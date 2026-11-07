// Whitebox pins for the decimal128 engine's internal machinery — the
// workspace helpers' degenerate calls, the finisher's range corners,
// the saturating exponent arithmetic, and the long divider's
// overshoot correction — the arms the public surface cannot reach
// with well-formed values alone.

///|
test "the workspace helpers refuse degenerate shifts" {
  let fa = dec_work()
  fa[0] = 42L
  dec_shift_left(fa, 0)
  assert_eq(fa[0], 42L)
  let (guard_digit, tail) = dec_drop_digits(fa, 0)
  assert_eq(guard_digit, 0)
  assert_true(!tail)
}

///|
test "exponent arithmetic saturates instead of wrapping" {
  assert_eq(dec_add_i32(2_147_483_647, 1), 2_147_483_647)
  assert_eq(dec_add_i32(-2_147_483_648, -1), -2_147_483_648)
}

///|
test "the finisher's range corners" {
  // A zero coefficient clamps its stored exponent into the format —
  // a saturated one past Emax, a saturated one below Etiny.
  let z_hi = dec_work()
  let (v_hi, _) = dec_finish(false, z_hi, 2_000_000_000, false)
  assert_true(v_hi.is_zero())
  assert_eq(v_hi.exponent().unwrap(), dec_emax)
  let z_lo = dec_work()
  let (v_lo, _) = dec_finish(false, z_lo, -2_000_000_000, false)
  assert_true(v_lo.is_zero())
  assert_eq(v_lo.exponent().unwrap(), dec_etiny)
  // The all-nines round-up at the subnormal floor lands on 10^34 —
  // one exponent coarser, the format's smallest normal boundary: 35
  // nines at Etiny−1 (a value just under 1E-6142) rounds up through
  // the carry to 10^33 at Etiny+1 (rendered with its cohort's 33
  // trailing zeros — the value is 1E-6142).
  let nines = dec_work()
  nines[3] = 99999999L // 8 digits — 35 with the three limbs below
  nines[2] = 999999999L
  nines[1] = 999999999L
  nines[0] = 999999999L
  let (v_sub, _) = dec_finish(false, nines, dec_etiny - 1, false)
  assert_true(v_sub.equal(Dec128::parse_opt("1E-6142").unwrap()))
  assert_eq(v_sub.exponent().unwrap(), dec_etiny + 1)
}

///|
test "the long divider's overshoot correction fires" {
  // A remainder window whose top estimate overstates the quotient —
  // q·divisor past the remainder — so the correction walks it back.
  let rem = FixedArray::makei(dec_work_limbs + 1, _ => 0L)
  let divisor = dec_work()
  divisor[0] = 999999999L
  divisor[1] = 999999999L
  rem[0] = 1L
  assert_true(dec_rem_lt_mul(rem, divisor, 999999999L))
}

///|
test "the divider's guard scaling clamps at zero" {
  // A dividend with more digits than the guard width wants — the
  // scale lands negative and clamps to none, and the exact quotient
  // already sits at the preferred exponent (the refinement's early
  // return).
  let mut thirty_eights = "9"
  for _ in 0..<37 {
    thirty_eights = thirty_eights + "9"
  }
  let a = Dec128::parse_opt(thirty_eights).unwrap()
  let b = Dec128::of_int64(1L)
  let q = a.div(b)
  assert_true(q.is_finite())
  assert_eq(q.exponent().unwrap(), a.exponent().unwrap())
}
