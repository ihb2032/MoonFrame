// Whitebox pins for the nested dtypes' registry rows: the display
// spellings and the non-facts (not numeric, not orderable, no I64
// buffer to ride).

///|
test "the nested dtypes' registry rows" {
  // Display reads the profile row, so these two lines pin the row's
  // existence as well as its spelling.
  assert_eq(DataType::List(DataType::Int).to_string(), "List")
  assert_eq(DataType::Struct([("a", DataType::Int)]).to_string(), "Struct")
  // The nested dtypes are not numeric, not orderable, and ride no I64
  // buffer — the registry's `None` physical slot says no column
  // materialises on them yet.
  assert_eq(DataType::List(DataType::Int).i64_rider_scalar(7), None)
  assert_eq(DataType::Struct([("a", DataType::Int)]).i64_rider_scalar(7), None)
}
