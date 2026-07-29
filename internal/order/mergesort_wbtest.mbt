// Whitebox pin for the stable merge-sort scheduler's overflow boundary.
// Real arrays large enough to reach width 2^30 are unsuitable for a unit test,
// so the total arithmetic helper is tested directly without allocation.

///|
test "next_merge_width doubles only while the result stays below n" {
  assert_eq(next_merge_width(1, 3), Some(2))
  assert_eq(next_merge_width(2, 5), Some(4))
  assert_eq(next_merge_width(1, 2), None)
  assert_eq(next_merge_width(4, 5), None)
}

///|
test "next_merge_width stops at the 2^30 Int overflow boundary" {
  let max_int = 0x7fffffff
  assert_eq(next_merge_width(0x20000000, max_int), Some(0x40000000))
  assert_eq(next_merge_width(0x40000000, max_int), None)
}

///|
test "next_merge_width is total outside scheduler invariants" {
  let max_int = 0x7fffffff
  assert_eq(next_merge_width(0, max_int), None)
  assert_eq(next_merge_width(-1, max_int), None)
  assert_eq(next_merge_width(1, -0x7fffffff - 1), None)
  assert_eq(next_merge_width(max_int, max_int), None)
}
