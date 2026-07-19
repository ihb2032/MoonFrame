///|
test "reader defaults share the same schema inference window" {
  let csv = @io.CsvReadOptions::default()
  let json = @io.JsonReadOptions::default()
  let ndjson = @io.NdjsonReadOptions::default()
  assert_eq(csv.infer_schema_rows, 100)
  assert_eq(json.infer_schema_rows, csv.infer_schema_rows)
  assert_eq(ndjson.infer_schema_rows, csv.infer_schema_rows)
}
