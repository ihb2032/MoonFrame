///|
test "reader defaults share the same schema inference window" {
  let csv = @io.CsvReadOptions::CsvReadOptions()
  let json = @io.JsonReadOptions::JsonReadOptions()
  let ndjson = @io.JsonReadOptions::JsonReadOptions()
  assert_eq(csv.infer_schema_rows, 100)
  assert_eq(json.infer_schema_rows, csv.infer_schema_rows)
  assert_eq(ndjson.infer_schema_rows, csv.infer_schema_rows)
}

///|
test "dtypes overrides are copied at the options boundary" {
  // Building copies the caller's map, so a later mutation cannot reach the
  // reader — the same boundary the null-token list draws.
  let src : Map[String, @types.DataType] = Map([("a", @types.DataType::String)])
  let csv = @io.CsvReadOptions::CsvReadOptions(dtypes=src)
  let json = @io.JsonReadOptions::JsonReadOptions(dtypes=src)
  src["b"] = @types.DataType::Int
  assert_eq(csv.dtypes(), Map([("a", @types.DataType::String)]))
  assert_eq(json.dtypes(), Map([("a", @types.DataType::String)]))
  // The accessor hands out a copy too, so a caller cannot reach in and
  // change what the reader pins. Both default to the empty map.
  csv.dtypes()["c"] = @types.DataType::Bool
  assert_eq(csv.dtypes(), Map([("a", @types.DataType::String)]))
  assert_eq(@io.CsvReadOptions::CsvReadOptions().dtypes(), Map([]))
  assert_eq(@io.JsonReadOptions::JsonReadOptions().dtypes(), Map([]))
}
