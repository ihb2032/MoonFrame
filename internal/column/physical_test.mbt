///|
test "physical_type: the four concrete types map one-to-one; Null has none" {
  assert_eq(physical_type(@types.DataType::Int), Some(PhysicalType::I64))
  assert_eq(physical_type(@types.DataType::Float), Some(PhysicalType::F64))
  assert_eq(physical_type(@types.DataType::Bool), Some(PhysicalType::Bool))
  assert_eq(physical_type(@types.DataType::String), Some(PhysicalType::Utf8))
  // `Null` is a value-level concept with no physical backend, so it maps to
  // `None` — the type-level statement of why an all-null column can't be built.
  assert_eq(physical_type(@types.DataType::Null), None)
}

///|
test "PhysicalType Show and equality" {
  inspect(PhysicalType::I64, content="I64")
  inspect(PhysicalType::F64, content="F64")
  inspect(PhysicalType::Bool, content="Bool")
  inspect(PhysicalType::Utf8, content="Utf8")
  assert_eq(PhysicalType::I64, PhysicalType::I64)
  assert_not_eq(PhysicalType::I64, PhysicalType::F64)
}
