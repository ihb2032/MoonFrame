///|
/// The query optimizer: two **total** plan→plan rewrites — pure tree
/// walking, no raise, no abort — that `collect` runs in front of the
/// executor and `explain(optimized=true)` renders for inspection. The
/// predicate pass runs first and sinks `Filter` nodes toward the scan so
/// rows drop as early as possible; the projection pass then runs a
/// required-columns analysis and narrows each scan — the in-memory `Scan`
/// and the `ScanCsv` / `ScanNdjson` file sources alike — to the columns its
/// consumers provably read, so dead columns never ride through row-level work
/// (and, for a file source, are never even parsed). The inviolable contract
/// is the executor's own: `execute(optimize(p))` is bitwise-equal to
/// `execute(p)` for every plan that collects. Neither pass ever alters a
/// user-written node's *content* (predicates, expression lists, keys stay
/// verbatim); the predicate pass re-orders whole `Filter` nodes downward, and
/// the projection pass narrows a scan two ways — inserting a `Select` of bare
/// column references over an in-memory `Scan`, or writing the column set into
/// a file source's own projection field.
///
/// Error faithfulness under re-ordering: a plan that fails to collect
/// still fails after optimization. When exactly one stage is broken, it
/// fails with the *same* `DataError` — every error the evaluator can
/// produce (`ColumnNotFound`, dtype-level `TypeMismatch`,
/// `DuplicateColumn`, the reduction-shape `InvalidOperation`) is decided
/// by names, dtypes, and expression shape, none of which the rewrites
/// disturb. When *several* stages are independently broken, sinking a
/// filter below another broken stage can change which of their errors
/// surfaces first — both are real errors of the same plan, and which one
/// wins was an artifact of stage order to begin with. The one failure
/// mode that would be value-dependent — `cast`'s parse / range rejection,
/// where dropping a row could drop the very cell that raises — is fenced
/// off entirely: no `Filter` ever crosses a stage whose expressions
/// contain a `Cast` (see `row_stable`).
///
/// The sole deliberate exception is a file source's projection (`ScanCsv` /
/// `ScanNdjson`). Narrowing it to the columns its consumers read means a
/// dropped column is never parsed, so a parse error confined to one — a
/// malformed cell no stage reads — is not raised by the optimized plan, where
/// the unoptimized full read would surface it. This is the defining property
/// of projection push-down into a source (and matches Polars' `scan_csv` /
/// `scan_ndjson`): every plan that *collects* still collects bitwise-equal,
/// every whole-input failure (a malformed header or line, a ragged row, a
/// missing file) still fails identically, and a parse error in a *kept* column
/// still surfaces unchanged — only an error isolated to a pruned-away column
/// goes unraised.
///
/// # The predicate pass
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
///   The predicate must also be `division_free`: a `Float` key folds `-0.0`
///   and `+0.0` into one group, yet the group's output row keeps its
///   representative's signed key, and division is the only operator that tells
///   the two apart (`1/+0.0 = +inf` vs `1/-0.0 = -inf`), so a dividing
///   predicate could drop only part of a folded group below the aggregate and
///   change its surviving reduction.
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
///   on the cells it meets), `mean` /
///   `min` / `max` do not (an all-null group yields a null cell, and
///   dropping that group would flip the stitched column's backend from
///   `Builtin` to `Numeric`, which the structural `Series` equality
///   observes), and `cast` does not (a dropped group could be the one whose
///   value fails to convert).
/// - Everything else stops the descent. `Head` / `Tail` / `Slice` pick
///   rows by *position*, and filtering re-numbers positions. `Sort` and
///   another `Filter` are value-safe to cross for row-stable predicates
///   but are deliberately left in place: crossing a filter re-orders
///   which predicate evaluates first, and crossing a sort buys nothing
///   until the executor can exploit sortedness. `Join` needs column
///   provenance through suffix renaming to split a predicate across its
///   sides, deferred with the projection pass's join narrowing — but
///   both sides restart their own descent, so filters inside either
///   side still sink. The scan leaves — `Scan`, `ScanCsv`, `ScanNdjson` —
///   are the floor; pushing a predicate into a file parser is v0.6.
///
/// # The projection pass
///
/// A top-down "required columns" analysis:
///
/// - `None` — the consumer may observe this node's *entire* output
///   (the plan root, or anything under a barrier node): its layout must
///   survive untouched, so no narrowing happens at this node's leaves
///   unless a descendant re-establishes a requirement of its own.
/// - `Some(s)` — the consumer reads only the named columns, **by name**,
///   and is insensitive to the node's column order and to extra columns.
///   Only the two by-name readers originate this: `Select` and
///   `Aggregate`, whose outputs are fully determined by their expression
///   / key lists. The layout-preserving nodes (`Filter` / `Sort` /
///   `Head` / `Tail` / `Slice`) pass the requirement through, widened by
///   the columns they read themselves; `WithColumns` subtracts the names
///   its expressions *define* (those need not exist in its input) and
///   adds the names they *read*. `Join` stays a barrier — splitting a
///   requirement across two sides whose outputs interleave under suffix
///   renaming is column provenance, deferred — but both sides restart
///   their own pass, so a `Select` deep under a join still narrows its
///   own scan.
///
/// Why the order insensitivity matters: narrowing a `with_columns` input
/// can turn an in-place column *replacement* into an *append* (the
/// replaced name no longer exists in the narrowed input), perturbing the
/// intermediate column order. That perturbation is only ever visible to
/// the requirement's originator — a by-name reader — never to the plan
/// root, which always starts at `None`. The `Aggregate` executor reads
/// its keys in key-list order, not input order, so it qualifies too.
///
/// Running the predicate pass first keeps the analysis honest: a sunk
/// filter is just another layout-preserving node by the time the
/// projection pass sees it, so its predicate columns stay alive at the
/// scan, and the narrowing `Select` lands *under* the sunk filter.
///
/// Deliberately deferred: pruning dead expressions from `Select` /
/// `WithColumns` lists (changes which expressions evaluate, hence which
/// *errors* a failing plan reports), narrowing or predicate-splitting
/// through `Join`, sinking filters below `Sort`, and pushing a predicate
/// into a file parser (`ScanCsv` / `ScanNdjson`) or streaming the file (both
/// v0.6). `optimize` is also not idempotent — re-optimizing an
/// already-rewritten plan would stack another (harmless) narrowing select
/// over an in-memory `Scan` (a file source's in-place projection just
/// recomputes to the same set) — which is moot in practice: plans are
/// immutable, and each `collect` or `explain(optimized=true)` call rewrites
/// the as-built plan exactly once.
fn optimize(plan : LogicalPlan) -> LogicalPlan {
  // A DAG-shaped plan — nested self-joins share node objects by reference —
  // is left as-built: both passes rebuild tree-wise, so rewriting would
  // materialise every shared subplan once per occurrence (2^depth new nodes
  // for nested self-joins, an OOM abort long before execution), and the
  // memoised executor already runs each shared subplan exactly once without
  // help. Tree plans — every chain the builders produce without sharing a
  // `LazyFrame` value across both sides of a join — rewrite exactly as
  // before.
  if has_shared_subplan(plan) {
    return plan
  }
  push_projection(push_predicates(plan), None)
}

