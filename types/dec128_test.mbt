// Blackbox pins for the decimal128 engine's non-arithmetic surface:
// the constructors and predicates, the comparison family, the cohort
// reads and canonical member, the Int64 / Double conversions, and the
// parse / render forms. The arithmetic itself is pinned against the
// golden vectors (dec128_golden_test.mbt); here every spelling and
// defensive arm gets its own deterministic case.

///|
test "constructors and predicates name the exceptional shapes" {
  let nan = @types.Dec128::nan()
  assert_true(nan.is_nan())
  assert_false(nan.is_finite())
  assert_false(nan.is_infinite())
  // NaN's sign carries nothing.
  assert_false(nan.is_negative())
  assert_false(nan.is_zero())
  let inf = @types.Dec128::infinity()
  let ninf = @types.Dec128::infinity(neg=true)
  assert_true(inf.is_infinite())
  assert_false(inf.is_finite())
  assert_true(inf.is_negative() == false)
  assert_true(ninf.is_negative())
  assert_false(inf.is_zero())
  let z = @types.Dec128::zero()
  let nz = @types.Dec128::zero(neg=true)
  assert_true(z.is_finite())
  assert_true(z.is_zero())
  assert_true(nz.is_zero())
  assert_true(nz.is_negative())
  assert_false(z.is_nan())
  assert_false(z.is_infinite())
}

///|
test "of_int64 and of_int64_scale carry exact integers" {
  assert_eq(@types.Dec128::of_int64(0L).to_string(), "0.0")
  assert_eq(@types.Dec128::of_int64(42L).to_string(), "42.0")
  assert_eq(@types.Dec128::of_int64(-42L).to_string(), "-42.0")
  assert_eq(
    @types.Dec128::of_int64(-9_223_372_036_854_775_808L).to_string(),
    "-9223372036854775808.0",
  )
  assert_eq(
    @types.Dec128::of_int64(9_223_372_036_854_775_807L).to_string(),
    "9223372036854775807.0",
  )
  // The fixed-point lift: an unscaled magnitude under a scale.
  assert_eq(
    @types.Dec128::of_int64_scale(12345L, scale=2).to_string(),
    "123.45",
  )
  assert_eq(@types.Dec128::of_int64_scale(-5L, scale=2).to_string(), "-0.05")
  assert_eq(@types.Dec128::of_int64_scale(7L, scale=0).to_string(), "7.0")
  // A negative scale is an exponent lift; past Emax it is an infinity.
  assert_eq(
    @types.Dec128::of_int64_scale(1L, scale=-6144).to_string(),
    "1E6144",
  )
  assert_true(@types.Dec128::of_int64_scale(1L, scale=-6145).is_infinite())
  // Deep under the floor it is a (signed) zero.
  assert_true(
    @types.Dec128::of_int64_scale(1L, scale=6177).is_zero() &&
    @types.Dec128::of_int64_scale(1L, scale=6177).is_negative() == false,
  )
}

///|
test "exponent reads are the finite value's own" {
  let one_point_five = @types.Dec128::parse_opt("1.50").unwrap()
  assert_eq(one_point_five.exponent().unwrap(), -2)
  assert_eq(one_point_five.adjusted_exponent().unwrap(), 0)
  assert_true(@types.Dec128::nan().exponent() is None)
  assert_true(@types.Dec128::infinity().exponent() is None)
  assert_true(@types.Dec128::nan().adjusted_exponent() is None)
}

///|
test "coefficient digits keep the cohort's trailing zeros" {
  let v = @types.Dec128::parse_opt("1.50").unwrap()
  assert_eq(v.coefficient_digits().unwrap_or([]), [1, 5, 0])
  let z = @types.Dec128::zero()
  assert_eq(z.coefficient_digits().unwrap_or([-1]), [])
  assert_true(@types.Dec128::nan().coefficient_digits() is None)
  assert_true(@types.Dec128::infinity().coefficient_digits() is None)
}

