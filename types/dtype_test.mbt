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
test "comparable_with: same dtype or two numerics" {
  assert_true(DataType::Date.comparable_with(DataType::Date))
  assert_true(DataType::Int.comparable_with(DataType::Float))
  assert_true(DataType::Float.comparable_with(DataType::Int))
  // The I64 rider never compares against the plain Int.
  assert_false(DataType::Date.comparable_with(DataType::Int))
  assert_false(DataType::String.comparable_with(DataType::Int))
  assert_false(DataType::Bool.comparable_with(DataType::Date))
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