// ── The predicate pass ──────────────────────────────────────────────────

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
fn push_predicates(plan : LogicalPlan) -> LogicalPlan {
  let values : Array[LogicalPlan] = []
  for node in post_order(plan) {
    match node {
      Scan(_) | ScanCsv(_, _, _) | ScanNdjson(_, _, _) => values.push(node)
      Select(_, exprs) => values.push(Select(pop_top(values), exprs))
      WithColumns(_, exprs) => values.push(WithColumns(pop_top(values), exprs))
      Filter(_, predicate) =>
        values.push(place_filter(pop_top(values), predicate))
      Sort(_, by) => values.push(Sort(pop_top(values), by))
      Head(_, n) => values.push(Head(pop_top(values), n))
      Tail(_, n) => values.push(Tail(pop_top(values), n))
      Slice(_, start, end) => values.push(Slice(pop_top(values), start, end))
      Join(_, _, options) => {
        let right = pop_top(values)
        let left = pop_top(values)
        values.push(Join(left, right, options))
      }
      Aggregate(_, keys, exprs) =>
        values.push(Aggregate(pop_top(values), keys, exprs))
      Drop(_, exprs) => values.push(Drop(pop_top(values), exprs))
      Rename(_, pairs) => values.push(Rename(pop_top(values), pairs))
      Unique(_) => values.push(Unique(pop_top(values)))
      DropNulls(_, subset) => values.push(DropNulls(pop_top(values), subset))
      FillNull(_, value) => values.push(FillNull(pop_top(values), value))
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
      Select(inner, exprs) =>
        if all_row_stable(exprs) &&
          preserves_row_count(exprs) &&
          reads_only_bare_columns(predicate, exprs) {
          crossed.push(ni => Select(ni, exprs))
          cur = inner
        } else {
          descending = false
        }
      WithColumns(inner, exprs) =>
        if all_row_stable(exprs) && defines_none_of(exprs, predicate) {
          crossed.push(ni => WithColumns(ni, exprs))
          cur = inner
        } else {
          descending = false
        }
      Aggregate(inner, keys, exprs) =>
        if row_stable(predicate) &&
          all_row_stable(keys) &&
          reads_only_bare_columns(predicate, keys) &&
          division_free(predicate) &&
          all_group_cells_stable(exprs) {
          crossed.push(ni => Aggregate(ni, keys, exprs))
          cur = inner
        } else {
          descending = false
        }
      Scan(_)
      | ScanCsv(_, _, _)
      | ScanNdjson(_, _, _)
      | Filter(_, _)
      | Sort(_, _)
      | Head(_, _)
      | Tail(_, _)
      | Slice(_, _, _)
      | Join(_, _, _)
      | Drop(_, _)
      | Rename(_, _)
      | Unique(_)
      | DropNulls(_, _)
      | FillNull(_, _) => descending = false
    }
  }
  // The floor is `cur`; the filter sits just above it. Re-wrap the crossed
  // stages from innermost (last recorded) outward, reproducing the original
  // top-to-bottom stack above the sunk filter.
  let mut result = Filter(cur, predicate)
  for i = crossed.length() - 1; i >= 0; i = i - 1 {
    let rewrap = crossed[i]
    result = rewrap(result)
  }
  result
}

