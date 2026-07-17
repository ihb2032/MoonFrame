// Adversarial round-trip corpus for CSV / JSON-records / NDJSON. Each fixture
// frame is checked for the **text fixpoint** `emit(parse(emit(df))) == emit(df)`
// on all three formats: the writer's output, parsed back and re-emitted,
// reproduces itself. This validates reader/writer agreement on the wire format
// over hostile data — embedded quotes / commas / newlines / unicode in strings,
// nulls, empty strings, big `Int64`s past 2^53, non-integral and signed-zero
// floats, and multi-column mixes — without coupling to the frame's internal
// dtype flags, and it stays stable under the documented lossy narrowings
// (integral `Float`→`Int` in JSON, all-null→`String`), which happen on the
// first emit and are therefore already fixed points. Complements the generated
// single-Int property in `property_test.mbt` and the per-caveat unit tests in
// `csv_test.mbt` / `json_test.mbt` / `ndjson_test.mbt`.

///|
/// Assert the text fixpoint `emit(parse(emit(df))) == emit(df)` on every format
/// for one frame; the enclosing test's name identifies the fixture on failure.
fn assert_roundtrip_fixpoint(df : @frame.DataFrame) -> Unit raise {
  let csv = @io.format_csv(df, @io.CsvWriteOptions::default())
  assert_eq(
    @io.format_csv(
      @io.parse_csv_str(csv, @io.CsvReadOptions::default()),
      @io.CsvWriteOptions::default(),
    ),
    csv,
  )
  let json = @io.format_json_records(df)
  assert_eq(
    @io.format_json_records(
      @io.parse_json_records_str(json, @io.JsonReadOptions::default()),
    ),
    json,
  )
  let ndjson = @io.format_ndjson(df)
  assert_eq(
    @io.format_ndjson(
      @io.parse_ndjson_str(ndjson, @io.NdjsonReadOptions::default()),
    ),
    ndjson,
  )
}

///|
test "round-trip: hostile string cells survive every format's escaping" {
  // Every character class a CSV / JSON writer has to escape, plus lookalikes
  // (a string that reads as a number / a bool must stay a string on read-back).
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", [
      "", // empty
       "a,b", // CSV delimiter
       "a\"b", // embedded quote
       "a\nb", // embedded newline
       "a\r\nb", // CRLF
       "  spaced  ", // leading / trailing spaces
       "a\tb", // tab
       "line\\back", // backslash (JSON escape)
       "123", // numeric lookalike
       "true", // bool lookalike
       "héllo😀", // multi-byte / astral unicode
       "null", // null lookalike
    ]),
  ])
  assert_roundtrip_fixpoint(df)
}

///|
test "round-trip: numeric edges (big Int64, non-integral and signed-zero Float)" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("i", [
      0L, -1L, 9223372036854775807L, // Int64::MAX
       -9223372036854775808L, // Int64::MIN
       9007199254740993L, // > 2^53, inexact as a Double
    ]),
    @series.Series::from_floats("f", [1.5, -2.5, 0.0, -0.0, 100.25]),
  ])
  assert_roundtrip_fixpoint(df)
}

///|
test "round-trip: nulls in every dtype, mixed columns" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("i", [Some(1L), None, Some(-3L)]),
    @series.Series::from_float_options("f", [None, Some(2.5), None]),
    @series.Series::from_string_options("s", [Some("x"), Some(""), None]),
    @series.Series::from_bool_options("b", [Some(true), None, Some(false)]),
  ])
  assert_roundtrip_fixpoint(df)
}

///|
test "round-trip: Bool column and a header that needs quoting" {
  let df = @frame.DataFrame::new([
    @series.Series::from_bools("has,comma", [true, false, true]),
    @series.Series::from_strings("with\"quote", ["a", "b", "c"]),
  ])
  assert_roundtrip_fixpoint(df)
}

///|
test "round-trip: shape edges (single row, single column, wide frame)" {
  assert_roundtrip_fixpoint(
    @frame.DataFrame::new([
      @series.Series::from_ints("a", [42L]),
      @series.Series::from_strings("b", ["only"]),
    ]),
  )
  assert_roundtrip_fixpoint(
    @frame.DataFrame::new([@series.Series::from_strings("c", ["p", "q", "r"])]),
  )
}
