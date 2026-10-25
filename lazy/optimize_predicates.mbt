///|
/// The predicate pass driver: sink each `Filter` toward the scan so rows drop
/// as early as possible. `push_predicates` rewrites the plan bottom-up and
/// `place_filter` sinks one predicate through the stages it may cross. The
/// crossing-soundness rules those two consult — row-locality, signed-zero
/// safety, group-cell stability, and the bare-column / row-count / defines
/// tests — are shared predicates defined in this package.

///|
/// The predicate pass: push every input first, then sink a `Filter` into its
/// now-rewritten input through `place_filter`. Every other node is already done
/// once its children are pushed, so only `Filter` needs a local step. Bottom-up
/// order is what lets a stack of filters sink as a unit — the lower filter is
/// already in place when the upper one descends onto it — while their relative
/// evaluation order never changes.
///
/// Walked iteratively (a `post_order` linearisation plus an explicit value
/// stack of rebuilt plans, not the call stack), so a deeply nested plan
/// optimizes without overflowing and aborting — the same never-abort treatment
/// the expression walks (`row_stable`, `eval_expr`) already carry. Each node is
/// rebuilt from its already-rebuilt children (popped off the stack top); a
/// rebuilt `Filter` then sinks through `place_filter`. Total: every arm is plain
/// data work.
///
/// # The crossing rules
///
/// A filter may sink below a stage only when dropping rows first provably
/// cannot change the stage's output on the surviving rows, its errors, or
/// the filter's own verdicts:
///
/// - `Select` — crossed when every selected expression is `row_stable`
///   *and* the selection preserves its input's row count (it reads at
///   least one column, mapping rows one-to-one rather than collapsing to a
///   single literal row: an all-constant selection collapses any input,
///   even zero rows, to one row, so a dropping filter must stay above it),
///   and every column the predicate reads appears in the selection as a
///   *bare* `col(name)` (so the predicate sees the same values below, and
///   a predicate the selection would have starved of its column still
///   fails identically — a computed or renamed column fences the filter
///   above).
/// - `WithColumns` — crossed under the same `row_stable` rule when the
///   stage *defines* none of the predicate's columns (a defined name has
///   different values — or no existence at all — below the stage; its
///   pass-through columns are identical on both sides by construction).
/// - `Aggregate` — crossed when the predicate is `row_stable` and reads
///   only *bare-column* keys (a key written as `col(name)`: every row of a
///   group shares its key tuple, so filtering groups after aggregation and
///   filtering their rows before it drop exactly the same groups, in the
///   same first-appearance order — and a bare key's output column holds its
///   input column verbatim, so the predicate reads identical values below).
///   The predicate must also be `signed_zero_safe` — the signed-zero rule
///   stated in full on that analysis; its
///   `Aggregate` hook is the `Float` key fold, so an unsafe predicate could
///   drop only part of a folded group below the aggregate and change its
///   surviving reduction.
///   Every key must also be `row_stable`, not only the ones the predicate
///   reads: each key is materialised as an output column (and joins the
///   grouping tuple). An aggregate key broadcasts a whole-scope reduction,
///   so a filtered scope would silently recompute its output cell; a cast /
///   map / lit-series key is value-raising or positional per `row_stable`.
///   All four must stay above the filter.
///   A *derived* key (any non-`Col` expression) outputs a computed column
///   whose name need not exist in the input at all, so a predicate over it
///   stays above; predicates over aggregation *outputs* read non-key names
///   and stay above the same way. Every aggregation must also be
///   `group_cell_stable` — its per-group cell can neither be null nor raise
///   on values: `sum` / `count` / `mean` / `min` / `max` over a
///   `row_stable` operand and non-null literals qualify (a
///   `sum(col.cast(…))` does not — its operand can raise on the cells it
///   meets), and `cast` does not (a dropped group could be the one whose
///   value fails to convert). `mean` / `min` / `max` cross by the
///   group-invariance argument: the crossing conditions above already
///   hold the group set and every group's cells fixed (a predicate that
///   reads only bare keys gives every row of a group the same verdict, so
///   a group survives whole or drops whole), and these ops are pure
///   functions of their group's cells — null exactly when an all-null
///   group makes them so — so per-group values, null-ness, and raised
///   errors are all unchanged. (The fence they replace was argued from an
///   all-null group's null cell flipping the stitched column's backend,
///   which column equality has since stopped observing; this argument, not
///   that removal, is what licenses the crossing.) The sample statistics
///   (`std` / `var` / `median`) and `first` / `last` stay fenced — a
///   conservative bound no consumer has asked to loosen.
/// - Everything else stops the descent. `Head` / `Tail` / `Slice` pick
///   rows by *position*, and filtering re-numbers positions. `Sort` and
///   another `Filter` are value-safe to cross for row-stable predicates
///   but are deliberately left in place: crossing a filter re-orders
///   which predicate evaluates first, and crossing a sort buys nothing
///   until the executor can exploit sortedness. `Join` is a floor for the
///   *descent* — a predicate that cannot split into one side wraps it —
///   but the one shape that can, does: a filter sitting directly on a
///   join splits into the side its columns name (`split_filter_into_join`
///   below, with the per-join-kind soundness argument). The in-memory
///   `Scan` is the floor. A **file source** goes one step further: the
///   predicate is absorbed into the file scan source itself, so the
///   driver prunes rows while reading and no `Filter` node remains above
///   the leaf.
///   Only the first predicate is absorbed — combining two would reorder
///   which operand's evaluation error surfaces first — so a second filter
///   stays a node above the scan.
fn LogicalPlan::push_predicates(self : LogicalPlan) -> LogicalPlan {
  let values : Array[LogicalPlan] = []
  for node in self.post_order() {
    match node {
      Scan(_) => values.push(node)
      // A `Filter` sinks into its rewritten input via `place_filter`; every
      // other unary op is an identity rebuild over its already-rewritten child.
      Unary(_, Filter(predicate)) =>
        values.push(pop_top(values).place_filter(predicate))
      Unary(_, op) => values.push(Unary(pop_top(values), op))
      Join(_, _, options) => rejoin(values, options)
      Aggregate(_, keys, exprs) =>
        values.push(Aggregate(pop_top(values), keys, exprs))
      AggregateAll(_, keys, op) =>
        values.push(AggregateAll(pop_top(values), keys, op))
    }
  }
  pop_top(values)
}