///|
/// Whether evaluating `expr` is invariant under dropping *other* rows of
/// its scope: each output cell depends only on its own row (literals
/// broadcast), and no cell can raise on a value. Aggregations fail the
/// first half — their value is computed over the whole scope, so a
/// filtered scope changes it. `Cast` fails the second half — its parse /
/// range rejection raises on the *values* it meets, so dropping a row
/// can drop the very cell that would have raised. `Map` fails it the same
/// way — its opaque closure can `raise` on the values it meets — so a `Map`
/// is a value barrier, exactly like `Cast`. A `LitSeries` is a *shape*
/// barrier: a frame-tall literal column is positional (cell `i` is row `i`),
/// so dropping rows before the stage would leave it mismatched against the
/// now-shorter frame — pushing a filter past it could turn a working plan
/// into a `LengthMismatch`, so no filter crosses it either. Everything else
/// (column reads, scalar literals, the operators, the total unary probes,
/// the string-namespace transforms, aliasing, ternary selection) is
/// row-local and raises only on scope-independent facts (names, dtypes) —
/// a `Str` op is per-cell and total, raising only the dtype-level
/// `TypeMismatch` of a non-String operand.
fn row_stable(expr : @expr.Expr) -> Bool {
  // Iterative tree walk (explicit stack, not the call stack) so a deeply nested
  // predicate cannot overflow and abort during optimization — total at any
  // depth, as this function's doc promises. Every node must be row-local;
  // `children()` drives the descent, so a new `Expr` variant is covered the
  // moment it declares its children.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Agg(_, _)
          | @expr.Expr::Cast(_, _)
          | @expr.Expr::Map(_, _, _)
          | @expr.Expr::LitSeries(_) => return false
          @expr.Expr::Col(_)
          | @expr.Expr::Lit(_)
          | @expr.Expr::Binary(_, _, _)
          | @expr.Expr::Unary(_, _)
          | @expr.Expr::Str(_, _)
          | @expr.Expr::Alias(_, _)
          | @expr.Expr::Ternary(_, _, _)
          | @expr.Expr::FillNull(_, _)
          | @expr.Expr::FillNan(_, _) =>
            for child in e.children() {
              stack.push(child)
            }
        }
    }
  }
  true
}

