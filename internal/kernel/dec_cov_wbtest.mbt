// Whitebox coverage pins for the kernel's decimal gates — through the
// package's own private entries (`eval_add` and kin), which the expr
// layer reaches only cross-package (where the coverage gate does not
// count).

///|
test "the decimal gates answer every pairing shape" {
  let dec = @series.Series::from_decimals("d", [
    Some(@types.Dec128::of_int64(6L)),
    None,
  ])
  let int = @series.Series::from_int_options("i", [Some(3L), None])
  let float = @series.Series::from_float_options("f", [Some(0.5), None])
  // add / sub / mul over every eligible pairing: Dec×Dec, Dec×Int,
  // Int×Dec — the null propagation included.
  let sum = eval_add(dec, dec)
  assert_true(
    sum.get(0) is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::of_int64(12L)),
  )
  assert_true(sum.get(1) is @types.Scalar::Null)
  let lifted = eval_mul(dec, int)
  assert_true(
    lifted.get(0) is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::of_int64(18L)),
  )
  assert_true(lifted.get(1) is @types.Scalar::Null)
  let diff = eval_sub(int, dec)
  assert_true(
    diff.get(0) is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::of_int64(-3L)),
  )
  assert_true(diff.get(1) is @types.Scalar::Null)
  // The division gate: Dec÷Int stays Decimal (a null on either side
  // nulls the cell).
  let quot = eval_div(dec, int)
  assert_true(
    quot.get(0) is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::of_int64(2L)),
  )
  assert_true(quot.get(1) is @types.Scalar::Null)
  // The mixed gate: Dec op Float promotes through the correctly-rounded
  // Double conversion, a null on either side nulling the cell.
  let mixed = eval_add(dec, float)
  assert_true(mixed.get(0) is @types.Scalar::Float(6.5))
  assert_true(mixed.get(1) is @types.Scalar::Null)
  let mixed_div = eval_div(float, dec)
  assert_true(mixed_div.get(0) is @types.Scalar::Float(0.08333333333333333))
  assert_true(mixed_div.get(1) is @types.Scalar::Null)
  // The arith and div gates read a shorter right operand's length.
  let a = @series.Series::from_decimals("a", [
    Some(@types.Dec128::of_int64(1L)),
    Some(@types.Dec128::of_int64(2L)),
  ])
  let b = @series.Series::from_decimals("b", [Some(@types.Dec128::of_int64(3L))])
  assert_eq(eval_add(a, b).len(), 1)
  assert_eq(eval_div(a, b).len(), 1)
}
