// Blackbox tests for `@io.parse_json_records_str` /
// `@io.format_json_records` plus the file-backed `read_json` /
// `write_json_records` wrappers.
//
// The string-level pipeline (DataFrame ↔ JSON text) is exercised
// across the four v0.1 dtypes, the null mapping, sparse / mixed
// records, the malformed-input error paths, and the format → parse
// round-trip. The builtin `@json` package handles the actual
// stringification, so the tests pin the *records layout* MoonFrame
// imposes on top — not `@json`'s own escaping rules.

// ── format_json_records: emission ───────────────────────────────────

///|
test "format_json_records: simple Int + String frame" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  // `@json.stringify` emits compact JSON with no spaces. Column
  // order matches DataFrame column declaration order — the
  // linked-hash-map `Map` preserves insertion order.
  assert_eq(
    @io.format_json_records(df),
    "[{\"n\":1,\"s\":\"a\"},{\"n\":2,\"s\":\"b\"},{\"n\":3,\"s\":\"c\"}]",
  )
}

///|
test "format_json_records: null cells emit JSON null" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), None]),
    @series.Series::from_string_options("s", [None, Some("x")]),
  ])
  assert_eq(
    @io.format_json_records(df),
    "[{\"n\":1,\"s\":null},{\"n\":null,\"s\":\"x\"}]",
  )
}

///|
test "format_json_records: special characters get standard escapes" {
  // `\"`, `\\`, `\n`, `\t` are the four escapes the v0.1 plan
  // pins explicitly. We rely on the builtin stringifier, so the
  // assertion locks in the convention rather than re-deriving it.
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", ["a\"b\\c\nd\te"]),
  ])
  assert_eq(@io.format_json_records(df), "[{\"s\":\"a\\\"b\\\\c\\nd\\te\"}]")
}

///|
test "format_json_records: zero-row frame emits an empty array" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)])
  let df = @frame.DataFrame::empty(schema)
  assert_eq(@io.format_json_records(df), "[]")
}

///|
/// Identity that defeats compile-time constant folding, so `x / 0.0`
/// evaluates to a runtime ±Infinity / NaN rather than being rejected as
/// a constant division by zero.
fn id_double(x : Double) -> Double {
  x
}

///|
/// JSON has no `NaN` / `Infinity` literal, so a non-finite `Float` cell is
/// emitted as `null` (matching pandas' `to_json`). Regression guard: the
/// renderer used to emit the bare tokens `Infinity` / `NaN`, producing
/// invalid JSON that the reader below could not round-trip.
test "format_json_records: non-finite floats emit JSON null" {
  let inf = id_double(1.0) / id_double(0.0)
  let nan = id_double(0.0) / id_double(0.0)
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("x", [1.5, inf, -inf, nan]),
  ])
  let js = @io.format_json_records(df)
  assert_eq(js, "[{\"x\":1.5},{\"x\":null},{\"x\":null},{\"x\":null}]")
  // The emitted text is valid JSON: the library's own reader round-trips
  // it, reading the three non-finite cells back as nulls in a Float column.
  let back = @io.parse_json_records_str(js, @io.JsonReadOptions::default())
  assert_eq(back.nrows(), 4)
  assert_eq(back.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(back.null_count().item(0, "x"), @types.Scalar::Int(3))
}

// ── parse_json_records_str: happy paths ─────────────────────────────

///|
test "parse_json_records_str: infers Int / Float / Bool / String" {
  let content = "[{\"i\":1,\"f\":1.5,\"b\":true,\"s\":\"hello\"}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.shape(), (1, 4))
  assert_eq(df.columns(), ["i", "f", "b", "s"])
  assert_eq(df.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "i"), @types.Scalar::Int(1))
  assert_eq(df.item(0, "f"), @types.Scalar::Float(1.5))
  assert_eq(df.item(0, "b"), @types.Scalar::Bool(true))
  assert_eq(df.item(0, "s"), @types.Scalar::String("hello"))
}

///|
test "parse_json_records_str: null cells map to None across every dtype" {
  let content =
    #|[{"i":1,"f":1.5,"b":true,"s":"a"},
    #| {"i":null,"f":null,"b":null,"s":null},
    #| {"i":3,"f":3.5,"b":false,"s":"c"}]
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.shape(), (3, 4))
  for name in ["i", "f", "b", "s"] {
    assert_eq(df.item(1, name), @types.Scalar::Null)
    assert_eq(df.get_column(name).null_count(), 1)
  }
}

///|
test "parse_json_records_str: integer-valued floats stay Int" {
  // `1`, `2`, `3` all carry an integral `repr`, so the column locks
  // on Int rather than Float — matching the CSV reader.
  let content = "[{\"n\":1},{\"n\":2},{\"n\":3}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
}