///|
/// `row_stable` over a stage's whole expression list — one scope-bound or
/// value-raising expression fences the stage.
fn all_row_stable(exprs : Array[@expr.Expr]) -> Bool {
  exprs.all(row_stable)
}

///|
/// Whether `expr` is free of division — the extra gate the `Aggregate`
/// predicate pushdown needs to stay sound on a `Float` group key. `KeyCell`
/// folds `-0.0` and `+0.0` into one group, but the group's output row keeps its
/// *representative* row's signed key, so a predicate that can tell the two
/// apart disagrees between a group's individual rows (filtered below the
/// aggregate) and that representative (filtered above it). Division is the only
/// operator in the vocabulary that makes a zero's sign observable —
/// `1.0 / +0.0 = +inf` but `1.0 / -0.0 = -inf`, while `+` / `-` / `*` and every
/// comparison treat `-0.0` and `+0.0` as equal — so a division-free predicate
/// gives every row of a folded group the same verdict and may sink below the
/// aggregate, while one that divides could drop only part of the group and must
/// stay above. Walks `children()` like `row_stable`, so a future `Expr` variant
/// is covered without a wildcard.
fn division_free(expr : @expr.Expr) -> Bool {
  // Iterative walk like `row_stable`: a deeply nested predicate stays total
  // instead of overflowing the call stack during optimization.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Binary(@expr.BinOp::Div, _, _) => return false
          _ =>
            for child in e.children() {
              stack.push(child)
            }
        }
    }
  }
  true
}

///|
/// Whether an aggregation expression's per-group cell is provably
/// independent of *which other groups exist*: never null (so the stitched
/// column's `Builtin` / `Numeric` backend cannot flip when groups
/// disappear — `agg` converges an all-valid numeric column onto
/// `Numeric`, and structural equality sees the difference) and never
/// raising on values (so a dropped group cannot take its error with it).
/// `sum` / `count` / `n_unique` always produce a non-null value, but only
/// over a `row_stable` operand — a `sum(col.cast(Int))` or `sum(col.map(…))`
/// still raises on the cells its operand meets, so a value-raising operand
/// (a nested `Cast` / `Map`, or an `Agg` / `LitSeries`) fences the filter
/// above exactly as a top-level cast does; `mean` / `min` /
/// `max` / `std` / `var` / `median` go null on an all-null (or, for the
/// sample statistics, single-value) group, and `first` / `last` go null on a
/// null leading / trailing cell; a `cast`'s rejection is value-dependent, as is a
/// `map`'s opaque closure (null- or raise-valued on the cells it meets);
/// the null literal is a null cell by definition; a bare column — or a
/// `lit_series`, equally row-wise — is not reduction-shaped at all (the
/// executor raises structurally — fencing keeps that error exactly where the
/// as-built plan reports it). The
/// combinators preserve the property cell-wise: arithmetic, comparison,
/// and the Kleene connectives over non-null cells stay non-null, as do
/// the unary wrappers, the string-namespace transforms, and a ternary over
/// a non-null condition.
fn group_cell_stable(expr : @expr.Expr) -> Bool {
  // Iterative walk like `row_stable`: total at any predicate depth. An `Agg`
  // node is terminal here — its verdict is its op's (the reducing ops fence,
  // `Sum`/`Count`/`NUnique` defer to `row_stable` of the operand) — so its
  // operand is never pushed for further `group_cell_stable` descent.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Col(_) => return false
          @expr.Expr::Lit(value) =>
            match value {
              @types.Scalar::Null => return false
              @types.Scalar::Int(_)
              | @types.Scalar::Float(_)
              | @types.Scalar::Bool(_)
              | @types.Scalar::String(_) => ()
            }
          @expr.Expr::Agg(op, operand) =>
            match op {
              @expr.AggOp::Sum | @expr.AggOp::Count | @expr.AggOp::NUnique =>
                if !row_stable(operand) {
                  return false
                }
              @expr.AggOp::Mean
              | @expr.AggOp::Min
              | @expr.AggOp::Max
              | @expr.AggOp::Std
              | @expr.AggOp::Var
              | @expr.AggOp::Median
              | @expr.AggOp::First
              | @expr.AggOp::Last => return false
            }
          @expr.Expr::Cast(_, _)
          | @expr.Expr::Map(_, _, _)
          | @expr.Expr::LitSeries(_) => return false
          @expr.Expr::Binary(_, _, _)
          | @expr.Expr::Unary(_, _)
          | @expr.Expr::Str(_, _)
          | @expr.Expr::Alias(_, _)
          | @expr.Expr::FillNull(_, _)
          | @expr.Expr::FillNan(_, _)
          | @expr.Expr::Ternary(_, _, _) =>
            for child in e.children() {
              stack.push(child)
            }
        }
    }
  }
  true
}

