// Blackbox tests for the positional lazy verbs — `top_k` / `bottom_k` /
// `gather_every` as their own `FrameOp` nodes (single nodes rather than
// compositions, so the eager verbs' argument validation surfaces at collect
// with the eager error), and `first` / `last` as one-row `slice` windows
// (the composition IS the eager semantic). Pinned: collect parity with the
// eager verbs, the plan renderings, the collect-time validation, and the
// projection pass's treatment of the ranking nodes' key reads.

///|
fn stride_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2, 3, 4]),
    @series.Series::from_ints("v", [10, 30, 20, 40]),
  ])
}

///|
test "top_k / bottom_k / gather_every collect to their eager equivalents" {
  let df = stride_df()
  assert_eq(
    LazyFrame::LazyFrame(df).top_k(2, by=[@expr.col("v")]).collect(),
    df.top_k(2, by=[@expr.col("v")]),
  )
  assert_eq(
    LazyFrame::LazyFrame(df)
    .bottom_k(2, by=[@expr.col("v")], reverse=true)
    .collect(),
    df.bottom_k(2, by=[@expr.col("v")], reverse=true),
  )
  assert_eq(
    LazyFrame::LazyFrame(df).gather_every(2, offset=1).collect(),
    df.gather_every(2, offset=1),
  )
}

///|
test "first / last collect to one-row windows, empty staying empty" {
  let df = stride_df()
  assert_eq(LazyFrame::LazyFrame(df).first().collect(), df.slice(0, length=1))
  assert_eq(LazyFrame::LazyFrame(df).last().collect(), df.slice(-1))
  // A 0-row input keeps zero rows — the window closes, no row is invented.
  let empty = @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [])])
  assert_eq(LazyFrame::LazyFrame(empty).first().collect().shape(), (0, 1))
  assert_eq(LazyFrame::LazyFrame(empty).last().collect().shape(), (0, 1))
}

///|
test "explain renders the ranking and stride nodes" {
  let base = LazyFrame::LazyFrame(stride_df())
  let scans = "\n  SCAN [4×2]"
  assert_eq(
    base.top_k(2, by=[@expr.col("v")]).explain(),
    "TOP_K 2 [col(v)]\{scans}",
  )
  // `reverse` shows only when set — the `UNIQUE` keep-strategy convention.
  assert_eq(
    base.top_k(2, by=[@expr.col("v")], reverse=true).explain(),
    "TOP_K 2 [col(v)] reverse\{scans}",
  )
  assert_eq(
    base.bottom_k(3, by=[@expr.col("v")]).explain(),
    "BOTTOM_K 3 [col(v)]\{scans}",
  )
  assert_eq(
    base.bottom_k(3, by=[@expr.col("v")], reverse=true).explain(),
    "BOTTOM_K 3 [col(v)] reverse\{scans}",
  )
  assert_eq(base.gather_every(3).explain(), "GATHER_EVERY 3 OFFSET 0\{scans}")
  assert_eq(
    base.gather_every(3, offset=1).explain(),
    "GATHER_EVERY 3 OFFSET 1\{scans}",
  )
  // The one-row windows are `slice` spellings, so they explain as one.
  assert_eq(base.first().explain(), "SLICE [0: 1]\{scans}")
  assert_eq(base.last().explain(), "SLICE [-1: ]\{scans}")
}

///|
test "the ranking verbs' argument validation surfaces at collect" {
  // The node defers the tag; the eager verb's `InvalidOperation` for a
  // negative `k` or an empty `by` arrives from collect — the layers'
  // failures stay identical (why these are nodes, not compositions).
  let base = LazyFrame::LazyFrame(stride_df())
  assert_true(
    (Ok(base.top_k(-1, by=[@expr.col("v")]).collect()) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(base.bottom_k(1, by=[]).collect()) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(base.gather_every(0).collect()) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a ranking node's key reads survive a projection above it" {
  // `select` narrows to `id`, but the `top_k` underneath ranks by `v` — its
  // key read keeps `v` alive through the projection pass, and collect
  // matches the eager chain instead of raising `ColumnNotFound`.
  let df = stride_df()
  let plan = LazyFrame::LazyFrame(df)
    .select([@expr.col("id"), @expr.col("v")])
    .top_k(1, by=[@expr.col("v")])
  assert_eq(
    plan.collect(),
    df.select([@expr.col("id"), @expr.col("v")]).top_k(1, by=[@expr.col("v")]),
  )
  // The optimized plan carries the widened requirement: no `SELECT` narrows
  // below the ranking node (it reads `v` whatever the parent needs).
  assert_eq(
    plan.explain(optimized=true),
    "TOP_K 1 [col(v)]\n  SELECT [col(id), col(v)]\n    SCAN [4×2]",
  )
}
