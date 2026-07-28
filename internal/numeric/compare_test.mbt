///|
test "double_fits_int64 boundaries" {
  // In range: zero and the exact representable Int64 bounds.
  assert_true(double_fits_int64(0.0))
  assert_true(double_fits_int64(-9223372036854775808.0)) // Int64::MIN, exact
  assert_true(double_fits_int64(9223372036854774784.0)) // largest Double < 2^63
  // Out of range: below the minimum, and above the representable maximum.
  assert_false(double_fits_int64(-9300000000000000000.0))
  assert_false(double_fits_int64(9223372036854775808.0)) // 2^63
}