///|
/// `group_cell_stable` over an aggregation's whole expression list — one
/// unstable cell fences the aggregation (an empty list is vacuously
/// stable: a keys-only aggregation has no stitched columns to flip).
fn all_group_cells_stable(exprs : Array[@expr.Expr]) -> Bool {
  exprs.all(group_cell_stable)
}

///|
/// Whether every column the predicate reads appears in `exprs` as a
/// *bare* `col(name)` — the pass-through test shared by the `Select`
/// (projection list) and `Aggregate` (key list) crossing rules. A bare
/// `col(name)` re-emits its input column verbatim, so the predicate sees
/// identical values below the stage, and a column the stage does not
/// output stays missing on both sides of the swap. A computed or renamed
/// occurrence does not count, even under the same output name: its values
/// are the stage's, not the input's. A *derived* key (any non-`Col`
/// expression) likewise fails the test — its output name need not exist in
/// the input at all. Vacuously true for a column-less (all-literal)
/// predicate.
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

///|
/// Whether the selection list contains `name` as a bare `col(name)` item.
fn has_bare_column(exprs : Array[@expr.Expr], name : String) -> Bool {
  for expr in exprs {
    match expr {
      @expr.Expr::Col(n) => if n == name { return true }
      _ => ()
    }
  }
  false
}

///|
/// Whether the selection's output height tracks its input's — i.e. it is
/// *not* an all-constant projection. `select` collapses any input,
/// even zero rows, to a single row when every expression is column-free (a
/// literal or an arithmetic of literals), because each such column is
/// length 1 and nothing fixes the height at the frame's. A filter may only
/// sink past a selection that keeps rows one-for-one: pushing a *dropping*
/// predicate below a collapsing selection would let it act on the
/// pre-collapse rows, then re-materialise the one literal row the as-built
/// collapse-then-filter had dropped (0 rows built, 1 row optimized).
/// Reached only after `all_row_stable` has excluded aggregations and
/// casts, so an expression is frame-tall exactly when it reads a column.
fn preserves_row_count(exprs : Array[@expr.Expr]) -> Bool {
  for expr in exprs {
    if !expr.referenced_columns().is_empty() {
      return true
    }
  }
  false
}

///|
/// Whether the stage defines none of the predicate's columns — the
/// `WithColumns` crossing rule. A defined name is served by the stage
/// itself: below it, the name either does not exist or (a replacement)
/// holds the original values the stage was about to overwrite, so a
/// predicate reading one must stay above.
fn defines_none_of(exprs : Array[@expr.Expr], predicate : @expr.Expr) -> Bool {
  let refs = predicate.referenced_columns()
  for expr in exprs {
    if refs.contains(expr.output_name()) {
      return false
    }
  }
  true
}

// ── The projection pass ─────────────────────────────────────────────────

///|
/// One step of the iterative projection pass: `Visit` descends into a node
/// under the requirement it inherits; `Rebuild1` / `RebuildJoin` reassemble a
/// node from its rebuilt child(ren) once they sit on the value stack. Lifting
/// the pass off the call stack (the `LogicalPlan` analogue of `eval_expr`'s
/// `EvalStep`) lets an arbitrarily deep plan optimize without overflowing.
priv enum ProjStep {
  Visit(LogicalPlan, @set.Set[String]?)
  Rebuild1((LogicalPlan) -> LogicalPlan)
  RebuildJoin(@frame.JoinOptions)
}

