///|
test "key_cell normalises each Scalar variant" {
  // Direct pins for the single-cell spelling `mode`'s windowed reduction
  // rides — the column path (key_cells) reads the buffer, so these arms
  // need their own witness.
  assert_true(key_cell(@types.Scalar::Int(5L)) == KInt(5L))
  assert_true(key_cell(@types.Scalar::Float(-0.0)) == KFloat(0.0))
  assert_true(key_cell(@types.Scalar::Float(@double.not_a_number)) == KNaN)
  assert_true(key_cell(@types.Scalar::Bool(true)) == KBool(true))
  assert_true(key_cell(@types.Scalar::String("x")) == KStr("x"))
  assert_true(key_cell(@types.Scalar::Date(11016L)) == KInt(11016L))
  assert_true(key_cell(@types.Scalar::Timestamp(1L)) == KInt(1L))
  assert_true(key_cell(@types.Scalar::Decimal(2, 25L)) == KInt(25L))
  assert_true(key_cell(@types.Scalar::Null) == KNull)
}
