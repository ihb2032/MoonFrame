///|
/// The predicate pass driver: sink each `Filter` toward the scan so rows drop
/// as early as possible. `push_predicates` rewrites the plan bottom-up and
/// `place_filter` sinks one predicate through the stages it may cross. The
/// crossing-soundness rules those two consult (`row_stable`, `signed_zero_safe`,
/// `group_cell_stable`, the bare-column / row-count / defines tests) live in
/// `optimize_predicate_rules.mbt`; the whole-optimizer overview is on `optimize`
/// in `optimize.mbt`.

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
///   The predicate must also be `signed_zero_safe`: a `Float` key folds `-0.0`
///   and `+0.0` into one group, yet the group's output row keeps its
///   representative's signed key, and division and a negative exponent are the
///   operators that tell the two apart (`1/+0.0 = +inf` vs `1/-0.0 = -inf`,
///   `(+0.0) ** -1 = +inf` vs `(-0.0) ** -1 = -inf`), so such a predicate could
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
///   on values: `sum` / `count` over a `row_stable` operand and non-null
///   literals qualify (a `sum(col.cast(…))` does not — its operand can raise
///   on the cells it meets), `mean` / `min` / `max` do not, and `cast` does
///   not (a dropped group could be the one whose value fails to convert).
///   The `mean` / `min` / `max` fence is **conservative**: it was argued from
///   an all-null group's null cell flipping the stitched column's backend,
///   which column equality has since stopped observing (it compares dtype,
///   length, null-ness and values, never the backend). Loosening it therefore
///   needs its own argument — that per-group values, null-ness and raised
///   errors are all unchanged when other groups disappear — not the removal of
///   the old one.
/// - Everything else stops the descent. `Head` / `Tail` / `Slice` pick
///   rows by *position*, and filtering re-numbers positions. `Sort` and
///   another `Filter` are value-safe to cross for row-stable predicates
///   but are deliberately left in place: crossing a filter re-orders
///   which predicate evaluates first, and crossing a sort buys nothing
///   until the executor can exploit sortedness. `Join` needs column
///   provenance through suffix renaming to split a predicate across its
///   sides, deferred with the projection pass's join narrowing — but
///   both sides restart their own descent, so filters inside either
///   side still sink. The in-memory `Scan` is the floor. A **file source**
///   goes one step further: the predicate is absorbed into the file scan
///   source itself, so the driver prunes rows while reading (the io drivers'
///   pruned core, `io/scan_driver.mbt`) and no `Filter` node remains above
///   the leaf.
///   Only the first predicate is absorbed — combining two would reorder
///   which operand's evaluation error surfaces first — so a second filter
///   stays a node above the scan.
fn push_predicates(plan : LogicalPlan) -> LogicalPlan {
  let values : Array[LogicalPlan] = []
  for node in post_order(plan) {
    match node {
      Scan(_) => values.push(node)
      // A `Filter` sinks into its rewritten input via `place_filter`; every
      // other unary op is an identity rebuild over its already-rewritten child.
      Unary(_, Filter(predicate)) =>
        values.push(place_filter(pop_top(values), predicate))
      Unary(_, op) => values.push(Unary(pop_top(values), op))
      Join(_, _, options) => {
        let right = pop_top(values)
        let left = pop_top(values)
        values.push(Join(left, right, options))
      }
      Aggregate(_, keys, exprs) =>
        values.push(Aggregate(pop_top(values), keys, exprs))
    }
  }
  pop_top(values)
}

///|
/// Sink one predicate into `input` as deep as the crossing rules allow
/// (see the header), wrapping the floor it reaches in the `Filter` node.
/// Each hop reproduces the crossed stage verbatim above the descending
/// filter, so `place_filter(input, p)` is always plan-equivalent to
/// `Filter(input, p)` — the hops are exactly the swaps proven safe.
/// Walked iteratively (descend the single-child spine recording each crossed
/// stage as a rebuild closure, not the call stack), so a deep crossable spine
/// sinks without overflowing and aborting — total at any depth.
fn place_filter(input : LogicalPlan, predicate : @expr.Expr) -> LogicalPlan {
  // Descend while the current stage is crossable, recording how to rebuild each
  // crossed stage over a new input; stop at the first floor.
  let crossed : Array[(LogicalPlan) -> LogicalPlan] = []
  let mut cur = input
  let mut descending = true
  while descending {
    match cur {
      Unary(inner, Select(exprs)) =>
        if all_row_stable(exprs) &&
          preserves_row_count(exprs) &&
          reads_only_bare_columns(predicate, exprs) {
          crossed.push(ni => Unary(ni, Select(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Unary(inner, WithColumns(exprs)) =>
        if all_row_stable(exprs) && defines_none_of(exprs, predicate) {
          crossed.push(ni => Unary(ni, WithColumns(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Aggregate(inner, keys, exprs) =>
        if row_stable(predicate.node()) &&
          all_row_stable(keys) &&
          reads_only_bare_columns(predicate, keys) &&
          signed_zero_safe(predicate) &&
          all_group_cells_stable(exprs) {
          crossed.push(ni => Aggregate(ni, keys, exprs))
          cur = inner
        } else {
          descending = false
        }
      // Every other node is a floor: the in-memory / file scans, a `Join`, and
      // any other unary op (`Sort` / `Head` / a second `Filter` / …) a dropping
      // filter must not cross.
      Scan(_) | Unary(_, _) | Join(_, _, _) => descending = false
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
    _ => Unary(cur, Filter(predicate))
  }
  for i = crossed.length() - 1; i >= 0; i = i - 1 {
    let rewrap = crossed[i]
    result = rewrap(result)
  }
  result
}