///|
test "value equality folds the cohort and the signed zero" {
  let a = @types.Dec128::parse_opt("1.0").unwrap()
  let b = @types.Dec128::parse_opt("1.00").unwrap()
  assert_true(a.equal(b))
  let p0 = @types.Dec128::zero()
  let n0 = @types.Dec128::zero(neg=true)
  assert_true(p0.equal(n0))
  let nan = @types.Dec128::nan()
  assert_false(nan.equal(nan))
  assert_true(@types.Dec128::infinity().equal(@types.Dec128::infinity()))
  assert_false(
    @types.Dec128::infinity().equal(@types.Dec128::infinity(neg=true)),
  )
  // Different kinds never compare equal.
  assert_false(@types.Dec128::infinity().equal(@types.Dec128::of_int64(1L)))
  assert_false(@types.Dec128::of_int64(1L).equal(@types.Dec128::of_int64(2L)))
  // One zero against a nonzero.
  assert_false(@types.Dec128::zero().equal(@types.Dec128::of_int64(1L)))
}

///|
test "the total order sorts the exceptionals and the zeroes" {
  let nan = @types.Dec128::nan()
  let inf = @types.Dec128::infinity()
  let ninf = @types.Dec128::infinity(neg=true)
  let one = @types.Dec128::of_int64(1L)
  let neg_one = @types.Dec128::of_int64(-1L)
  assert_eq(nan.cmp_total(nan), 0)
  assert_true(nan.cmp_total(inf) > 0)
  assert_true(ninf.cmp_total(one) < 0)
  assert_true(one.cmp_total(inf) < 0)
  assert_eq(inf.cmp_total(@types.Dec128::infinity()), 0)
  assert_true(ninf.cmp_total(inf) < 0)
  assert_true(inf.cmp_total(ninf) > 0)
  // The zeroes share one bucket, either sign against either sign.
  let p0 = @types.Dec128::zero()
  let n0 = @types.Dec128::zero(neg=true)
  assert_eq(p0.cmp_total(n0), 0)
  assert_eq(n0.cmp_total(p0), 0)
  // Zero against a finite value: after every negative, before every
  // positive, its own sign unobservable.
  assert_true(n0.cmp_total(neg_one) > 0)
  assert_true(p0.cmp_total(neg_one) > 0)
  assert_true(n0.cmp_total(one) < 0)
  assert_true(p0.cmp_total(one) < 0)
  // Negative magnitudes reverse.
  assert_true(neg_one.cmp_total(@types.Dec128::of_int64(-2L)) > 0)
  assert_eq(one.cmp_total(@types.Dec128::of_int64(1L)), 0)
}

///|
test "the magnitude compare reads equal-adjusted digit strings" {
  // Same adjusted exponent, differing digits at a middle position —
  // the implicit-trailing-zero comparison path.
  let a = @types.Dec128::parse_opt("12.0").unwrap()
  let b = @types.Dec128::parse_opt("12.5").unwrap()
  let c = @types.Dec128::parse_opt("120").unwrap()
  assert_true(a.lt(b))
  assert_true(b.lt(c)) // 12.5 < 120: a larger adjusted exponent
  assert_true(a.equal(@types.Dec128::parse_opt("12.00").unwrap()))
  assert_true(c.gt(b))
  assert_true(a.le(b))
  assert_true(b.ge(a))
}

///|
test "the IEEE predicates are false on NaN" {
  let nan = @types.Dec128::nan()
  let one = @types.Dec128::of_int64(1L)
  assert_false(nan.lt(one))
  assert_false(one.lt(nan))
  assert_false(nan.le(one))
  assert_false(one.le(nan))
  assert_false(nan.gt(one))
  assert_false(one.gt(nan))
  assert_false(nan.ge(one))
  assert_false(one.ge(nan))
}