///|
test "parse_json_records_str: mixed Int + Float promotes to Float" {
  let content = "[{\"n\":1},{\"n\":2.5},{\"n\":3}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("n").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "n"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "n"), @types.Scalar::Float(2.5))
}

///|
test "parse_json_records_str: large ints stay Int up to the Int64 range" {
  // 3_000_000_000 overflows Int32 but fits Int64, so it stays an Int
  // column — the Int->Int64 migration removed the old demotion to Float.
  let in_range = @io.parse_json_records_str(
    "[{\"big\":3000000000}]",
    @io.JsonReadOptions::default(),
  )
  assert_eq(in_range.get_column("big").dtype(), @types.DataType::Int)
  // A value past the Int64 range still falls through to Float.
  let beyond = @io.parse_json_records_str(
    "[{\"big\":1e30}]",
    @io.JsonReadOptions::default(),
  )
  assert_eq(beyond.get_column("big").dtype(), @types.DataType::Float)
}

///|
test "round-trip: a large Int64 beyond 2^53 keeps Int dtype and exact value" {
  // 2^53, 2^53+1 (the first Int64 with no exact Double), and Int64::MAX all
  // used to corrupt to a Float(Infinity) cell on round-trip; the verbatim-repr
  // writer and the repr-recovering reader keep them exact.
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("n", [
      9007199254740992L, 9007199254740993L, 9223372036854775807L, 7L,
    ]),
  ])
  let text = @io.format_json_records(df)
  // Exact digits are emitted, not the rounded Double.
  assert_eq(
    text, "[{\"n\":9007199254740992},{\"n\":9007199254740993},{\"n\":9223372036854775807},{\"n\":7}]",
  )
  let parsed = @io.parse_json_records_str(text, @io.JsonReadOptions::default())
  assert_eq(parsed.get_column("n").dtype(), @types.DataType::Int)
  for i in 0..<df.nrows() {
    assert_eq(parsed.item(i, "n"), df.item(i, "n"))
  }
}

///|
test "parse_json_records_str: a Double-overflowing int in a String column keeps its digits" {
  // A mixed column falls back to String; the `Double`-overflowing integer must
  // render as its exact digits (from the preserved `repr`), not "Infinity".
  let content = "[{\"x\":9007199254740993},{\"x\":\"hi\"}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("9007199254740993"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("hi"))
}

///|
test "parse_json_records_str: a Double-overflowing int in a Float column recovers a finite Double, not Infinity" {
  // A fractional sibling forces `Float` inference; the `Double`-overflowing
  // integer must recover its nearest finite `Double` from the preserved `repr`
  // (as the CSV reader does) instead of corrupting the cell to `Infinity`.
  let content = "[{\"x\":1.5},{\"x\":9007199254740993}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.5))
  // 9007199254740993 = 2^53 + 1 is unrepresentable; it rounds to 2^53.
  assert_eq(df.item(1, "x"), @types.Scalar::Float(9007199254740992.0))
}

///|
test "parse_json_records_str: Float-column big-int recovery matches the CSV reader" {
  // The same digits read through CSV and JSON must agree — the JSON path used to
  // diverge to Infinity while the CSV path stayed finite.
  let js = @io.parse_json_records_str(
    "[{\"x\":1.5},{\"x\":9007199254740993}]",
    @io.JsonReadOptions::default(),
  )
  let csv = @io.parse_csv_str(
    "x\n1.5\n9007199254740993\n",
    @io.CsvReadOptions::default(),
  )
  assert_eq(js.item(1, "x"), csv.item(1, "x"))
}

///|
test "parse_json_records_str: missing fields become nulls" {
  // The second record lacks `b`; the column-collection pass keeps
  // both columns and the builder slots in a null for the missing
  // field.
  let content = "[{\"a\":1,\"b\":2},{\"a\":3}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(1, "b"), @types.Scalar::Null)
}

///|
test "parse_json_records_str: sparse records contribute their own columns" {
  // Headers are collected in first-seen order across *all* records,
  // not just the first one, so a column that appears later still
  // shows up.
  let content = "[{\"a\":1},{\"b\":2}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(0, "b"), @types.Scalar::Null)
  assert_eq(df.item(1, "a"), @types.Scalar::Null)
}

///|
test "parse_json_records_str: mixed-dtype column falls back to String" {
  // `1` is an Int candidate, `"two"` is a String candidate — no
  // single dtype accepts both, so the inference order ends at the
  // String fallback and numeric cells are restringified.
  let content = "[{\"x\":1},{\"x\":\"two\"},{\"x\":3}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("1"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("two"))
  assert_eq(df.item(2, "x"), @types.Scalar::String("3"))
}

