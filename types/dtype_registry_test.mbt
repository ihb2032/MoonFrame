// Registry behavior pins: the physical mapping, the display names, the
// numericity flag, and the pair-comparability gate — each read through the
// accessor the engine packages use, so the registry's rows stay honest.

///|
test "physical: the concrete dtypes map to their buffers; Null has none" {
  assert_true(DataType::Int.physical() is Some(PhysicalType::I64))
  assert_true(DataType::Float.physical() is Some(PhysicalType::F64))
  assert_true(DataType::Bool.physical() is Some(PhysicalType::Bool))
  assert_true(DataType::String.physical() is Some(PhysicalType::Utf8))
  // The value-level Null has no storable representation...
  assert_true(DataType::Null.physical() is None)
  // ...and Date rides the existing I64 buffer — the whole point of the
  // registry's identity/representation split.
  assert_true(DataType::Date.physical() is Some(PhysicalType::I64))
}

///|
test "display names are the registered spellings" {
  // Read through the public Show rendering, which the registry feeds.
  assert_eq(DataType::Int.to_string(), "Int")
  assert_eq(DataType::Float.to_string(), "Float")
  assert_eq(DataType::Bool.to_string(), "Bool")
  assert_eq(DataType::String.to_string(), "String")
  assert_eq(DataType::Date.to_string(), "Date")
  assert_eq(DataType::Null.to_string(), "Null")
}

///|
test "numericity: Int and Float only, however the buffers align" {
  assert_true(DataType::Int.is_numeric())
  assert_true(DataType::Float.is_numeric())
  assert_false(DataType::Bool.is_numeric())
  assert_false(DataType::String.is_numeric())
  // Date is I64-typed but is not a number: summing day-counts is a bug.
  assert_false(DataType::Date.is_numeric())
  assert_false(DataType::Null.is_numeric())
}

///|
test "comparable_with: same dtype or two numerics" {
  assert_true(DataType::Date.comparable_with(DataType::Date))
  assert_true(DataType::Int.comparable_with(DataType::Float))
  assert_true(DataType::Float.comparable_with(DataType::Int))
  // The I64 rider never compares against the plain Int.
  assert_false(DataType::Date.comparable_with(DataType::Int))
  assert_false(DataType::String.comparable_with(DataType::Int))
  assert_false(DataType::Bool.comparable_with(DataType::Date))
}
