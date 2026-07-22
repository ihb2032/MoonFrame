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
  let schema = @types.Schema::new([@types.Field("a", @types.DataType::Int)])
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
  let back = @io.parse_ndjson_str(text, @io.JsonReadOptions())
  assert_eq(back.nrows(), 4)
  assert_eq(back.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(back.null_count().item(0, "x"), @types.Scalar::Int(3))
}

///|
test "round-trip: a large Int64 survives NDJSON write→read" {
  // NDJSON shares `scalar_to_json` / `json_value_as_int`, so the large-Int64
  // verbatim-repr fix carries over: values past 2^53 stay exact Ints.
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("n", [9007199254740993L, 9223372036854775807L]),
  ])
  let text = @io.format_ndjson(df)
  assert_eq(text, "{\"n\":9007199254740993}\n{\"n\":9223372036854775807}\n")
  let parsed = @io.parse_ndjson_str(text, @io.JsonReadOptions())
  assert_eq(parsed.get_column("n").dtype(), @types.DataType::Int)
  for i in 0..<df.nrows() {
    assert_eq(parsed.item(i, "n"), df.item(i, "n"))
  }
}

// ── parse_ndjson_str: happy paths ───────────────────────────────────

///|
test "parse_ndjson_str: infers Int / Float / Bool / String" {
  let content =
    #|{"i":1,"f":1.5,"b":true,"s":"hello"}
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
}

///|
test "parse_ndjson_str: mixed Int + Float promotes to Float" {
  let content =
    #|{"n":1}
    #|{"n":2.5}
    #|{"n":3}
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
  assert_eq(df.get_column("n").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "n"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "n"), @types.Scalar::Float(2.5))
}

///|
test "parse_ndjson_str: large ints stay Int up to the Int64 range" {
  let in_range = @io.parse_ndjson_str(
    "{\"big\":3000000000}",
    @io.JsonReadOptions(),
  )
  assert_eq(in_range.get_column("big").dtype(), @types.DataType::Int)
  let beyond = @io.parse_ndjson_str("{\"big\":1e30}", @io.JsonReadOptions())
  assert_eq(beyond.get_column("big").dtype(), @types.DataType::Float)
}

///|
test "parse_ndjson_str: missing fields become nulls" {
  let content =
    #|{"a":1,"b":2}
    #|{"a":3}
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.get_column("x").null_count(), 2)
}

///|
test "parse_ndjson_str: nested array / object cells fall back to String" {
  let content =
    #|{"x":[1,2,3]}
    #|{"x":{"k":1}}
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("[1,2,3]"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("{\"k\":1}"))
}

// ── parse_ndjson_str: line framing ──────────────────────────────────