// ── parse_json_records_str: edge / error paths ──────────────────────

///|
test "parse_json_records_str: empty input yields a 0x0 frame" {
  let df = @io.parse_json_records_str("", @io.JsonReadOptions::default())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_records_str: empty array yields a 0x0 frame" {
  let df = @io.parse_json_records_str("[]", @io.JsonReadOptions::default())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_records_str: array of empty objects collapses to 0x0" {
  // `[{}, {}]` is N records with 0 columns, which `DataFrame::new`
  // cannot represent; the reader collapses it to the same shape
  // empty-input produces.
  let df = @io.parse_json_records_str("[{},{}]", @io.JsonReadOptions::default())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_records_str: strips a leading UTF-8 BOM (Excel / utf-8-sig)" {
  // A file saved with a UTF-8 BOM must read like a clean one — matching the CSV
  // reader and Polars / pandas. Left in place the BOM makes `@json.parse` reject
  // the payload at column 0.
  let df = @io.parse_json_records_str(
    "\u{FEFF}[{\"a\":1,\"b\":2}]",
    @io.JsonReadOptions::default(),
  )
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.shape(), (1, 2))
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
}

///|
test "parse_json_records_str: a BOM-only payload still reads as empty" {
  let df = @io.parse_json_records_str(
    "\u{FEFF}",
    @io.JsonReadOptions::default(),
  )
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_records_str: non-array top-level returns ParseError" {
  let result = Ok(
    @io.parse_json_records_str("{\"a\":1}", @io.JsonReadOptions::default()),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: non-object record returns ParseError" {
  let result = Ok(
    @io.parse_json_records_str("[1,2,3]", @io.JsonReadOptions::default()),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: malformed JSON returns ParseError" {
  let result = Ok(
    @io.parse_json_records_str("[{", @io.JsonReadOptions::default()),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: typed mismatch past inference window errors" {
  // First two records lock the dtype on Int; the third sneaks in a
  // string. The builder rejects the unparseable cell with
  // ParseError rather than silently widening the column.
  let content = "[{\"x\":1},{\"x\":2},{\"x\":\"three\"}]"
  let result = Ok(
    @io.parse_json_records_str(content, {
      infer_schema_rows: 2,
      on_parse_error: @io.OnParseError::Raise,
    }),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: Float column with non-number past inference errors" {
  // Inference locks Float on the first two records; the third
  // sneaks a string in, which `json_value_as_float` rejects.
  let content = "[{\"x\":1.5},{\"x\":2.5},{\"x\":\"oops\"}]"
  let result = Ok(
    @io.parse_json_records_str(content, {
      infer_schema_rows: 2,
      on_parse_error: @io.OnParseError::Raise,
    }),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: Bool column with non-bool past inference errors" {
  // Locks Bool on the first two records, then rejects the numeric
  // cell — `json_value_as_bool` refuses `Number(1)` per the same
  // convention `parse_csv_str` uses for `parse_bool_opt`.
  let content = "[{\"x\":true},{\"x\":false},{\"x\":1}]"
  let result = Ok(
    @io.parse_json_records_str(content, {
      infer_schema_rows: 2,
      on_parse_error: @io.OnParseError::Raise,
    }),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

// ── O4 read resilience (scan-all / on_parse_error) ──────────────────

///|
test "parse_json_records_str: infer_schema_rows=0 scans every record" {
  // Record 1 is an integral number, record 2 fractional. A 1-record window
  // would lock Int and reject 2.5; scanning every record (`0`, Polars'
  // `infer_schema_length=None`) types the column Float up front.
  let content = "[{\"x\":1},{\"x\":2.5}]"
  let df = @io.parse_json_records_str(content, {
    infer_schema_rows: 0,
    on_parse_error: @io.OnParseError::Raise,
  })
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "x"), @types.Scalar::Float(2.5))
}

///|
test "parse_json_records_str: on_parse_error=Null nulls an out-of-window misfit" {
  // First two records lock Int; the third is a string. `Raise` (the
  // default, exercised above) errors; `Null` keeps the Int column and
  // downgrades the bad cell to null (Polars' `ignore_errors=True`).
  let content = "[{\"x\":1},{\"x\":2},{\"x\":\"three\"}]"
  let df = @io.parse_json_records_str(content, {
    infer_schema_rows: 2,
    on_parse_error: @io.OnParseError::Null,
  })
  assert_eq(df.get_column("x").dtype(), @types.DataType::Int)
  assert_eq(df.item(0, "x"), @types.Scalar::Int(1))
  assert_eq(df.item(2, "x"), @types.Scalar::Null)
  assert_eq(df.get_column("x").null_count(), 1)
}

// ── inference edge cases ────────────────────────────────────────────

///|
test "parse_json_records_str: all-null column defaults to String dtype" {
  // No non-null cell exists to disambiguate the dtype, so the
  // inference pass falls back to the same `String` default the CSV
  // reader uses for an entirely-null probe window.
  let content = "[{\"x\":null},{\"x\":null}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.get_column("x").null_count(), 2)
}

///|
test "parse_json_records_str: Bool + Int mix collapses to String" {
  // `true` kills the Int / Float / String candidates while keeping
  // Bool; `1` then kills Bool. With every candidate false, the
  // final `else` branch in the dtype cascade returns `JsonString`
  // and the build pass restringifies each cell via the fallback
  // (`True → "true"`, `Number(1, ..) → "1"`).
  let content = "[{\"x\":true},{\"x\":false},{\"x\":1}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("true"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("false"))
  assert_eq(df.item(2, "x"), @types.Scalar::String("1"))
}

///|
test "parse_json_records_str: nested array / object cells fall back to String" {
  // Nested composites have no scalar dtype to slot under, so the
  // inference pass strikes out on every candidate and falls back
  // to `String`. The build pass then serialises the composites via
  // `@json.stringify` so the cell still carries the original shape.
  let content =
    #|[{"x":[1,2,3]},{"x":{"k":1}}]
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("[1,2,3]"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("{\"k\":1}"))
}

// ── read_json / write_json_records: file-system path ────────────────

///|
test "write_json_records then read_json round-trips a small frame on disk" {
  let path = "_build/io_json_test_roundtrip.json"
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["x", "y", "z"]),
  ])
  @io.write_json_records(path, df)
  let parsed = @io.read_json(path)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.item(2, "n"), @types.Scalar::Int(3))
  assert_eq(parsed.item(0, "s"), @types.Scalar::String("x"))
}

///|
test "read_json_with_options honours a custom inference window" {
  let path = "_build/io_json_test_custom.json"
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("a", [Some(1), Some(2), Some(3)]),
  ])
  @io.write_json_records(path, df)
  let parsed = @io.read_json_with_options(path, {
    infer_schema_rows: 1,
    on_parse_error: @io.OnParseError::Raise,
  })
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.get_column("a").dtype(), @types.DataType::Int)
}

