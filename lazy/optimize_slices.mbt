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
/// outright — except a window sitting in the way, which is a *fusion*
/// candidate rather than a floor: the two windows compose into one
/// (`fuse_windows` states the arithmetic) and the descent continues with
/// the composite. The scans are the floor — absorbing into a source's own
/// row limit is future work with the streaming reader. Iterative spine
/// descent like `place_filter` — total at any depth.
fn LogicalPlan::place_slice(
  self : LogicalPlan,
  window : FrameOp,
) -> LogicalPlan {
  let crossed : Array[(LogicalPlan) -> LogicalPlan] = []
  let mut cur = self
  let mut window = window
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
      // Anything else blocks the descent — unless it is itself a window the
      // descending one composes with, in which case the inner window is
      // absorbed and the descent carries the composite downward.
      Unary(inner, blocking) =>
        match fuse_windows(window, blocking) {
          Some(fused) => {
            window = fused
            cur = inner
          }
          None => descending = false
        }
      // The floors: scans, filters, sorts, aggregations, joins.
      Scan(_) | Join(_, _, _) | Aggregate(_, _, _) | AggregateAll(_, _, _) =>
        descending = false
    }
  }
  let mut result = Unary(cur, window)
  for i = crossed.length() - 1; i >= 0; i = i - 1 {
    let rewrap = crossed[i]
    result = rewrap(result)
  }
  result
}

///|
/// Compose an outer window over an inner one, when the composite is itself
/// a window of the same vocabulary: `head` over `head` (and `tail` over
/// `tail`) keeps the smaller bound either way — the outer addresses rows
/// the inner already kept or would have kept, so whichever bound is tighter
/// decides; two `slice` windows with non-negative offsets compose by adding
/// the offsets and intersecting the spans, the available span under the
/// outer's start clamped to an empty window at zero. Every other pairing —
/// `head` over `tail` (opposite ends), a negative-offset `slice` (its
/// arithmetic reads the tail through a height the plan does not know), a
/// window over a non-window — has no composite here and stays a floor.
/// The composition is error-faithful by construction: windows carry no
/// expressions, so absorbing one never drops a stage's evaluation duty.
fn fuse_windows(outer : FrameOp, inner : FrameOp) -> FrameOp? {
  match (outer, inner) {
    (Head(a), Head(b)) => Some(Head(if a < b { a } else { b }))
    (Tail(a), Tail(b)) => Some(Tail(if a < b { a } else { b }))
    (Slice(ao, alen), Slice(bo, blen)) if ao >= 0 && bo >= 0 => {
      // The outer window reads the inner's rows `[ao, ao + alen)`; the inner
      // supplies `[bo, bo + blen)`. Their composition reads the original's
      // `[bo + ao, bo + ao + len)` with `len` the intersection of the two
      // spans — `blen - ao` available, `alen` asked, an empty window when
      // the outer starts past the inner's end.
      let reach = blen.map(m => m - ao)
      let len : Int? = match (alen, reach) {
        (Some(l), Some(r)) => Some(if l < r { l } else { r })
        (Some(l), None) => Some(l)
        (None, Some(r)) => Some(r)
        (None, None) => None
      }
      Some(Slice(bo + ao, len.map(l => if l > 0 { l } else { 0 })))
    }
    _ => None
  }
}