///|
test "parse_ndjson_str: empty input yields a 0x0 frame" {
  let df = @io.parse_ndjson_str("", @io.JsonReadOptions())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_ndjson_str: whitespace-only input yields a 0x0 frame" {
  // Spaces / tabs / blank lines carry no records.
  let df = @io.parse_ndjson_str("  \n\t\n", @io.JsonReadOptions())
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_ndjson_str: strips a leading UTF-8 BOM on the first line" {
  // The BOM sits only on the first record line, so without stripping line 1
  // would fail `@json.parse` while later lines parse — an asymmetric failure on
  // Excel-saved files. The whole file must read cleanly, like the CSV reader.
  let df = @io.parse_ndjson_str(
    "\u{FEFF}{\"a\":1}\n{\"a\":2}\n",
    @io.JsonReadOptions(),
  )
  assert_eq(df.shape(), (2, 1))
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "parse_ndjson_str: a BOM-only payload still reads as empty" {
  let df = @io.parse_ndjson_str("\u{FEFF}", @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
  assert_eq(df.shape(), (2, 1))
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "parse_ndjson_str: a line with no trailing newline still parses" {
  // NDJSON's last line may omit the separator; the single segment is a
  // full record.
  let df = @io.parse_ndjson_str("{\"a\":1}\n{\"a\":2}", @io.JsonReadOptions())
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
  let df = @io.parse_ndjson_str(content, @io.JsonReadOptions())
  assert_eq(df.shape(), (0, 0))
}

// ── parse_ndjson_str: error paths ───────────────────────────────────

///|
test "parse_ndjson_str: non-object line returns ParseError" {
  // A bare array / scalar on a line is valid JSON but not a record.
  let result = Ok(
    @io.parse_ndjson_str("{\"a\":1}\n[1,2,3]", @io.JsonReadOptions()),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_ndjson_str: malformed line returns ParseError" {
  let result = Ok(
    @io.parse_ndjson_str("{\"a\":1}\n{oops", @io.JsonReadOptions()),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_ndjson_str: typed mismatch has structured line context" {
  // First two lines lock the dtype on Int; the third sneaks a string
  // in past the inference window, which the builder rejects.
  let content =
    #|{"x":1}
    #|{"x":2}
    #|{"x":"three"}
  let result = Ok(
    @io.parse_ndjson_str(content, @io.JsonReadOptions(infer_schema_rows=2)),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Line,
          "x",
          3,
          @types.DataType::Int,
          "three",
        ),
      ),
    ),
  )
}

///|
test "parse_ndjson_str: a build-stage type error reports the physical file line" {
  // Blank lines (file lines 1 and 4) shift the record index off the physical
  // line: the offending cell is the 3rd record but file line 5. The error must
  // name the true line ("line 5"), not the post-blank-skip record index.
  let content = "\n{\"x\":1}\n{\"x\":2}\n\n{\"x\":\"three\"}"
  let result = Ok(
    @io.parse_ndjson_str(content, @io.JsonReadOptions(infer_schema_rows=2)),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Line,
          "x",
          5,
          @types.DataType::Int,
          "three",
        ),
      ),
    ),
  )
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
  let df = @io.parse_ndjson_str(
    content,
    @io.JsonReadOptions(infer_schema_rows=0),
  )
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
  let df = @io.parse_ndjson_str(
    content,
    @io.JsonReadOptions(
      infer_schema_rows=2,
      on_parse_error=@io.OnParseError::Null,
    ),
  )
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
test "write_ndjson refuses a cell holding an unpaired surrogate" {
  // A lone surrogate is ingestible (JSON's \uD800 escape parses to a cell
  // holding the bare code unit, and the builtin stringifier emits it
  // verbatim), but the UTF-8 file encoder would merge it with the following
  // quote, corrupting the line framing — so the write is refused up front.
  let df = @io.parse_ndjson_str(
    "{\"a\":\"\\ud800\",\"b\":1}\n",
    @io.JsonReadOptions(),
  )
  assert_eq(df.item(0, "b"), @types.Scalar::Int(1))
  let w = Ok(@io.write_ndjson("_build/io_ndjson_surrogate_reject.ndjson", df)) catch {
    e => Err(e)
  }
  assert_true(w is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "a non-object record's ParseError names its line" {
  // Line 2 is valid JSON but an array; the error must carry the locator,
  // like the per-line syntax and build-stage dtype errors already do.
  assert_eq(
    Ok(
      @io.parse_ndjson_str(
        "{\"a\":1}\n[1,2]\n{\"a\":3}\n",
        @io.JsonReadOptions(),
      ),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "line 2: expected each record to be a JSON object",
        ),
      ),
    ),
  )
}

///|
test "negative zero keeps its sign on an NDJSON round-trip" {
  // A repr-less number renders through Double's Show, which drops the sign
  // of -0.0 — the token `0` would read back as +0.0 and `1.0 / x` flip from
  // -inf to +inf. The writer pins the exact token instead.
  let df = @frame.DataFrame::new([@series.Series::from_floats("a", [-0.0, 1.5])])
  let text = @io.format_ndjson(df)
  assert_true(text.contains("-0.0"))
  let back = @io.parse_ndjson_str(text, @io.JsonReadOptions())
  // Double's == treats -0.0 and +0.0 as equal, so assert on the sign bit.
  let cell = back.get_column("a").get(0).as_float()
  assert_true(cell == 0.0 && cell.reinterpret_as_int64() != 0L)
}

///|
test "read_ndjson_with_options honours a custom inference window" {
  let path = "_build/io_ndjson_test_custom.ndjson"
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("a", [Some(1), Some(2), Some(3)]),
  ])
  @io.write_ndjson(path, df)
  let parsed = @io.read_ndjson_with_options(
    path,
    @io.JsonReadOptions(infer_schema_rows=1),
  )
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.get_column("a").dtype(), @types.DataType::Int)
}

///|
test "read_ndjson: missing file surfaces as IoError, not panic" {
  let result = Ok(
    @io.read_ndjson("_build/io_ndjson_test_does_not_exist.ndjson"),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "read_ndjson_with_options: missing file surfaces as IoError" {
  let result = Ok(
    @io.read_ndjson_with_options(
      "_build/io_ndjson_test_does_not_exist.ndjson",
      @io.JsonReadOptions(),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_ndjson: invalid path surfaces as IoError" {
  // Aim the writer at a directory that doesn't exist so the underlying
  // `@fs` call surfaces `IOError`, promoted to `DataError::IoError`.
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let result = Ok(
    @io.write_ndjson("_build/no_such_dir_io_ndjson_test/file.ndjson", df),
  ) catch {
    e => Err(e)
  }
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
  let df2 = @io.parse_ndjson_str(text, @io.JsonReadOptions())
  // The reader produces Builtin-backed columns; the round-trip preserves the
  // *data*, so compare on a common backend (the original's `r`, built with
  // `from_floats`, is on the Numeric fast path).
  assert_eq(df.to_builtin(), df2.to_builtin())
}