///|
test "canonical strips the cohort to one member" {
  let v = @types.Dec128::parse_opt("1.50").unwrap()
  let canon = v.canonical()
  assert_eq(canon.to_string(), "1.5")
  assert_eq(canon.exponent().unwrap(), -1)
  // Zero canonicalizes at exponent zero, sign kept.
  let nz = @types.Dec128::zero(neg=true).canonical()
  assert_true(nz.is_zero() && nz.is_negative())
  assert_eq(nz.exponent().unwrap(), 0)
  // The exceptionals are their own canonical shapes.
  assert_true(@types.Dec128::nan().canonical().is_nan())
  assert_true(@types.Dec128::infinity().canonical().is_infinite())
  // An already-canonical value stays put.
  let plain = @types.Dec128::parse_opt("1.5").unwrap()
  assert_eq(plain.canonical().exponent().unwrap(), -1)
}

///|
test "neg and abs flip and clear the sign" {
  assert_eq(@types.Dec128::of_int64(5L).neg().to_string(), "-5.0")
  assert_eq(@types.Dec128::of_int64(-5L).neg().to_string(), "5.0")
  // −0 negates to +0 and back, the sign a value's own.
  assert_true(@types.Dec128::zero(neg=true).neg().is_negative() == false)
  assert_true(@types.Dec128::zero().neg().is_negative())
  // NaN carries no sign to flip — negation is the identity.
  assert_true(@types.Dec128::nan().neg().is_nan())
  assert_eq(@types.Dec128::of_int64(-5L).abs().to_string(), "5.0")
  assert_true(@types.Dec128::nan().abs().is_nan())
  assert_true(@types.Dec128::infinity(neg=true).abs().is_infinite())
  assert_false(@types.Dec128::infinity(neg=true).abs().is_negative())
}

///|
test "to_int64 is exact integer digits or nothing" {
  assert_eq(@types.Dec128::of_int64(123L).to_int64(), Some(123L))
  assert_eq(
    @types.Dec128::of_int64(-9_223_372_036_854_775_808L).to_int64(),
    Some(-9_223_372_036_854_775_808L),
  )
  // A positive exponent shifts into integer digits.
  let e3 = @types.Dec128::parse_opt("1E+3").unwrap()
  assert_eq(e3.to_int64(), Some(1000L))
  // A negative exponent stays integral only when every dropped digit
  // is zero — 3.00 is 3, 2.50 is 2.5 and refuses.
  let t = @types.Dec128::parse_opt("3.00").unwrap()
  assert_eq(t.to_int64(), Some(3L))
  let half = @types.Dec128::parse_opt("2.50").unwrap()
  assert_true(half.to_int64() is None)
  // A real fraction refuses.
  let f = @types.Dec128::parse_opt("2.51").unwrap()
  assert_true(f.to_int64() is None)
  // Past the range refuses — including a shift past the workspace.
  let big = @types.Dec128::parse_opt("1E+4000").unwrap()
  assert_true(big.to_int64() is None)
  // The exceptionals refuse.
  assert_true(@types.Dec128::nan().to_int64() is None)
  assert_true(@types.Dec128::infinity().to_int64() is None)
}

///|
test "Double conversions map the exceptionals across" {
  assert_true(@types.Dec128::from_double(0.0 / 0.0).is_nan())
  assert_true(@types.Dec128::from_double(@double.infinity).is_infinite())
  assert_true(@types.Dec128::from_double(@double.neg_infinity).is_negative())
  let d = @types.Dec128::from_double(1.5)
  assert_eq(d.to_string(), "1.5")
  assert_eq(d.to_double(), 1.5)
  assert_true(@types.Dec128::nan().to_double().is_nan())
  assert_eq(@types.Dec128::infinity().to_double(), @double.infinity)
  assert_eq(@types.Dec128::infinity(neg=true).to_double(), @double.neg_infinity)
  // The negative zero carries across both ways.
  let nz = @types.Dec128::from_double(-0.0)
  assert_true(nz.is_zero() && nz.is_negative())
}

