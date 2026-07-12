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
          signed_zero_safe(predicate) &&
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
