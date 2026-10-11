// The slice pass: sink a `Head` / `Tail` / `Slice` window toward the scan so
// rows leave the pipeline as early as possible — the positional analogue of
// the predicate pass, and like Polars' `slice_pushdown`, it runs first so the
// later passes see the pruned plan. A window may cross a stage only when the
// stage is row-*preserving* (one output row per input row — otherwise which
// rows the window picks is different above and below) and its expressions
// are row-local (a value-raising expression on a pruned-away row would lose
// its error otherwise — the same fence the predicate pass uses for the same
// reason). `Select` adds the all-constant guard: a column-free selection
// collapses any input to one row, so a window must stay above it.

///|
/// The slice pass driver: push every input first, then sink a window node
/// into its now-rewritten input through `place_slice`. Bottom-up over the
/// shared post-order — iterative, total, like every engine walk.
fn LogicalPlan::push_slices(self : LogicalPlan) -> LogicalPlan {
  let values : Array[LogicalPlan] = []
  for node in self.post_order() {
    match node {
      Scan(_) => values.push(node)
      Unary(_, op) =>
        if op is Head(_) || op is Tail(_) || op is Slice(_, _) {
          values.push(pop_top(values).place_slice(op))
        } else {
          values.push(Unary(pop_top(values), op))
        }
      Join(_, _, options) => rejoin(values, options)
      Aggregate(_, keys, exprs) =>
        values.push(Aggregate(pop_top(values), keys, exprs))
      AggregateAll(_, keys, op2) =>
        values.push(AggregateAll(pop_top(values), keys, op2))
    }
  }
  pop_top(values)
}

///|
/// Sink one window operation into `input` as deep as the crossing rules
/// allow, wrapping the floor it reaches in the window node. The window
/// reads no columns, so the crossing gates are purely about row shape: a
/// `Select` must be row-stable *and* row-preserving (not an all-constant
/// collapse), a `WithColumns` row-stable. Everything else is a floor: a
/// `Filter` re-numbers positions by dropping rows, a `Sort` re-orders which
/// rows the window's offsets address, an `Aggregate` / `Join` reshapes rows
/// outright, another window is the deferred fusion case (min / offset
/// arithmetic across two windows, no consumer has asked), and the scans are
/// the floor — absorbing into a source's own row limit is future work with
/// the streaming reader. Iterative spine descent like `place_filter` —
/// total at any depth.
fn LogicalPlan::place_slice(
  self : LogicalPlan,
  window : FrameOp,
) -> LogicalPlan {
  let crossed : Array[(LogicalPlan) -> LogicalPlan] = []
  let mut cur = self
  let mut descending = true
  while descending {
    match cur {
      Unary(inner, Select(exprs)) =>
        if all_row_stable(exprs) && preserves_row_count(exprs) {
          crossed.push(ni => Unary(ni, Select(exprs)))
          cur = inner
        } else {
          descending = false
        }
      Unary(inner, WithColumns(exprs)) =>
        if all_row_stable(exprs) {
          crossed.push(ni => Unary(ni, WithColumns(exprs)))
          cur = inner
        } else {
          descending = false
        }
      // The floors: scans, filters, sorts, aggregations, joins, and any
      // other window sitting in the way.
      Scan(_)
      | Unary(_, _)
      | Join(_, _, _)
      | Aggregate(_, _, _)
      | AggregateAll(_, _, _) => descending = false
    }
  }
  let mut result = Unary(cur, window)
  for i = crossed.length() - 1; i >= 0; i = i - 1 {
    let rewrap = crossed[i]
    result = rewrap(result)
  }
  result
}