///|
/// The projection pass: a top-down required-columns analysis that narrows each
/// scan — the in-memory `Scan` (by inserting a `Select`) and the `ScanCsv` /
/// `ScanNdjson` file sources (by writing their projection field) — to the
/// columns its consumers provably read. The per-node requirement rules are in
/// the file header; this walks them iteratively — `Visit` computes each child's
/// requirement and schedules its rebuild, the rebuild pops the rebuilt
/// child(ren) off an explicit value stack — so a deeply nested plan optimizes
/// without overflowing and aborting (total at any depth). Every narrowing
/// decision and requirement is bit-for-bit the recursion's.
fn push_projection(
  plan : LogicalPlan,
  required : @set.Set[String]?,
) -> LogicalPlan {
  let work : Array[ProjStep] = [Visit(plan, required)]
  let values : Array[LogicalPlan] = []
  while work.length() > 0 {
    match pop_top(work) {
      Visit(node, req) =>
        match node {
          // Narrowing point: insert a `Select` only when the requirement is a
          // proper, non-empty subset of the scan's columns (header rationale).
          Scan(df) =>
            values.push(
              match req {
                None => Scan(df)
                Some(needed) => {
                  let cols = df.columns()
                  let survivors = cols.filter(name => needed.contains(name))
                  if survivors.length() > 0 &&
                    survivors.length() < cols.length() {
                    Select(Scan(df), survivors.map(name => @expr.col(name)))
                  } else {
                    Scan(df)
                  }
                }
              },
            )
          // File sources' narrowing point: write the requirement into the
          // node's own projection field (`narrow_scan`).
          ScanCsv(path, options, _) =>
            values.push(
              narrow_scan(node, req, columns => {
                ScanCsv(path, options, Some(columns))
              }),
            )
          ScanNdjson(path, options, _) =>
            values.push(
              narrow_scan(node, req, columns => {
                ScanNdjson(path, options, Some(columns))
              }),
            )
          // By-name originator: the input needs exactly the columns the
          // expressions read.
          Select(input, exprs) => {
            work.push(Rebuild1(c => Select(c, exprs)))
            work.push(Visit(input, Some(columns_read(exprs))))
          }
          // Layout-preserving: subtract the names this stage defines, add the
          // names it reads.
          WithColumns(input, exprs) => {
            let downstream : @set.Set[String]? = match req {
              None => None
              Some(needed) => {
                let defined : @set.Set[String] = @set.Set([])
                for expr in exprs {
                  defined.add(expr.output_name())
                }
                let pass : @set.Set[String] = @set.Set([])
                needed.each(name => {
                  if !defined.contains(name) {
                    pass.add(name)
                  }
                })
                add_all(pass, columns_read(exprs))
                Some(pass)
              }
            }
            work.push(Rebuild1(c => WithColumns(c, exprs)))
            work.push(Visit(input, downstream))
          }
          // Layout-preserving pass-throughs: the predicate / sort keys stay
          // alive alongside whatever the parent needs.
          Filter(input, predicate) => {
            work.push(Rebuild1(c => Filter(c, predicate)))
            work.push(
              Visit(input, widened(req, predicate.referenced_columns())),
            )
          }
          Sort(input, by) => {
            let keys : @set.Set[String] = @set.Set([])
            for key in by {
              let (expr, _, _) = key
              add_all(keys, expr.referenced_columns())
            }
            work.push(Rebuild1(c => Sort(c, by)))
            work.push(Visit(input, widened(req, keys)))
          }
          // Pure row windows read no columns: the requirement passes through.
          Head(input, n) => {
            work.push(Rebuild1(c => Head(c, n)))
            work.push(Visit(input, req))
          }
          Tail(input, n) => {
            work.push(Rebuild1(c => Tail(c, n)))
            work.push(Visit(input, req))
          }
          Slice(input, start, end) => {
            work.push(Rebuild1(c => Slice(c, start, end)))
            work.push(Visit(input, req))
          }
          // Barrier: both sides keep their full output; each restarts its pass.
          Join(left, right, options) => {
            work.push(RebuildJoin(options))
            work.push(Visit(right, None))
            work.push(Visit(left, None))
          }
          // By-name originator, like `Select`: keys + aggregated expressions.
          Aggregate(input, keys, exprs) => {
            let needed = columns_read(exprs)
            add_all(needed, columns_read(keys))
            work.push(Rebuild1(c => Aggregate(c, keys, exprs)))
            work.push(Visit(input, Some(needed)))
          }
          // Barriers (like `Join`): the input keeps its whole output (`None`).
          Drop(input, exprs) => {
            work.push(Rebuild1(c => Drop(c, exprs)))
            work.push(Visit(input, None))
          }
          Rename(input, pairs) => {
            work.push(Rebuild1(c => Rename(c, pairs)))
            work.push(Visit(input, None))
          }
          Unique(input) => {
            work.push(Rebuild1(c => Unique(c)))
            work.push(Visit(input, None))
          }
          DropNulls(input, subset) => {
            work.push(Rebuild1(c => DropNulls(c, subset)))
            work.push(Visit(input, None))
          }
          FillNull(input, value) => {
            work.push(Rebuild1(c => FillNull(c, value)))
            work.push(Visit(input, None))
          }
        }
      Rebuild1(f) => values.push(f(pop_top(values)))
      RebuildJoin(options) => {
        // Right is on top (pushed last), left just below.
        let right = pop_top(values)
        let left = pop_top(values)
        values.push(Join(left, right, options))
      }
    }
  }
  pop_top(values)
}