///|
test "parse reads the render's every form" {
  assert_eq(@types.Dec128::parse_opt("5").unwrap().to_string(), "5.0")
  assert_eq(@types.Dec128::parse_opt("+5").unwrap().to_string(), "5.0")
  assert_eq(@types.Dec128::parse_opt(".5").unwrap().to_string(), "0.5")
  assert_eq(@types.Dec128::parse_opt("-.5").unwrap().to_string(), "-0.5")
  assert_eq(@types.Dec128::parse_opt("5.").unwrap().to_string(), "5.0")
  assert_eq(@types.Dec128::parse_opt("1e3").unwrap().to_string(), "1000.0")
  assert_eq(@types.Dec128::parse_opt("1.5E+2").unwrap().to_string(), "150.0")
  assert_eq(@types.Dec128::parse_opt("15e-1").unwrap().to_string(), "1.5")
  assert_true(@types.Dec128::parse_opt("inf").unwrap().is_infinite())
  assert_true(@types.Dec128::parse_opt("+inf").unwrap().is_infinite())
  assert_true(@types.Dec128::parse_opt("-inf").unwrap().is_negative())
  assert_true(@types.Dec128::parse_opt("NaN").unwrap().is_nan())
  // The signed zero keeps its sign.
  assert_true(
    @types.Dec128::parse_opt("-0").unwrap().is_negative() &&
    @types.Dec128::parse_opt("-0").unwrap().is_zero(),
  )
  // A saturated exponent folds to the range clamps: a huge one is an
  // infinity, a tiny one a zero.
  assert_true(@types.Dec128::parse_opt("1E+9999999999").unwrap().is_infinite())
  assert_true(@types.Dec128::parse_opt("1E-9999999999").unwrap().is_zero())
  // Refused shapes.
  let refused : Array[String] = [
    "", "+", "-", "abc", "1.2.3", "1e", "1e+", "e5", "nan", "infinity", "1E", "-.e3",
    "0x10",
  ]
  for s in refused {
    assert_true(@types.Dec128::parse_opt(s) is None, msg="refused: " + s)
  }
}

///|
test "NaN inputs dominate every operation" {
  let nan = @types.Dec128::nan()
  let one = @types.Dec128::of_int64(1L)
  assert_true(nan.add(one).is_nan())
  assert_true(one.add(nan).is_nan())
  assert_true(nan.sub(one).is_nan())
  assert_true(one.sub(nan).is_nan())
  assert_true(nan.mul(one).is_nan())
  assert_true(one.mul(nan).is_nan())
  assert_true(nan.div(one).is_nan())
  assert_true(one.div(nan).is_nan())
}

///|
test "quantize passes the exceptionals and refuses impossible targets" {
  // NaN and ±∞ pass through as values — the round verb's contract.
  assert_true(@types.Dec128::nan().quantize(places=2).is_nan())
  assert_true(@types.Dec128::infinity().quantize(places=2).is_infinite())
  assert_true(
    @types.Dec128::infinity(neg=true).quantize(places=2).is_negative(),
  )
  // A target below the subnormal floor, and a value whose digits past
  // the target run beyond 34, are the quantize-invalid shape.
  let one = @types.Dec128::of_int64(1L)
  assert_true(one.quantize(places=6177).is_nan())
  let huge = @types.Dec128::parse_opt("1E+6144").unwrap()
  assert_true(huge.quantize(places=0).is_nan())
  let wide = @types.Dec128::parse_opt("1E+40").unwrap()
  assert_true(wide.quantize(places=1).is_nan())
  // A coarser target past every digit is the quantize-to-zero: the
  // value rounds to a zero carrying the target's own exponent.
  let z = wide.quantize(places=-80)
  assert_true(z.is_zero())
  assert_eq(z.exponent().unwrap(), 80)
}

