// Blackbox tests for `@io.parse_ndjson_str` / `@io.format_ndjson` plus
// the file-backed `read_ndjson` / `write_ndjson` wrappers.
//
// NDJSON shares its records → frame core (`frame_from_json_records`) and
// its cell mapping (`scalar_to_json`) with the JSON-records reader, so
// these tests focus on what NDJSON adds on top — the line framing (one
// object per line, trailing newline on write, blank-line / CRLF
// tolerance on read) — while still smoke-testing the inherited
// inference / null / sparse behaviour through the NDJSON path. The
// builtin `@json` package handles the actual stringification.
//
// Note: `id_double` (defeats constant folding for the non-finite-float
// test) is defined in `json_test.mbt` and shared across this package's
// blackbox tests, so it is reused here rather than redefined.

// ── format_ndjson: emission ─────────────────────────────────────────

///|
test "format_ndjson: simple Int + String frame" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  // One compact object per row, each terminated by `\n` (including the
  // last). Keys follow column declaration order.
  assert_eq(
    @io.format_ndjson(df),
    "{\"n\":1,\"s\":\"a\"}\n{\"n\":2,\"s\":\"b\"}\n{\"n\":3,\"s\":\"c\"}\n",
  )
}

///|
test "format_ndjson: null cells emit JSON null" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), None]),
    @series.Series::from_string_options("s", [None, Some("x")]),
  ])
  assert_eq(
    @io.format_ndjson(df),
    "{\"n\":1,\"s\":null}\n{\"n\":null,\"s\":\"x\"}\n",
  )
}

///|
test "format_ndjson: special characters get standard escapes" {
  // Same four escapes the JSON-records writer pins; the builtin
  // stringifier produces them, so this locks in the convention.
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", ["a\"b\\c\nd\te"]),
  ])
  assert_eq(@io.format_ndjson(df), "{\"s\":\"a\\\"b\\\\c\\nd\\te\"}\n")
}

///|
test "format_ndjson: zero-row frame emits the empty string" {
  // No rows → no lines → empty output (the NDJSON analogue of the
  // JSON-records writer's `[]`).
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)])
  let df = @frame.DataFrame::empty(schema)
  assert_eq(@io.format_ndjson(df), "")
}

///|
test "format_ndjson: non-finite floats emit JSON null" {
  // NDJSON inherits `scalar_to_json`, so a non-finite `Float` cell is
  // emitted as `null` — keeping each line valid JSON — exactly as the
  // JSON-records writer does.
  let inf = id_double(1.0) / id_double(0.0)
  let nan = id_double(0.0) / id_double(0.0)
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("x", [1.5, inf, -inf, nan]),
  ])
  let text = @io.format_ndjson(df)
  assert_eq(text, "{\"x\":1.5}\n{\"x\":null}\n{\"x\":null}\n{\"x\":null}\n")
  // The emitted text round-trips: the three non-finite cells read back
  // as nulls in a Float column.
  let back = @io.parse_ndjson_str(text, @io.NdjsonReadOptions::default())
  assert_eq(back.nrows(), 4)
  assert_eq(back.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(back.null_count().item(0, "x"), @types.Scalar::Int(3))
}

// ── parse_ndjson_str: happy paths ───────────────────────────────────

