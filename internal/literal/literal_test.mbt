// Blackbox tests for the shared literal renderer.

///|
test "format_scalar: every variant in display syntax" {
  assert_eq(format_scalar(@types.Scalar::Int(42)), "42")
  assert_eq(format_scalar(@types.Scalar::Bool(true)), "true")
  assert_eq(format_scalar(@types.Scalar::Null), "null")
  // A string is quoted and escaped, unlike `to_string()`'s bare form.
  assert_eq(format_scalar(@types.Scalar::String("a\"b")), "\"a\\\"b\"")
}

///|
test "format_scalar: a Float literal stays distinct from an Int one" {
  // A fractional value already carries its point.
  assert_eq(format_scalar(@types.Scalar::Float(1.5)), "1.5")
  // A finite whole value gets the `.0` `Double::to_string` drops.
  assert_eq(format_scalar(@types.Scalar::Float(1.0)), "1.0")
  assert_eq(format_scalar(@types.Scalar::Float(0.0)), "0.0")
  // Negative zero re-adds the sign from the sign bit.
  assert_eq(format_scalar(@types.Scalar::Float(-0.0)), "-0.0")
  // Non-finite values keep their own spelling.
  assert_eq(format_scalar(@types.Scalar::Float(0.0 / 0.0)), "NaN")
  assert_eq(format_scalar(@types.Scalar::Float(1.0 / 0.0)), "Infinity")
  assert_eq(format_scalar(@types.Scalar::Float(-1.0 / 0.0)), "-Infinity")
}