///|
/// Union of every column the expressions read, via
/// `Expr::referenced_columns` (which deliberately includes a ternary's
/// condition columns — pruning must keep them alive).
fn columns_read(exprs : Array[@expr.Expr]) -> @set.Set[String] {
  let acc : @set.Set[String] = @set.Set([])
  for expr in exprs {
    add_all(acc, expr.referenced_columns())
  }
  acc
}

///|
/// Fold one name set into an accumulator (core `Set` has no in-place
/// union).
fn add_all(acc : @set.Set[String], names : @set.Set[String]) -> Unit {
  names.each(name => acc.add(name))
}

///|
/// Narrow a file source (`ScanCsv` / `ScanNdjson`) to the required columns,
/// shared by both because they differ only in the node constructor `rebuild`
/// wraps. The file's columns aren't known until it is parsed, so there is
/// nothing to intersect here: the requirement is written verbatim into the
/// node's projection (sorted, for a deterministic `explain`), and the reader
/// filters it against the real header at collect time, keeping the file's own
/// column order. An unbounded requirement (`None`) or an empty one — an
/// all-literal consumer that reads no source column — leaves the scan whole
/// (mirroring the in-memory `Scan` guard), so the read still yields its columns
/// and a row count rather than collapsing to nothing. A required name absent
/// from the file is simply never built; whichever expression references it
/// raises the same `ColumnNotFound` it would in the unoptimized plan.
fn narrow_scan(
  plan : LogicalPlan,
  required : @set.Set[String]?,
  rebuild : (Array[String]) -> LogicalPlan,
) -> LogicalPlan {
  match required {
    None => plan
    Some(needed) => {
      let columns = sorted_names(needed)
      if columns.is_empty() {
        plan
      } else {
        rebuild(columns)
      }
    }
  }
}

///|
/// A name set as a sorted array — the deterministic column list the
/// projection pass writes into a file source's projection. Core `Set`
/// iteration is
/// unordered, so without this `explain(optimized=true)` would vary run to
/// run. Ordering routes through `@types.compare_string_lex` (dictionary
/// order), like every other user-facing ordering in MoonFrame, rather than
/// the built-in shortlex `Compare` on `String`; it is presentation only,
/// since the reader re-derives the read order from the file's own header.
fn sorted_names(names : @set.Set[String]) -> Array[String] {
  let arr : Array[String] = []
  names.each(name => arr.push(name))
  arr.sort_by((a, b) => @types.compare_string_lex(a, b))
  arr
}

///|
/// The pass-through rule for layout-preserving nodes that read columns of
/// their own: an unbounded requirement stays unbounded (the node's whole
/// output may be observed, and `extra` is necessarily part of "whole"),
/// and a bounded one is widened — into a fresh set, never mutating the
/// caller's — by the names this node reads.
fn widened(
  required : @set.Set[String]?,
  extra : @set.Set[String],
) -> @set.Set[String]? {
  match required {
    None => None
    Some(needed) => {
      let acc : @set.Set[String] = @set.Set([])
      add_all(acc, needed)
      add_all(acc, extra)
      Some(acc)
    }
  }
}