///|
/// Sink one predicate into `input` as deep as the crossing rules allow
/// (see the header), wrapping the floor it reaches in the `Filter` node.
/// Each hop reproduces the crossed stage verbatim above the descending
/// filter, so `place_filter` is always plan-equivalent to
/// `Filter`-over-input — the hops are exactly the swaps proven safe.
/// Walked iteratively (descend the single-child spine recording each crossed
/// stage as a rebuild closure, not the call stack), so a deep crossable spine
/// sinks without overflowing and aborting — total at any depth.
fn LogicalPlan::place_filter(
  self : LogicalPlan,
  predicate : @expr.Expr,
) -> LogicalPlan {
  // The decimal value-fence, predicate half: a predicate whose own
  // evaluation refuses on values keeps its row set — sinking it would
  // prune the very rows the refusal lives on, and the crossing gates
  // below are structural and cannot see it.
  let decimal_names = decimal_names_in_plan(self)
  if value_raises_on_decimal(predicate.node(), decimal_names) {
    return Unary(self, Filter(predicate))
  }
  // The crossing gates, each local to the only walk that asks them:
  //
  // `group_cell_stable` over an aggregation's expression list: one unstable
  // cell fences it, and an empty list is vacuously stable — a keys-only
  // aggregation has no stitched columns to flip. (`all_row_stable` and
  // `preserves_row_count` are package-level beside the slice pass, which
  // consults the same two verdicts.)
  fn all_group_cells_stable(exprs : Array[@expr.Expr]) -> Bool {
    exprs.all(e => group_cell_stable(e.node()))
  }

  // Whether every column the predicate reads appears in `exprs` as a *bare*
  // `col(name)` — the pass-through test shared by the `Select` (projection
  // list) and `Aggregate` (key list) crossing rules. A bare `col(name)`
  // re-emits its input column verbatim, so the predicate sees identical
  // values below the stage; a computed or renamed occurrence does not count,
  // even under the same output name, and a *derived* key (any non-`Col`
  // expression) likewise fails — its output name need not exist in the
  // input at all. Vacuously true for a column-less (all-literal) predicate.
  fn reads_only_bare_columns(
    predicate : @expr.Expr,
    exprs : Array[@expr.Expr],
  ) -> Bool {
    for name in predicate.referenced_columns() {
      if !has_bare_column(exprs, name) {
        return false
      }
    }
    true
  }

  // Descend while the current stage is crossable, recording how to rebuild each
  // crossed stage over a new input; stop at the first floor.
  let crossed : Array[(LogicalPlan) -> LogicalPlan] = []
  let mut cur = self
  let mut descending = true
  while descending {
    match cur {
      Unary(inner, Select(exprs)) =>
        if all_row_stable(exprs) &&
          preserves_row_count(exprs) &&
          reads_only_bare_columns(predicate, exprs) &&
          !stage_value_raises(exprs, decimal_names) {
          crossed.push(ni => Unary(ni, Select(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Unary(inner, WithColumns(exprs)) =>
        if all_row_stable(exprs) &&
          defines_none_of(exprs, predicate) &&
          !stage_value_raises(exprs, decimal_names) {
          crossed.push(ni => Unary(ni, WithColumns(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Aggregate(inner, keys, exprs) =>
        if row_stable(predicate.node()) &&
          all_row_stable(keys) &&
          reads_only_bare_columns(predicate, keys) &&
          signed_zero_safe(predicate.node()) &&
          all_group_cells_stable(exprs) &&
          // The decimal value-fence, stage half: the keys and the stitched
          // cells evaluate over the child's rows, and a decimal sum or
          // arithmetic refuses on the cells of exactly the groups a
          // sunken predicate would drop.
          !stage_value_raises(keys, decimal_names) &&
          !stage_value_raises(exprs, decimal_names) {
          crossed.push(ni => Aggregate(ni, keys, exprs))
          cur = inner
        } else {
          descending = false
        }
      // Every other node is a floor: the in-memory / file scans, a `Join`,
      // and any other unary op (`Sort` / `Head` / a second `Filter` / …) a dropping
      // filter must not cross. An `AggregateAll` floors here too: the
      // crossing test reads the aggregated expressions to prove a predicate's
      // cells stable, and this node's aggregations exist only at collect —
      // conservatively fencing is the sound reading (the node's own comment).
      Scan(_) | Unary(_, _) | Join(_, _, _) | AggregateAll(_, _, _) =>
        descending = false
    }
  }
  // The floor is `cur`. A file source takes the predicate *into* the read
  // (push-down proper: it builds the predicate's columns, prunes the rows, and
  // only then parses the rest), so no `Filter` node remains above it. A scan
  // that already absorbed one keeps its own and the new predicate stays a
  // node above it — combining them would reorder which operand's evaluation
  // error surfaces first.
  //
  // A predicate that names no column (a literal like `lit_bool(true)`, a
  // no-input `map`) rides in like any other: the pruner builds a zero-column
  // key frame, which carries the file's row count as an `N×0` frame, and the
  // literal broadcasts over that height exactly as it does over a fully-read
  // one. (While a column-less frame was pinned to `0×0` such a predicate had
  // to be held back above the scan, or the lost row count dropped every row.)
  let mut result = match cur {
    // Only a file source with no absorbed predicate yet takes this one in;
    // struct-update keeps the driver and the pushed projection verbatim.
    Scan(File(fs)) if fs.predicate is None =>
      Scan(File({ ..fs, predicate: Some(predicate), }))
    // A filter sitting directly on a join may split into one side — the
    // crossing rules for that hop are `split_filter_into_join`'s; failing
    // them, the join floors the filter like any other node.
    Join(left, right, options) =>
      match
        split_filter_into_join(left, right, options, predicate, decimal_names) {
        Some(joined) => joined
        None => Unary(cur, Filter(predicate))
      }
    _ => Unary(cur, Filter(predicate))
  }
  for i = crossed.length() - 1; i >= 0; i = i - 1 {
    let rewrap = crossed[i]
    result = rewrap(result)
  }
  result
}

///|
/// Split one filter into the join it sits on — the `Join` floor's half of
/// `place_filter`, and the one crossing whose soundness is argued per join
/// kind rather than per stage shape. A predicate may move *into one side*
/// when every row of that side provably survives to some output row that
/// carries its cells verbatim, so filtering the side before the join and
/// filtering the join's output drop exactly the same rows:
///
/// - `Inner` / `Cross` — every output row is a matched (or paired) pair of
///   real rows, so a predicate reading only one side's columns has the same
///   verdict on the output row as on that side's row. Both sides qualify.
/// - `Left` — a left row always produces an output row (matched, or
///   null-extended on the right), and the left columns ride it verbatim, so
///   a left-side predicate's verdicts agree everywhere; a *right*-side
///   predicate does not qualify (a null-extended row reads null where the
///   sunk version would have read the dropped match's cells). Left only.
/// - `Right` — the mirror: right only.
/// - `Outer` — either side can be null-extended on the other's unmatched
///   rows, so neither side qualifies.
/// - `Semi` / `Anti` — the output is a subset of the left schema in left
///   order, so a left-side predicate commutes with the existence test;
///   there are no right output columns to read. Left only.
///
/// Column attribution comes from the static name walk (`output_names`): the
/// predicate's every referenced name must be a *left* output name (left
/// columns keep their names through the join), or — for the right sink — a
/// right name that no left name clashes with (so the join outputs it under
/// its own name; a clashed right column is renamed `<name><suffix>` and a
/// predicate reading the suffixed spelling would need its expression
/// rewritten, which this pass does not do). A side whose names are not
/// statically knowable cannot be attributed and does not sink.
///
/// The error face is covered by the gates every sinking already carries:
/// `row_stable` excludes the expressions whose *raises* depend on which
/// rows exist (a cast's values, a map's closure, a literal series' height —
/// a sunk predicate would evaluate at the side's height, not the join's
/// output height), and the decimal value-fence at the top of `place_filter`
/// has already checked the predicate against the *whole* subtree's decimal
/// names — a superset of either side's — so a split can only sink into a
/// side whose decimal refusals the predicate has already been cleared
/// against. The join's *keys* carry the same two gates, and for a stronger
/// reason than error faithfulness: after a sink, the keys re-evaluate on
/// the filtered side, so an aggregation key broadcasts over a different
/// frame (`sum(v)` of the surviving rows), a positional key reads different
/// neighbours, and a literal-series key meets a different height — the
/// *matching itself* changes, not just the errors. `all_row_stable` over
/// every key (`on` keys evaluate on both sides, so they gate the split as
/// a whole), plus the decimal fence read against the same whole-subtree
/// risk set, keep those keys' evaluations — values and refusals alike —
/// identical below the sink. What remains raises, if at all, on
/// scope-independent facts (a dtype, a regex pattern's compile) that hold
/// identically on the side and on the join output — the left columns ride
/// verbatim, so their dtypes are the same cells' dtypes — and the
/// evaluation itself runs column-wise whether the frame is empty or not
/// (`filter_row_indices` evaluates the predicate before looking at rows),
/// so even an empty-output join has already raised the same error the sunk
/// version raises on the non-empty side.
fn split_filter_into_join(
  left : LogicalPlan,
  right : LogicalPlan,
  options : @frame.JoinOptions,
  predicate : @expr.Expr,
  decimal_names : DecimalRisk,
) -> LogicalPlan? {
  if !row_stable(predicate.node()) {
    return None
  }
  // The keys re-evaluate on each side once the predicate sinks into one,
  // so they carry the aggregate crossing's own key gate (`all_row_stable`)
  // and the decimal fence — see the header.
  let keys : Array[@expr.Expr] = []
  for key in options.on_keys() {
    keys.push(key)
  }
  for key in options.left_keys() {
    keys.push(key)
  }
  for key in options.right_keys() {
    keys.push(key)
  }
  if !all_row_stable(keys) {
    return None
  }
  if keys.any(k => value_raises_on_decimal(k.node(), decimal_names)) {
    return None
  }
  let reads = predicate.referenced_columns()
  let left_names = left.output_names()
  let right_names = right.output_names()
  let can_left = match (options.how, left_names) {
    (Inner | Left | Cross | Semi | Anti, Some(names)) =>
      reads_within(reads, names)
    (Right | Outer, _) | (_, None) => false
  }
  let can_right = match (options.how, left_names, right_names) {
    (Inner | Right | Cross, Some(l), Some(r)) => {
      // Only the right names the left does not clash with keep their
      // spelling in the output; a clashed one is renamed and cannot be
      // attributed without rewriting the predicate's expression.
      let bare = @set.Set([])
      r.each(name => if !l.contains(name) { bare.add(name) })
      reads_within(reads, bare)
    }
    (Left | Outer | Semi | Anti, _, _) | (_, None, _) | (_, _, None) => false
  }
  if can_left {
    Some(Join(left.place_filter(predicate), right, options))
  } else if can_right {
    Some(Join(left, right.place_filter(predicate), options))
  } else {
    None
  }
}

///|
/// Whether every name in `reads` is in `names` — the attribution test both
/// join sinks consult. An empty `reads` (a literal predicate) is vacuously
/// within every set, including the left one it then sinks into.
fn reads_within(reads : @set.Set[String], names : @set.Set[String]) -> Bool {
  let mut within = true
  reads.each(name => if !names.contains(name) { within = false })
  within
}
