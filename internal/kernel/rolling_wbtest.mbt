// Whitebox pins for the rescan extrema fold `float_rolling_stat` still
// carries — the dispatch routes the rolling extrema through the
// monotonic-deque pass, so these arms answer only if a future change
// routes them again; the verdicts here are the reference they must keep.

///|
test "the rescan extrema fold keeps its reference verdicts" {
  assert_eq(float_rolling_stat(Min, [3.0, 1.0, 2.0], false, 3), Some(1.0))
  assert_eq(float_rolling_stat(Max, [3.0, 1.0, 2.0], false, 3), Some(3.0))
  // NaN is no candidate and an all-NaN window is the no-value null —
  // the semantics the deque pass reproduces.
  assert_eq(float_rolling_stat(Min, [], true, 2), None)
  assert_eq(float_rolling_stat(Max, [], true, 1), None)
}
