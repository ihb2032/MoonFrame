// Whitebox pins for the nested dtypes' registry rows: the display
// spellings (the category name with the shape spelled out) and the
// facts the rows state (not numeric, not summable, orderable by the
// nested sort order, no one physical buffer).

///|
test "the nested dtypes' registry rows" {
  // A nested dtype's spelling carries its shape: the element dtype, or
  // the fields in the struct's own order — a bare category name would
  // name every list dtype alike.
  assert_eq(DataType::List(DataType::Int).to_string(), "List(Int)")
  assert_eq(
    DataType::List(DataType::List(DataType::String)).to_string(),
    "List(List(String))",
  )
  assert_eq(
    DataType::Struct(
      Schema::Schema([
        Field::Field("a", DataType::Int),
        Field::Field("b", DataType::List(DataType::Int)),
      ]),
    ).to_string(),
    "Struct(a: Int, b: List(Int))",
  )
  assert_eq(DataType::Struct(Schema::Schema([])).to_string(), "Struct()")
  // The registry's own display name stays the bare category — the row
  // is per variant, and the shape rides `Show`, not the row.
  assert_eq(DataType::List(DataType::Int).dtype_profile().display, "List")
  // The nested dtypes are not numeric and not summable, they order (the
  // whole-frame extrema read the same total order the sort does), and
  // they ride no one physical buffer — a nested column's body is children
  // and offsets, which no buffer the registry names.
  for
    dtype in [
      DataType::List(DataType::Int),
      DataType::Struct(Schema::Schema([Field::Field("a", DataType::Int)])),
    ] {
    let row = dtype.dtype_profile()
    assert_true(row.physical is None)
    assert_eq(row.numeric, false)
    assert_eq(row.summable, false)
    assert_eq(row.orderable, true)
  }
  assert_eq(DataType::List(DataType::Int).i64_rider_scalar(7), None)
  assert_eq(
    DataType::Struct(Schema::Schema([Field::Field("a", DataType::Int)])).i64_rider_scalar(
      7,
    ),
    None,
  )
}