///|
test "a literal past the workspace's digits rounds once, sticky and all" {
  // 80 significant digits: the tail past 70 folds into the sticky bit
  // (a nonzero one), the integer-part overflow scaling counted.
  let mut eighty = "1"
  for k in 0..<79 {
    eighty = eighty + (if k == 78 { "6" } else { "0" })
  }
  let v = @types.Dec128::parse_opt(eighty).unwrap()
  // 10^79 + 6 rounds to 34 digits: the 6 is 46 digits past the guard,
  // too small to move the tie — the value is exactly the cohort of
  // 1E+79.
  assert_true(v.equal(@types.Dec128::parse_opt("1E+79").unwrap()))
  // The same digits with a fraction tail: sticky only, no scaling.
  let frac = @types.Dec128::parse_opt("0." + eighty).unwrap()
  assert_true(frac.is_zero() == false)
  assert_true(frac.to_int64() is None)
}

///|
test "the exceptionals render their own spellings" {
  assert_eq(@types.Dec128::nan().to_string(), "NaN")
  assert_eq(@types.Dec128::infinity().to_string(), "inf")
  assert_eq(@types.Dec128::infinity(neg=true).to_string(), "-inf")
}

///|
test "the total order's mirrored pairs both read" {
  let one = @types.Dec128::of_int64(1L)
  let neg_one = @types.Dec128::of_int64(-1L)
  let nan = @types.Dec128::nan()
  let inf = @types.Dec128::infinity()
  // The mirrored alternatives of the rank and sign arms.
  assert_true(one.cmp_total(nan) < 0)
  assert_true(inf.cmp_total(one) > 0)
  assert_true(one.cmp_total(neg_one) > 0)
  assert_true(neg_one.cmp_total(one) < 0)
  // A larger adjusted exponent as the FIRST operand (the magnitude
  // compare's other orientation), and a longer digit string against a
  // shorter at the same adjusted exponent.
  let big = @types.Dec128::parse_opt("120").unwrap()
  let small = @types.Dec128::parse_opt("12.5").unwrap()
  assert_true(big.cmp_total(small) > 0)
  assert_true(small.cmp_total(big) < 0)
  let wide = @types.Dec128::parse_opt("12.05").unwrap()
  let narrow = @types.Dec128::parse_opt("12.5").unwrap()
  assert_true(wide.lt(narrow))
  assert_true(narrow.gt(wide))
}

///|
test "to_int64 refuses a magnitude past the range" {
  // 2^63 itself: one past Int64::MAX (the negative extreme reads back
  // exactly — of_int64 pins that elsewhere).
  let past = @types.Dec128::parse_opt("9223372036854775808").unwrap()
  assert_true(past.to_int64() is None)
  let neg_past = @types.Dec128::parse_opt("-9223372036854775809").unwrap()
  assert_true(neg_past.to_int64() is None)
}

///|
test "render picks positional inside its window and scientific beyond" {
  // The window's edges: adj 39 positional, adj 40 scientific; adj −6
  // positional, adj −7 scientific.
  let mut e39 = "1"
  for _ in 0..<39 {
    e39 = e39 + "0"
  }
  assert_eq(@types.Dec128::parse_opt("1E+39").unwrap().to_string(), e39 + ".0")
  assert_eq(@types.Dec128::parse_opt("1E+40").unwrap().to_string(), "1E40")
  assert_eq(@types.Dec128::parse_opt("1E-6").unwrap().to_string(), "0.000001")
  assert_eq(@types.Dec128::parse_opt("1E-7").unwrap().to_string(), "1E-7")
  // The cohort's trailing zeros render positionally too.
  assert_eq(@types.Dec128::parse_opt("1.50").unwrap().to_string(), "1.50")
  // A short coefficient under a large exponent pads integer zeros.
  assert_eq(@types.Dec128::parse_opt("1.5E+5").unwrap().to_string(), "150000.0")
  // Every rendering round-trips.
  for
    s in [
      "0.0", "-0.0", "1.5", "-1.5", "1E40", "-1E40", "1E-7", "123.456", "9.999999999999999999999999999999999E+6144",
      "1E-6176",
    ] {
    let v = @types.Dec128::parse_opt(s).unwrap()
    assert_eq(
      @types.Dec128::parse_opt(v.to_string()).unwrap().equal(v),
      true,
      msg="round-trip: " + s,
    )
  }
}
