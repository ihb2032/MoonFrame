///|
test "DataType predicates" {
  assert_true(DataType::Int.is_integer())
  assert_true(DataType::Int.is_numeric())
  assert_false(DataType::Int.is_float())
  assert_false(DataType::Int.is_bool())
  assert_false(DataType::Int.is_string())
  assert_true(DataType::Float.is_float())
  assert_true(DataType::Float.is_numeric())
  assert_false(DataType::Float.is_integer())
  assert_true(DataType::Bool.is_bool())
  assert_false(DataType::Bool.is_numeric())
  assert_true(DataType::String.is_string())
  assert_false(DataType::String.is_numeric())
  assert_false(DataType::Null.is_numeric())
  assert_false(DataType::Null.is_integer())
  assert_false(DataType::Null.is_float())
  assert_false(DataType::Null.is_bool())
  assert_false(DataType::Null.is_string())
}

///|
test "DataType Show output" {
  inspect(DataType::Int, content="Int")
  inspect(DataType::Float, content="Float")
  inspect(DataType::Bool, content="Bool")
  inspect(DataType::String, content="String")
  inspect(DataType::Null, content="Null")
}

///|
test "DataType equality is structural" {
  assert_eq(DataType::Int, DataType::Int)
  assert_not_eq(DataType::Int, DataType::Float)
  assert_not_eq(DataType::Null, DataType::Int)
}

///|
test "DataType physical: the four concrete types map one-to-one; Null has none" {
  assert_eq(DataType::Int.physical(), Some(PhysicalType::I64))
  assert_eq(DataType::Float.physical(), Some(PhysicalType::F64))
  assert_eq(DataType::Bool.physical(), Some(PhysicalType::Bool))
  assert_eq(DataType::String.physical(), Some(PhysicalType::Utf8))
  // `Null` is a value-level concept with no physical backend, so it maps to
  // `None` — the type-level statement of why an all-null column can't be built.
  assert_eq(DataType::Null.physical(), None)
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
