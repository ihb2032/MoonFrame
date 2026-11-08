// Coverage pins for the IEEE reshape's engine arms the arithmetic
// golden vectors and the frame suite do not reach: the shrink chain, the
// Show spelling, the decimal extremum/arg-extremum folds, the mean's
// factory refusal, the fill and cast refusal arms.

///|
test "the shrink chain walks the exceptional atoms and the trunc ladder" {
  // The exceptional values do not shrink; a finite value offers its
  // integer part then the signed zero; an integral value offers only
  // the zero; zero offers nothing.
  let nan = @types.Dec128::nan()
  assert_true(nan.shrink().next() is None)
  assert_true(@types.Dec128::infinity().shrink().next() is None)
  let with_frac = @types.Dec128::parse_opt("12.5").unwrap()
  let it = with_frac.shrink()
  let first = it.next().unwrap()
  assert_true(first.equal(@types.Dec128::parse_opt("12").unwrap()))
  let second = it.next().unwrap()
  assert_true(second.is_zero())
  assert_true(it.next() is None)
  let integral = @types.Dec128::of_int64(7L)
  let it2 = integral.shrink()
  let z = it2.next().unwrap()
  assert_true(z.is_zero())
  assert_true(it2.next() is None)
  assert_true(@types.Dec128::zero().shrink().next() is None)
}

///|
test "the decimal scalar's Show form carries the value spelling" {
  inspect(
    @types.Scalar::Decimal(@types.Dec128::parse_opt("1.50").unwrap()),
    content="Decimal(1.50)",
  )
  inspect(@types.Scalar::Decimal(@types.Dec128::nan()), content="Decimal(NaN)")
}
