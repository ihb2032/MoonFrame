// Direct pins for the checked primitives' own contracts: the guards the
// kernel's gates make unreachable from expression level (a narrowing
// rescale, the zero-scale identity) hold here.

///|
test "rescale refuses narrowing and keeps identity" {
  assert_true(@numeric.rescale_unscaled(2, 1, 123L) is None)
  assert_true(@numeric.rescale_unscaled(2, 2, 123L) is None)
  assert_eq(@numeric.rescale_unscaled(1, 3, 15L), Some(1500L))
  assert_true(
    @numeric.rescale_unscaled(0, 18, 9_000_000_000_000_000_000L) is None,
  )
}

///|
test "checked multiply catches the MIN edge" {
  assert_eq(@numeric.mul_checked(3L, 4L), Some(12L))
  assert_eq(@numeric.mul_checked(-3L, 4L), Some(-12L))
  assert_true(
    @numeric.mul_checked(4_000_000_000_000_000_000L, 4_000_000_000_000_000_000L)
    is None,
  )
  // MIN * -1 wraps to MIN on plain Int64; the divide-back check catches it.
  assert_true(@numeric.mul_checked(-9_223_372_036_854_775_808L, -1L) is None)
}