///|
test "read_json: missing file surfaces as IoError, not panic" {
  let result = Ok(@io.read_json("_build/io_json_test_does_not_exist.json")) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "read_json_with_options: missing file surfaces as IoError" {
  let result = Ok(
    @io.read_json_with_options(
      "_build/io_json_test_does_not_exist.json",
      @io.JsonReadOptions::default(),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_json_records: invalid path surfaces as IoError" {
  // Same shape as the CSV writer error test: aim the writer at a
  // directory that doesn't exist so the underlying `@fs` call
  // surfaces `IOError`, which we promote to `DataError::IoError`.
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let result = Ok(
    @io.write_json_records("_build/no_such_dir_io_json_test/file.json", df),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

// ── round-trip ──────────────────────────────────────────────────────

///|
test "format_json_records / parse_json_records_str round-trip preserves data" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
    @series.Series::from_floats("r", [
      (1.5 : Double),
      (2.5 : Double),
      (3.5 : Double),
    ]),
    @series.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  let json = @io.format_json_records(df)
  let df2 = @io.parse_json_records_str(json, @io.JsonReadOptions::default())
  // The reader produces Builtin-backed columns; the round-trip preserves the
  // *data*, so compare on a common backend (the original's `r`, built with
  // `from_floats`, is on the Numeric fast path).
  assert_eq(df.to_builtin(), df2.to_builtin())
}

///|
test "round-trip narrows an all-integral Float column to Int (documented caveat)" {
  // JSON has a single number type and `Double::to_string` drops the
  // fractional part of a whole value (`2.0` → "2"), so a `Float` column whose
  // cells are all integral comes back as `Int` after `format_json_records` →
  // `parse_json_records_str`. Only the dtype narrows (`Float → Int`); the
  // values are preserved. This pins the behaviour documented in this module's
  // header (Caveat 1) — and is why the round-trip test above uses fractional
  // cells (1.5 / 2.5 / 3.5), which stay `Float`.
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("r", [(2.0 : Double), (3.0 : Double)]),
  ])
  assert_eq(df.get_column("r").dtype(), @types.DataType::Float)
  let df2 = @io.parse_json_records_str(
    @io.format_json_records(df),
    @io.JsonReadOptions::default(),
  )
  assert_eq(df2.get_column("r").dtype(), @types.DataType::Int)
  assert_eq(df2.item(0, "r"), @types.Scalar::Int(2))
  assert_eq(df2.item(1, "r"), @types.Scalar::Int(3))
}
