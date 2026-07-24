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
  let csv = @io.format_csv(df)
  assert_eq(@io.format_csv(@io.parse_csv_str(csv)), csv)
  let json = @io.format_json(df)
  assert_eq(@io.format_json(@io.parse_json_str(json)), json)
  let ndjson = @io.format_ndjson(df)
  assert_eq(@io.format_ndjson(@io.parse_ndjson_str(ndjson)), ndjson)
}

///|
test "round-trip: hostile string cells survive every format's escaping" {
  // Every character class a CSV / JSON writer has to escape, plus lookalikes
  // (a string that reads as a number / a bool must stay a string on read-back).
  let df = @frame.DataFrame([
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
  let df = @frame.DataFrame([
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
  let df = @frame.DataFrame([
    @series.Series::from_int_options("i", [Some(1L), None, Some(-3L)]),
    @series.Series::from_float_options("f", [None, Some(2.5), None]),
    @series.Series::from_string_options("s", [Some("x"), Some(""), None]),
    @series.Series::from_bool_options("b", [Some(true), None, Some(false)]),
  ])
  assert_roundtrip_fixpoint(df)
}

///|
test "round-trip: Bool column and a header that needs quoting" {
  let df = @frame.DataFrame([
    @series.Series::from_bools("has,comma", [true, false, true]),
    @series.Series::from_strings("with\"quote", ["a", "b", "c"]),
  ])
  assert_roundtrip_fixpoint(df)
}

///|
test "round-trip: shape edges (single row, single column, wide frame)" {
  assert_roundtrip_fixpoint(
    @frame.DataFrame([
      @series.Series::from_ints("a", [42L]),
      @series.Series::from_strings("b", ["only"]),
    ]),
  )
  assert_roundtrip_fixpoint(
    @frame.DataFrame([@series.Series::from_strings("c", ["p", "q", "r"])]),
  )
}

///|
/// Compare shape, column order, and every cell. Float comparison is bit-exact
/// so signed zero and values next to the finite Double limit cannot drift.
fn assert_same_cells(
  expected : @frame.DataFrame,
  actual : @frame.DataFrame,
) -> Unit raise {
  assert_eq(actual.shape(), expected.shape())
  assert_eq(actual.columns(), expected.columns())
  for name in expected.columns() {
    for row in 0..<expected.nrows() {
      let want = expected.item(row, name)
      let got = actual.item(row, name)
      match (want, got) {
        (@types.Scalar::Float(w), @types.Scalar::Float(g)) =>
          if w.is_nan() {
            assert_true(g.is_nan())
          } else {
            assert_eq(g.reinterpret_as_int64(), w.reinterpret_as_int64())
          }
        _ => assert_eq(got, want)
      }
    }
  }
}

///|
/// Use an out-of-corpus null token so an empty String cell stays distinct from
/// Null. The reader scans the complete fixture and rejects ragged records.
fn csv_roundtrip(
  df : @frame.DataFrame,
  delimiter? : Char = ',',
) -> @frame.DataFrame raise {
  let null_token = "\u{E000}MOONFRAME_NULL"
  @io.parse_csv_str(
    @io.format_csv(
      df,
      options=@io.CsvWriteOptions(delimiter~, null_value=null_token),
    ),
    options=@io.CsvReadOptions(
      delimiter~,
      infer_schema_rows=0,
      null_values=[null_token],
      strict_column_count=true,
    ),
  )
}

///|
fn json_roundtrip(df : @frame.DataFrame) -> @frame.DataFrame raise {
  @io.parse_json_str(
    @io.format_json(df),
    options=@io.JsonReadOptions(infer_schema_rows=0),
  )
}

///|
fn ndjson_roundtrip(df : @frame.DataFrame) -> @frame.DataFrame raise {
  @io.parse_ndjson_str(
    @io.format_ndjson(df),
    options=@io.JsonReadOptions(infer_schema_rows=0),
  )
}

///|
fn assert_lossless_in_every_format(df : @frame.DataFrame) -> Unit raise {
  assert_same_cells(df, csv_roundtrip(df))
  assert_same_cells(df, json_roundtrip(df))
  assert_same_cells(df, ndjson_roundtrip(df))
}

///|
test "cell property: hostile text and empty/null cells keep their positions" {
  let df = @frame.DataFrame([
    @series.Series::from_string_options("\u{FEFF}first,\"header", [
      Some(""),
      None,
      Some("a,b"),
      Some("a;custom"),
      Some("has \"quote\""),
      Some("two\nlines"),
      Some("crlf\r\ncell"),
      Some("prefix\u{FEFF}suffix"),
      Some("\u{FEFF}leading cell"),
      Some("astral \u{1F600}"),
      Some("01"),
      Some("true"),
    ]),
    @series.Series::from_ints("row", [
      0L, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L,
    ]),
  ])
  assert_lossless_in_every_format(df)
  assert_same_cells(df, csv_roundtrip(df, delimiter=';'))
}

///|
test "cell property: finite numeric extremes survive with exact Float bits" {
  let df = @frame.DataFrame([
    @series.Series::from_ints("i", [
      -9223372036854775808L, -9007199254740993L, -1L, 0L, 1L, 9007199254740993L,
      9223372036854775807L,
    ]),
    @series.Series::from_floats("f", [
      -1.7976931348623157e308, -1.7976931348623155e308, -2.5, 0.5, 1.5, 1.7976931348623155e308,
      1.7976931348623157e308,
    ]),
  ])
  assert_lossless_in_every_format(df)
}

///|
test "cell property: signed zero changes only where CSV documents it" {
  let df = @frame.DataFrame([@series.Series::from_floats("f", [-0.0, 0.0, 1.5])])
  assert_same_cells(df, json_roundtrip(df))
  assert_same_cells(df, ndjson_roundtrip(df))
  assert_same_cells(
    @frame.DataFrame([@series.Series::from_floats("f", [0.0, 0.0, 1.5])]),
    csv_roundtrip(df),
  )
}

///|
test "cell property: non-finite JSON cells canonicalize in place" {
  let df = @frame.DataFrame([
    @series.Series::from_floats("f", [
      1.5, @double.not_a_number, @double.infinity, @double.neg_infinity, -1.7976931348623157e308,
    ]),
    @series.Series::from_ints("row", [0L, 1L, 2L, 3L, 4L]),
  ])
  assert_same_cells(df, csv_roundtrip(df))
  let canonical = @frame.DataFrame([
    @series.Series::from_float_options("f", [
      Some(1.5),
      None,
      None,
      None,
      Some(-1.7976931348623157e308),
    ]),
    @series.Series::from_ints("row", [0L, 1L, 2L, 3L, 4L]),
  ])
  assert_same_cells(canonical, json_roundtrip(df))
  assert_same_cells(canonical, ndjson_roundtrip(df))
}

///|
test "rejection property: an unsafe CSV delimiter returns DataError" {
  let df = @frame.DataFrame([
    @series.Series::from_strings("s", ["left", "right"]),
  ])
  let result = Ok(
    @io.format_csv(df, options=@io.CsvWriteOptions(delimiter='\u{FEFF}')),
  ) catch {
    error => Err(error)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "rejection property: isolated surrogate halves never reach a file" {
  let df = @io.parse_ndjson_str(
    "{\"s\":\"\\ud800\",\"kind\":\"high\"}\n{\"s\":\"\\udfff\",\"kind\":\"low\"}\n",
  )
  let csv = Ok(@io.write_csv("_build/io_corpus_surrogate.csv", df)) catch {
    error => Err(error)
  }
  let json = Ok(@io.write_json("_build/io_corpus_surrogate.json", df)) catch {
    error => Err(error)
  }
  let ndjson = Ok(@io.write_ndjson("_build/io_corpus_surrogate.ndjson", df)) catch {
    error => Err(error)
  }
  assert_true(csv is Err(@types.DataError::InvalidOperation(_)))
  assert_true(json is Err(@types.DataError::InvalidOperation(_)))
  assert_true(ndjson is Err(@types.DataError::InvalidOperation(_)))
}
