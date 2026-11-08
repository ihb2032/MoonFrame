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
  // The swapped operand order reaches the same wrapped MIN, where the
  // verification division would be MIN / -1 — the one quotient Int64
  // division traps on — so the pair is refused before it divides.
  assert_true(@numeric.mul_checked(-1L, -9_223_372_036_854_775_808L) is None)
  assert_eq(
    @numeric.mul_checked(-9_223_372_036_854_775_808L, 1L),
    Some(-9_223_372_036_854_775_808L),
  )
}

///|
test "checked subtract decides the MIN subtrahend directly" {
  assert_eq(@numeric.sub_checked(5L, 3L), Some(2L))
  assert_eq(@numeric.sub_checked(-5L, -3L), Some(-2L))
  assert_eq(@numeric.sub_checked(0L, 7L), Some(-7L))
  // A MIN minuend overflowed by any positive subtrahend.
  assert_true(@numeric.sub_checked(-9_223_372_036_854_775_808L, 5L) is None)
  // A MIN subtrahend: negating it would wrap, so only a negative minuend
  // lands in range — -1 - MIN is exactly MAX — and a non-negative one
  // refuses.
  assert_eq(
    @numeric.sub_checked(-1L, -9_223_372_036_854_775_808L),
    Some(9_223_372_036_854_775_807L),
  )
  assert_eq(
    @numeric.sub_checked(
      -9_223_372_036_854_775_808L, -9_223_372_036_854_775_808L,
    ),
    Some(0L),
  )
  assert_true(@numeric.sub_checked(5L, -9_223_372_036_854_775_808L) is None)
  assert_true(@numeric.sub_checked(0L, -9_223_372_036_854_775_808L) is None)
}
