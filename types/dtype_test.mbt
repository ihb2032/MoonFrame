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
