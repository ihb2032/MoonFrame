// Property-based tests (quickcheck) for the `io` package: CSV, JSON, and
// NDJSON are faithful round-trips. We check a *text fixpoint* — parsing
// emitted text and re-emitting it reproduces the text exactly — which
// validates that reader and writer agree on the wire format, without
// coupling the property to the DataFrame's internal schema-flag
// representation.

///|
/// A non-empty `Array[Int64]` of length `1..=max_len`. We avoid the 0-row
/// frame, whose emitted header alone carries no values for schema inference to
/// recover the Int dtype from.
fn gen_i64_array(max_len : Int) -> @gen.Gen[Array[Int64]] {
  @gen.int_range(1, max_len).bind(n => {
    @gen.int_range(-1000, 1000).fmap(x => x.to_int64()).array_with_size(n)
  })
}

///|
fn prop_csv_roundtrip(xs : Array[Int64]) -> Bool {
  try {
    let df = @frame.DataFrame::new([@series.Series::from_ints("x", xs)])
    let text = @io.format_csv(df, @io.CsvWriteOptions::default())
    let back = @io.parse_csv_str(text, @io.CsvReadOptions::default())
    @io.format_csv(back, @io.CsvWriteOptions::default()) == text
  } catch {
    _ => false
  }
}

///|
fn prop_json_roundtrip(xs : Array[Int64]) -> Bool {
  try {
    let df = @frame.DataFrame::new([@series.Series::from_ints("x", xs)])
    let text = @io.format_json_records(df)
    let back = @io.parse_json_records_str(text, @io.JsonReadOptions::default())
    @io.format_json_records(back) == text
  } catch {
    _ => false
  }
}

///|
fn prop_ndjson_roundtrip(xs : Array[Int64]) -> Bool {
  try {
    let df = @frame.DataFrame::new([@series.Series::from_ints("x", xs)])
    let text = @io.format_ndjson(df)
    let back = @io.parse_ndjson_str(text, @io.NdjsonReadOptions::default())
    @io.format_ndjson(back) == text
  } catch {
    _ => false
  }
}

///|
test "property: CSV round-trips a single Int column" {
  @qc.quick_check(@qc.forall(gen_i64_array(30), prop_csv_roundtrip))
}

///|
test "property: JSON round-trips a single Int column" {
  @qc.quick_check(@qc.forall(gen_i64_array(30), prop_json_roundtrip))
}

///|
test "property: NDJSON round-trips a single Int column" {
  @qc.quick_check(@qc.forall(gen_i64_array(30), prop_ndjson_roundtrip))
}