///|
test "parse_ndjson_str: infers Int / Float / Bool / String" {
  let content =
    #|{"i":1,"f":1.5,"b":true,"s":"hello"}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
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
test "parse_ndjson_str: null cells map to None across every dtype" {
  let content =
    #|{"i":1,"f":1.5,"b":true,"s":"a"}
    #|{"i":null,"f":null,"b":null,"s":null}
    #|{"i":3,"f":3.5,"b":false,"s":"c"}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (3, 4))
  for name in ["i", "f", "b", "s"] {
    assert_eq(df.item(1, name), @types.Scalar::Null)
    assert_eq(df.get_column(name).null_count(), 1)
  }
}

///|
test "parse_ndjson_str: integer-valued floats stay Int" {
  let content =
    #|{"n":1}
    #|{"n":2}
    #|{"n":3}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
}

///|
test "parse_ndjson_str: mixed Int + Float promotes to Float" {
  let content =
    #|{"n":1}
    #|{"n":2.5}
    #|{"n":3}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.get_column("n").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "n"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "n"), @types.Scalar::Float(2.5))
}

///|
test "parse_ndjson_str: large ints stay Int up to the Int64 range" {
  let in_range = @io.parse_ndjson_str(
    "{\"big\":3000000000}",
    @io.NdjsonReadOptions::default(),
  )
  assert_eq(in_range.get_column("big").dtype(), @types.DataType::Int)
  let beyond = @io.parse_ndjson_str(
    "{\"big\":1e30}",
    @io.NdjsonReadOptions::default(),
  )
  assert_eq(beyond.get_column("big").dtype(), @types.DataType::Float)
}

///|
test "parse_ndjson_str: missing fields become nulls" {
  let content =
    #|{"a":1,"b":2}
    #|{"a":3}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(1, "b"), @types.Scalar::Null)
}

///|
test "parse_ndjson_str: sparse records contribute their own columns" {
  // Headers are collected in first-seen order across *all* lines, so a
  // column that first appears on a later line still shows up.
  let content =
    #|{"a":1}
    #|{"b":2}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(0, "b"), @types.Scalar::Null)
  assert_eq(df.item(1, "a"), @types.Scalar::Null)
}

///|
test "parse_ndjson_str: mixed-dtype column falls back to String" {
  let content =
    #|{"x":1}
    #|{"x":"two"}
    #|{"x":3}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("1"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("two"))
  assert_eq(df.item(2, "x"), @types.Scalar::String("3"))
}

///|
test "parse_ndjson_str: all-null column defaults to String dtype" {
  let content =
    #|{"x":null}
    #|{"x":null}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.get_column("x").null_count(), 2)
}

///|
test "parse_ndjson_str: nested array / object cells fall back to String" {
  let content =
    #|{"x":[1,2,3]}
    #|{"x":{"k":1}}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("[1,2,3]"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("{\"k\":1}"))
}

// ── parse_ndjson_str: line framing ──────────────────────────────────

///|
test "parse_ndjson_str: empty input yields a 0x0 frame" {
  let df = @io.parse_ndjson_str("", @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_ndjson_str: whitespace-only input yields a 0x0 frame" {
  // Spaces / tabs / blank lines carry no records.
  let df = @io.parse_ndjson_str("  \n\t\n", @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_ndjson_str: blank lines between and around records are skipped" {
  // Leading, interior, and trailing blank lines must not produce
  // phantom rows — they are skipped before parsing.
  let content =
    #|
    #|{"a":1}
    #|
    #|{"a":2}
    #|
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (2, 1))
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "parse_ndjson_str: CRLF line endings are handled" {
  // Splitting on `\n` leaves a trailing `\r`, which `@json.parse`
  // tolerates as JSON whitespace; the final empty segment after the
  // last CRLF is a blank line and is skipped.
  let content = "{\"a\":1}\r\n{\"a\":2}\r\n"
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (2, 1))
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "parse_ndjson_str: a line with no trailing newline still parses" {
  // NDJSON's last line may omit the separator; the single segment is a
  // full record.
  let df = @io.parse_ndjson_str(
    "{\"a\":1}\n{\"a\":2}",
    @io.NdjsonReadOptions::default(),
  )
  assert_eq(df.shape(), (2, 1))
  assert_eq(df.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "parse_ndjson_str: lines of empty objects collapse to 0x0" {
  // `{}` per line is N rows of zero columns, which `DataFrame::new`
  // cannot represent; collapses to the empty-input shape.
  let content =
    #|{}
    #|{}
  let df = @io.parse_ndjson_str(content, @io.NdjsonReadOptions::default())
  assert_eq(df.shape(), (0, 0))
}

// ── parse_ndjson_str: error paths ───────────────────────────────────

///|
test "parse_ndjson_str: non-object line returns ParseError" {
  // A bare array / scalar on a line is valid JSON but not a record.
  let result = try? @io.parse_ndjson_str(
    "{\"a\":1}\n[1,2,3]",
    @io.NdjsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_ndjson_str: malformed line returns ParseError" {
  let result = try? @io.parse_ndjson_str(
    "{\"a\":1}\n{oops",
    @io.NdjsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_ndjson_str: typed mismatch past inference window errors" {
  // First two lines lock the dtype on Int; the third sneaks a string
  // in past the inference window, which the builder rejects.
  let content =
    #|{"x":1}
    #|{"x":2}
    #|{"x":"three"}
  let result = try? @io.parse_ndjson_str(content, {
    infer_schema_rows: 2,
    on_parse_error: @io.OnParseError::Raise,
  })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_ndjson_str: a build-stage type error reports the physical file line" {
  // Blank lines (file lines 1 and 4) shift the record index off the physical
  // line: the offending cell is the 3rd record but file line 5. The error must
  // name the true line ("line 5"), not the post-blank-skip record index.
  let content = "\n{\"x\":1}\n{\"x\":2}\n\n{\"x\":\"three\"}"
  let result = try? @io.parse_ndjson_str(content, {
    infer_schema_rows: 2,
    on_parse_error: @io.OnParseError::Raise,
  })
  let msg = match result {
    Err(@types.DataError::ParseError(m)) => m
    _ => "<not a ParseError>"
  }
  assert_true(msg.contains("line 5"))
  assert_eq(msg.contains("record"), false)
}

// ── O4 read resilience (scan-all / on_parse_error) ──────────────────

///|
test "parse_ndjson_str: infer_schema_rows=0 scans every line" {
  // Line 1 is integral, line 2 fractional. A 1-line window would lock Int
  // and reject 2.5; scanning every line (`0`, Polars'
  // `infer_schema_length=None`) types the column Float up front. Shares the
  // `frame_from_json_records` core with the JSON-array reader, so the two
  // formats agree.
  let content =
    #|{"x":1}
    #|{"x":2.5}
  let df = @io.parse_ndjson_str(content, {
    infer_schema_rows: 0,
    on_parse_error: @io.OnParseError::Raise,
  })
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "x"), @types.Scalar::Float(2.5))
}

///|
test "parse_ndjson_str: on_parse_error=Null nulls an out-of-window misfit" {
  // First two lines lock Int; the third is a string. `Raise` (the default,
  // exercised above) errors; `Null` keeps the Int column and downgrades the
  // bad cell to null.
  let content =
    #|{"x":1}
    #|{"x":2}
    #|{"x":"three"}
  let df = @io.parse_ndjson_str(content, {
    infer_schema_rows: 2,
    on_parse_error: @io.OnParseError::Null,
  })
  assert_eq(df.get_column("x").dtype(), @types.DataType::Int)
  assert_eq(df.item(2, "x"), @types.Scalar::Null)
  assert_eq(df.get_column("x").null_count(), 1)
}

// ── read_ndjson / write_ndjson: file-system path ────────────────────

///|
test "write_ndjson then read_ndjson round-trips a small frame on disk" {
  let path = "_build/io_ndjson_test_roundtrip.ndjson"
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["x", "y", "z"]),
  ])
  @io.write_ndjson(path, df)
  let parsed = @io.read_ndjson(path)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.item(2, "n"), @types.Scalar::Int(3))
  assert_eq(parsed.item(0, "s"), @types.Scalar::String("x"))
}

///|
test "read_ndjson_with_options honours a custom inference window" {
  let path = "_build/io_ndjson_test_custom.ndjson"
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("a", [Some(1), Some(2), Some(3)]),
  ])
  @io.write_ndjson(path, df)
  let parsed = @io.read_ndjson_with_options(path, {
    infer_schema_rows: 1,
    on_parse_error: @io.OnParseError::Raise,
  })
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.get_column("a").dtype(), @types.DataType::Int)
}

///|
test "read_ndjson: missing file surfaces as IoError, not panic" {
  let result = try? @io.read_ndjson(
    "_build/io_ndjson_test_does_not_exist.ndjson",
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "read_ndjson_with_options: missing file surfaces as IoError" {
  let result = try? @io.read_ndjson_with_options(
    "_build/io_ndjson_test_does_not_exist.ndjson",
    @io.NdjsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_ndjson: invalid path surfaces as IoError" {
  // Aim the writer at a directory that doesn't exist so the underlying
  // `@fs` call surfaces `IOError`, promoted to `DataError::IoError`.
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let result = try? @io.write_ndjson(
    "_build/no_such_dir_io_ndjson_test/file.ndjson", df,
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

// ── round-trip ──────────────────────────────────────────────────────

///|
test "format_ndjson / parse_ndjson_str round-trip preserves data" {
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
  let text = @io.format_ndjson(df)
  let df2 = @io.parse_ndjson_str(text, @io.NdjsonReadOptions::default())
  // The reader produces Builtin-backed columns; the round-trip preserves the
  // *data*, so compare on a common backend (the original's `r`, built with
  // `from_floats`, is on the Numeric fast path).
  assert_eq(df.to_builtin(), df2.to_builtin())
}
