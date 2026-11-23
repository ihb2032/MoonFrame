// Blackbox tests for `@io.parse_json_str` /
// `@io.format_json` plus the file-backed `read_json` /
// `write_json` wrappers.
//
// The string-level pipeline (DataFrame ↔ JSON text) is exercised
// across the four dtypes, the null mapping, sparse / mixed
// records, the malformed-input error paths, and the format → parse
// round-trip. The builtin `@json` package handles the actual
// stringification, so the tests pin the *records layout* MoonFrame
// imposes on top — not `@json`'s own escaping rules.

// ── format_json: emission ───────────────────────────────────

///|
test "format_json: simple Int + String frame" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  // `@json.stringify` emits compact JSON with no spaces. Column
  // order matches DataFrame column declaration order — the
  // linked-hash-map `Map` preserves insertion order.
  assert_eq(
    @io.format_json(df),
    "[{\"n\":1,\"s\":\"a\"},{\"n\":2,\"s\":\"b\"},{\"n\":3,\"s\":\"c\"}]",
  )
}

///|
test "format_json: null cells emit JSON null" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [Some(1), None]),
    @series.Series::from_string_options("s", [None, Some("x")]),
  ])
  assert_eq(
    @io.format_json(df),
    "[{\"n\":1,\"s\":null},{\"n\":null,\"s\":\"x\"}]",
  )
}

///|
test "format_json: special characters get standard escapes" {
  // `\"`, `\\`, `\n`, `\t` are the four escapes pinned
  // explicitly. We rely on the builtin stringifier, so the
  // assertion locks in the convention rather than re-deriving it.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("s", ["a\"b\\c\nd\te"]),
  ])
  assert_eq(@io.format_json(df), "[{\"s\":\"a\\\"b\\\\c\\nd\\te\"}]")
}

///|
test "format_json: zero-row frame emits an empty array" {
  let schema = @types.Schema::Schema([
    @types.Field::Field("a", @types.DataType::Int),
  ])
  let df = @frame.DataFrame::empty(schema)
  assert_eq(@io.format_json(df), "[]")
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
/// emitted as `null`. Regression guard: the
/// renderer used to emit the bare tokens `Infinity` / `NaN`, producing
/// invalid JSON that the reader below could not round-trip.
test "format_json: non-finite floats emit JSON null" {
  let inf = id_double(1.0) / id_double(0.0)
  let nan = id_double(0.0) / id_double(0.0)
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("x", [1.5, inf, -inf, nan]),
  ])
  let js = @io.format_json(df)
  assert_eq(js, "[{\"x\":1.5},{\"x\":null},{\"x\":null},{\"x\":null}]")
  // The emitted text is valid JSON: the library's own reader round-trips
  // it, reading the three non-finite cells back as nulls in a Float column.
  let back = @io.parse_json_str(js)
  assert_eq(back.nrows(), 4)
  assert_eq(back.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(back.null_count().item(0, "x"), @types.Scalar::Int(3))
}

// ── parse_json_str: happy paths ─────────────────────────────

///|
test "parse_json_str: infers Int / Float / Bool / String" {
  let content = "[{\"i\":1,\"f\":1.5,\"b\":true,\"s\":\"hello\"}]"
  let df = @io.parse_json_str(content)
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
test "parse_json_str: null cells map to None across every dtype" {
  let content =
    #|[{"i":1,"f":1.5,"b":true,"s":"a"},
    #| {"i":null,"f":null,"b":null,"s":null},
    #| {"i":3,"f":3.5,"b":false,"s":"c"}]
  let df = @io.parse_json_str(content)
  assert_eq(df.shape(), (3, 4))
  for name in ["i", "f", "b", "s"] {
    assert_eq(df.item(1, name), @types.Scalar::Null)
    assert_eq(df.get_column(name).null_count(), 1)
  }
}

///|
test "parse_json_str: integer-valued floats stay Int" {
  // `1`, `2`, `3` all carry an integral `repr`, so the column locks
  // on Int rather than Float — matching the CSV reader.
  let content = "[{\"n\":1},{\"n\":2},{\"n\":3}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
}

///|
test "parse_json_str: mixed Int + Float promotes to Float" {
  let content = "[{\"n\":1},{\"n\":2.5},{\"n\":3}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("n").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "n"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "n"), @types.Scalar::Float(2.5))
}

///|
test "parse_json_str: large ints stay Int up to the Int64 range" {
  // 3_000_000_000 overflows Int32 but fits Int64, so it stays an Int
  // column — the Int->Int64 migration removed the old demotion to Float.
  let in_range = @io.parse_json_str("[{\"big\":3000000000}]")
  assert_eq(in_range.get_column("big").dtype(), @types.DataType::Int)
  // A value past the Int64 range still falls through to Float.
  let beyond = @io.parse_json_str("[{\"big\":1e30}]")
  assert_eq(beyond.get_column("big").dtype(), @types.DataType::Float)
}

///|
test "round-trip: a large Int64 beyond 2^53 keeps Int dtype and exact value" {
  // 2^53, 2^53+1 (the first Int64 with no exact Double), and Int64::MAX all
  // used to corrupt to a Float(Infinity) cell on round-trip; the verbatim-repr
  // writer and the repr-recovering reader keep them exact.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("n", [
      9007199254740992L, 9007199254740993L, 9223372036854775807L, 7L,
    ]),
  ])
  let text = @io.format_json(df)
  // Exact digits are emitted, not the rounded Double.
  assert_eq(
    text, "[{\"n\":9007199254740992},{\"n\":9007199254740993},{\"n\":9223372036854775807},{\"n\":7}]",
  )
  let parsed = @io.parse_json_str(text)
  assert_eq(parsed.get_column("n").dtype(), @types.DataType::Int)
  for i in 0..<df.nrows() {
    assert_eq(parsed.item(i, "n"), df.item(i, "n"))
  }
}

///|
test "parse_json_str: a Double-overflowing int in a String column keeps its digits" {
  // A mixed column falls back to String; the `Double`-overflowing integer must
  // render as its exact digits (from the preserved `repr`), not "Infinity".
  let content = "[{\"x\":9007199254740993},{\"x\":\"hi\"}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("9007199254740993"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("hi"))
}

///|
test "parse_json_str: a Double-overflowing int in a Float column recovers a finite Double, not Infinity" {
  // A fractional sibling forces `Float` inference; the `Double`-overflowing
  // integer must recover its nearest finite `Double` from the preserved `repr`
  // (as the CSV reader does) instead of corrupting the cell to `Infinity`.
  let content = "[{\"x\":1.5},{\"x\":9007199254740993}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.5))
  // 9007199254740993 = 2^53 + 1 is unrepresentable; it rounds to 2^53.
  assert_eq(df.item(1, "x"), @types.Scalar::Float(9007199254740992.0))
}

///|
test "parse_json_str: integers beyond Double range write back as null" {
  // A fractional sibling forces Float inference. Unlike 2^53+1 above, ±1e309
  // exceed Double's numerical range, so the preserved integer digits still
  // parse to ±Infinity. JSON has no non-finite number literal; the writer must
  // therefore emit null rather than an invalid bare Infinity token.
  let magnitude = "1\{String::make(309, '0')}"
  let content = "[{\"x\":1.5},{\"x\":\{magnitude}},{\"x\":-\{magnitude}}]"
  let df = @io.parse_json_str(content)
  let inf = id_double(1.0) / id_double(0.0)
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(1, "x"), @types.Scalar::Float(inf))
  assert_eq(df.item(2, "x"), @types.Scalar::Float(-inf))
  assert_eq(@io.format_json(df), "[{\"x\":1.5},{\"x\":null},{\"x\":null}]")
}

///|
test "parse_json_str: Float-column big-int recovery matches the CSV reader" {
  // The same digits read through CSV and JSON must agree — the JSON path used to
  // diverge to Infinity while the CSV path stayed finite.
  let js = @io.parse_json_str("[{\"x\":1.5},{\"x\":9007199254740993}]")
  let csv = @io.parse_csv_str("x\n1.5\n9007199254740993\n")
  assert_eq(js.item(1, "x"), csv.item(1, "x"))
}

///|
test "parse_json_str: missing fields become nulls" {
  // The second record lacks `b`; the column-collection pass keeps
  // both columns and the builder slots in a null for the missing
  // field.
  let content = "[{\"a\":1,\"b\":2},{\"a\":3}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(1, "b"), @types.Scalar::Null)
}

///|
test "parse_json_str: sparse records contribute their own columns" {
  // Headers are collected in first-seen order across *all* records,
  // not just the first one, so a column that appears later still
  // shows up.
  let content = "[{\"a\":1},{\"b\":2}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(0, "b"), @types.Scalar::Null)
  assert_eq(df.item(1, "a"), @types.Scalar::Null)
}

///|
test "parse_json_str: mixed-dtype column falls back to String" {
  // `1` is an Int candidate, `"two"` is a String candidate — no
  // single dtype accepts both, so the inference order ends at the
  // String fallback and numeric cells are restringified.
  let content = "[{\"x\":1},{\"x\":\"two\"},{\"x\":3}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("1"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("two"))
  assert_eq(df.item(2, "x"), @types.Scalar::String("3"))
}

// ── parse_json_str: edge / error paths ──────────────────────

///|
test "parse_json_str: empty input yields a 0x0 frame" {
  let df = @io.parse_json_str("")
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_str: whitespace-only input yields a 0x0 frame" {
  // A whitespace-only payload is "no payload": it collapses to 0×0 like empty
  // input and like the NDJSON reader (which skips blank lines), rather than
  // raising on an absent top-level value.
  let df = @io.parse_json_str("  \n\t ")
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_str: empty array yields a 0x0 frame" {
  let df = @io.parse_json_str("[]")
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_str: array of empty objects keeps the record count" {
  // `[{}, {}]` is 2 records with 0 fields: the `N×0` frame, not the shape
  // empty input produces. The records are there to be counted, and a later
  // `with_columns` can still compute over them.
  let df = @io.parse_json_str("[{},{}]")
  assert_eq(df.shape(), (2, 0))
  assert_false(df.is_empty())
}

///|
test "parse_json_str: strips a leading UTF-8 BOM (Excel / utf-8-sig)" {
  // A file saved with a UTF-8 BOM must read like a clean one — matching the
  // CSV reader. Left in place the BOM makes `@json.parse` reject
  // the payload at column 0.
  let df = @io.parse_json_str("\u{FEFF}[{\"a\":1,\"b\":2}]")
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.shape(), (1, 2))
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
}

///|
test "parse_json_str: a BOM-only payload still reads as empty" {
  let df = @io.parse_json_str("\u{FEFF}")
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_json_str: non-array top-level returns ParseError" {
  let result = Ok(@io.parse_json_str("{\"a\":1}")) catch { e => Err(e) }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_str: non-object record returns ParseError" {
  let result = Ok(@io.parse_json_str("[1,2,3]")) catch { e => Err(e) }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_str: malformed JSON returns ParseError" {
  let result = Ok(@io.parse_json_str("[{")) catch { e => Err(e) }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_str: typed mismatch has structured record context" {
  // First two records lock the dtype on Int; the third sneaks in a
  // string. The builder rejects the unparseable cell with
  // a structured cell error rather than silently widening the column.
  let content = "[{\"x\":1},{\"x\":2},{\"x\":\"three\"}]"
  let result = Ok(
    @io.parse_json_str(
      content,
      options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=2),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
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
test "parse_json_str: Float column with non-number past inference errors" {
  // Inference locks Float on the first two records; the third
  // sneaks a string in, which `json_value_as_float` rejects.
  let content = "[{\"x\":1.5},{\"x\":2.5},{\"x\":\"oops\"}]"
  let result = Ok(
    @io.parse_json_str(
      content,
      options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=2),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
          "x",
          3,
          @types.DataType::Float,
          "oops",
        ),
      ),
    ),
  )
}

///|
test "parse_json_str: Bool column with non-bool past inference errors" {
  // Locks Bool on the first two records, then rejects the numeric
  // cell — `json_value_as_bool` refuses `Number(1)` per the same
  // convention `parse_csv_str` uses for `parse_bool_opt`.
  let content = "[{\"x\":true},{\"x\":false},{\"x\":1}]"
  let result = Ok(
    @io.parse_json_str(
      content,
      options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=2),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
          "x",
          3,
          @types.DataType::Bool,
          "1",
        ),
      ),
    ),
  )
}

// ── O4 read resilience (scan-all / on_parse_error) ──────────────────

///|
test "parse_json_str: infer_schema_rows=0 scans every record" {
  // Record 1 is an integral number, record 2 fractional. A 1-record window
  // would lock Int and reject 2.5; scanning every record (`0`) types the
  // column Float up front.
  let content = "[{\"x\":1},{\"x\":2.5}]"
  let df = @io.parse_json_str(
    content,
    options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=0),
  )
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "x"), @types.Scalar::Float(2.5))
}

///|
test "parse_json_str: on_parse_error=Null nulls an out-of-window misfit" {
  // First two records lock Int; the third is a string. `Raise` (the
  // default, exercised above) errors; `Null` keeps the Int column and
  // downgrades the bad cell to null.
  let content = "[{\"x\":1},{\"x\":2},{\"x\":\"three\"}]"
  let df = @io.parse_json_str(
    content,
    options=@io.JsonReadOptions::JsonReadOptions(
      infer_schema_rows=2,
      on_parse_error=@io.OnParseError::Null,
    ),
  )
  assert_eq(df.get_column("x").dtype(), @types.DataType::Int)
  assert_eq(df.item(0, "x"), @types.Scalar::Int(1))
  assert_eq(df.item(2, "x"), @types.Scalar::Null)
  assert_eq(df.get_column("x").null_count(), 1)
}

// ── inference edge cases ────────────────────────────────────────────

///|
test "parse_json_str: all-null column defaults to String dtype" {
  // No non-null cell exists to disambiguate the dtype, so the
  // inference pass falls back to the same `String` default the CSV
  // reader uses for an entirely-null probe window.
  let content = "[{\"x\":null},{\"x\":null}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.get_column("x").null_count(), 2)
}

///|
test "parse_json_str: Bool + Int mix collapses to String" {
  // `true` kills the Int / Float / String candidates while keeping
  // Bool; `1` then kills Bool. With every candidate false, the
  // final `else` branch in the dtype cascade returns `JsonString`
  // and the build pass restringifies each cell via the fallback
  // (`True → "true"`, `Number(1, ..) → "1"`).
  let content = "[{\"x\":true},{\"x\":false},{\"x\":1}]"
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("true"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("false"))
  assert_eq(df.item(2, "x"), @types.Scalar::String("1"))
}

///|
test "parse_json_str: array and object cells in one column fall back to String" {
  // An array and an object are two nested shapes with no dtype in common,
  // so no one column dtype holds both cells: the column takes the String
  // fallback, each cell as its text — the fallback a column mixing two
  // scalar dtypes takes.
  let content =
    #|[{"x":[1,2,3]},{"x":{"k":1}}]
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("[1,2,3]"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("{\"k\":1}"))
}

// ── read_json / write_json: file-system path ────────────────

///|
test "write_json then read_json round-trips a small frame on disk" {
  let path = "_build/io_json_test_roundtrip.json"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["x", "y", "z"]),
  ])
  @io.write_json(path, df)
  let parsed = @io.read_json(path)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.item(2, "n"), @types.Scalar::Int(3))
  assert_eq(parsed.item(0, "s"), @types.Scalar::String("x"))
}

///|
test "read_json honours a custom inference window from its options" {
  let path = "_build/io_json_test_custom.json"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("a", [Some(1), Some(2), Some(3)]),
  ])
  @io.write_json(path, df)
  let parsed = @io.read_json(
    path,
    options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=1),
  )
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
test "read_json with options: missing file surfaces as IoError" {
  // The open failure precedes any option, so passing a non-default one must
  // not change which error surfaces.
  let result = Ok(
    @io.read_json(
      "_build/io_json_test_does_not_exist.json",
      options=@io.JsonReadOptions::JsonReadOptions(
        infer_schema_rows=1,
        on_parse_error=@io.OnParseError::Null,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_json: invalid path surfaces as IoError" {
  // Same shape as the CSV writer error test: aim the writer at a
  // directory that doesn't exist so the underlying `@fs` call
  // surfaces `IOError`, which we promote to `DataError::IoError`.
  let df = @frame.DataFrame::DataFrame([@series.Series::from_ints("a", [1])])
  let result = Ok(
    @io.write_json("_build/no_such_dir_io_json_test/file.json", df),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

// ── round-trip ──────────────────────────────────────────────────────

///|
test "format_json / parse_json_str round-trip preserves data" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
    @series.Series::from_floats("r", [
      (1.5 : Double),
      (2.5 : Double),
      (3.5 : Double),
    ]),
    @series.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  let json = @io.format_json(df)
  let df2 = @io.parse_json_str(json)
  // Frame equality is by content — dtype, null-ness, and cell values — not by
  // representation, so the reader building `Builtin` columns where the
  // original `r` took the `Numeric` fast path does not enter into it.
  assert_eq(df2, df)
}

///|
test "round-trip narrows an all-integral Float column to Int (documented caveat)" {
  // JSON has a single number type and `Double::to_string` drops the
  // fractional part of a whole value (`2.0` → "2"), so a `Float` column whose
  // cells are all integral comes back as `Int` after `format_json` →
  // `parse_json_str`. Only the dtype narrows (`Float → Int`); the
  // values are preserved. This pins the documented integral-`Float`
  // narrowing caveat — and is why the round-trip test above uses fractional
  // cells (1.5 / 2.5 / 3.5), which stay `Float`.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("r", [(2.0 : Double), (3.0 : Double)]),
  ])
  assert_eq(df.get_column("r").dtype(), @types.DataType::Float)
  let df2 = @io.parse_json_str(@io.format_json(df))
  assert_eq(df2.get_column("r").dtype(), @types.DataType::Int)
  assert_eq(df2.item(0, "r"), @types.Scalar::Int(2))
  assert_eq(df2.item(1, "r"), @types.Scalar::Int(3))
}

// ── duplicate object keys: last-wins default, optional strict ───────────

///|
test "a repeated object key keeps its last value by default" {
  // `@json.parse` folds an object into a `Map`, so the second spelling of a
  // key replaces the first — the common JSON last-wins reading. Pinned
  // here so the strict option below has a default to differ from.
  let df = @io.parse_json_str("[{\"a\": 1, \"a\": 2}]")
  assert_eq(df.item(0, "a"), @types.Scalar::Int(2))
}

///|
test "reject_duplicate_keys fails the read naming the key and object" {
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[{\"a\": 1}, {\"b\": 1, \"b\": 2}]", options=opts),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_eq(m, "duplicate key \"b\" at line 1, column 20")
    _ => fail("expected a duplicate-key ParseError")
  }
}

///|
test "reject_duplicate_keys scans nested objects too" {
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  // The nested value object is the payload's 2nd object; its key repeats.
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[{\"outer\": {\"x\": 1, \"x\": 2}}]", options=opts),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_eq(m, "duplicate key \"x\" at line 1, column 20")
    _ => fail("expected a duplicate-key ParseError")
  }
}

///|
test "reject_duplicate_keys defers a lone-surrogate key to the parser" {
  // A `\uD800`-style escape is not valid JSON — the core parser refuses it,
  // so the strict scan must not pre-empt that diagnostic with a
  // duplicate-key message: the repeat is only visible in such a payload
  // through a token carrying the lone surrogate itself, and no message
  // should embed that string. Both readings report the parser's own
  // diagnostic.
  let payload = "{\"\\uD800\": 1, \"\\uD800\": 2}"
  let strict = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  for opts in [@io.JsonReadOptions::JsonReadOptions(), strict] {
    let result : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.parse_json_str(payload, options=opts),
    ) catch {
      e => Err(e)
    }
    match result {
      Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
        assert_true(m.has_prefix("invalid JSON: "))
      _ => fail("expected the parser's invalid-JSON diagnostic")
    }
  }
}

///|
test "reject_duplicate_keys compares keys decoded, so unicode escapes collide" {
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  // The JSON text spells one key as "a" and again as "\u0061" (the MoonBit
  // literal doubles the backslash); both decode to `a`, exactly as they fold
  // to the same `Map` entry after `@json.parse`.
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[{\"a\": 1, \"\\u0061\": 2}]", options=opts),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_eq(m, "duplicate key \"a\" at line 1, column 10")
    _ => fail("expected a duplicate-key ParseError")
  }
}

///|
test "reject_duplicate_keys passes a payload without repeats" {
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  let df = @io.parse_json_str(
    "[{\"a\": 1}, {\"a\": 3, \"b\": 4}]",
    options=opts,
  )
  assert_eq(df.nrows(), 2)
  assert_eq(df.item(1, "b"), @types.Scalar::Int(4))
}

///|
test "reject_duplicate_keys decodes every escape spelling before comparing" {
  // One key spelled twice with the same escape sequence (`\t` here), so the
  // duplicate is found after decoding; the reported key carries the decoded
  // character. The `\u00ff` pair exercises the hex letters arm of the
  // `\uXXXX` decoder the same way.
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[{\"a\\tb\": 1, \"a\\tb\": 2}]", options=opts),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_true(m.has_prefix("duplicate key \"a\tb\" at line 1,"))
    _ => fail("expected a duplicate-key ParseError")
  }
  let result2 : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[{\"\\u00ff\": 1, \"\\u00ff\": 2}]", options=opts),
  ) catch {
    e => Err(e)
  }
  match result2 {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_true(m.has_prefix("duplicate key \"\u{ff}\" at line 1,"))
    _ => fail("expected a duplicate-key ParseError")
  }
  // Uppercase hex digits take the decoder's other arm and land on the same
  // key.
  let result3 : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[{\"\\u00AB\": 1, \"\\u00ab\": 2}]", options=opts),
  ) catch {
    e => Err(e)
  }
  match result3 {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_true(m.has_prefix("duplicate key \"\u{ab}\" at line 1,"))
    _ => fail("expected a duplicate-key ParseError")
  }
}

///|
test "reject_duplicate_keys decodes each simple escape spelling" {
  // Every two-character escape JSON defines, as a key spelled the same way
  // twice so the duplicate is found after decoding. The expected key is the
  // decoded character the escape names.
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  let cases : Array[(String, String)] = [
    ("\\\"", "\""), // \" → "
    ("\\\\", "\\"), // \\ → backslash
    ("\\/", "/"), // \/ → /
    ("\\b", "\b"), // \b → backspace
    ("\\f", "\u{000C}"), // \f → form feed
    ("\\n", "\n"), // \n → newline
    ("\\r", "\r"), // \r → carriage return
    ("\\t", "\t"), // \t → tab
  ]
  for case in cases {
    let esc = case.0
    let decoded = case.1
    let payload = "[{\"" + esc + "\": 1, \"" + esc + "\": 2}]"
    let result : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.parse_json_str(payload, options=opts),
    ) catch {
      e => Err(e)
    }
    match result {
      Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
        assert_true(
          m.has_prefix("duplicate key \"" + decoded + "\" at line 1,"),
        )
      _ => fail("expected a duplicate-key ParseError")
    }
  }
}

///|
test "string values and array items are not keys" {
  // The scanner records a string literal only in key position; values and
  // array elements pass through, so a repeated *value* is not a duplicate
  // key and the read succeeds.
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  let df = @io.parse_json_str(
    "[{\"k\": \"same\", \"l\": [\"same\", \"same\"]}, {\"k\": \"same\"}]",
    options=opts,
  )
  assert_eq(df.nrows(), 2)
  assert_eq(df.item(0, "k"), @types.Scalar::String("same"))
}

///|
test "reject_duplicate_keys leaves malformed payloads to the parser" {
  // The scanner tolerates out-of-shape input — a trailing lone backslash,
  // an unknown escape, a short `\u`, a stray closer, a top-level comma, a
  // bare top-level string — and reports nothing, so the diagnostic the
  // caller sees is `@json.parse`'s own, not a half-scanned guess.
  let opts = @io.JsonReadOptions::JsonReadOptions(reject_duplicate_keys=true)
  let malformed = [
    "[{\"a\\", // string ends at the lone trailing backslash
     "[{\"a\\q\": 1}]", // unknown escape
     "[{\"a\\u00\": 1}]", // short \u escape (non-hex terminator)
     "[{\"a\\u", // \u at end of input: not even four characters remain
     "[{\"a\":1,\"a", // truncated second key aliases the first: not a repeat
     "}", // stray closer before any object
     ",", // top-level comma outside any container
  ]
  for payload in malformed {
    let result : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.parse_json_str(payload, options=opts),
    ) catch {
      e => Err(e)
    }
    match result {
      Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
        assert_true(m.contains("invalid JSON"))
      _ => fail("expected the parser's own invalid-JSON diagnostic")
    }
  }
  // A bare top-level string scans (no object, no keys) and is rejected by
  // the array check, not by the scan.
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("\"just a string\"", options=opts),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_eq(m, "expected a JSON array of objects at the top level")
    _ => fail("expected the top-level shape diagnostic")
  }
}

///|
test "allow_nonfinite_floats=false keeps an overflowing number column String" {
  // The JSON counterpart of the CSV gate: `1e999` overflows Double, and the
  // default read infers the column Float with Infinity cells; with the gate
  // on, the number is not Float evidence, so the column stays String.
  let open = @io.parse_json_str("[{\"a\": 1e999}, {\"a\": 1.5}]")
  assert_eq(open.get_column("a").dtype(), @types.DataType::Float)
  assert_true(open.item(0, "a") is @types.Scalar::Float(v) && v.is_inf())
  let gated = @io.parse_json_str(
    "[{\"a\": 1e999}, {\"a\": 1.5}]",
    options=@io.JsonReadOptions::JsonReadOptions(allow_nonfinite_floats=false),
  )
  assert_eq(gated.get_column("a").dtype(), @types.DataType::String)
  // NDJSON shares the gate through the same options type.
  let gated_ndjson = @io.parse_ndjson_str(
    "{\"a\": 1e999}\n{\"a\": 1.5}",
    options=@io.JsonReadOptions::JsonReadOptions(allow_nonfinite_floats=false),
  )
  assert_eq(gated_ndjson.get_column("a").dtype(), @types.DataType::String)
}

///|
test "parse_json_str: dtypes override pins a column ahead of inference" {
  // `a` holds integral numbers, which inference narrows to Int (the
  // integral-Float caveat); the pin holds it at Float. `b` holds numbers,
  // which no inference would read as String; the pin renders their text
  // form, the String-fallback rule.
  let content = "[{\"a\": 1, \"b\": 2}, {\"a\": 2, \"b\": 3.5}]"
  let opts = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("a", @types.DataType::Float), ("b", @types.DataType::String)]),
  )
  let df = @io.parse_json_str(content, options=opts)
  assert_eq(df.get_column("a").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "a"), @types.Scalar::Float(1.0))
  assert_eq(df.item(0, "b"), @types.Scalar::String("2"))
  assert_eq(df.item(1, "b"), @types.Scalar::String("3.5"))
}

///|
test "parse_json_str: a JSON string never coerces into a pinned Int" {
  // JSON has strong types — a String cell in a column pinned Int is a
  // locked-in mismatch, not a text coercion: it follows `on_parse_error`
  // exactly as a post-window mismatch does.
  let content = "[{\"a\": 1}, {\"a\": \"2\"}]"
  let strict = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("a", @types.DataType::Int)]),
  )
  let result = Ok(@io.parse_json_str(content, options=strict)) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
          "a",
          2,
          @types.DataType::Int,
          "2",
        ),
      ),
    ),
  )
  let lenient = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("a", @types.DataType::Int)]),
    on_parse_error=Null,
  )
  let df = @io.parse_json_str(content, options=lenient)
  assert_eq(df.get_column("a").dtype(), @types.DataType::Int)
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.item(1, "a"), @types.Scalar::Null)
}

///|
test "parse_json_str: the rider pins read JSON strings, and only strings" {
  // The riders have no JSON-native type, so a pin reads the writer's text
  // form out of a `String` value — the one carrier. A `Number` under a
  // `Decimal` pin refuses rather than coercing.
  let content = "[{\"d\": \"2024-01-02\", \"t\": \"1970-01-01T00:00:00.000000Z\", \"x\": \"1.5\"}]"
  let opts = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([
      ("d", @types.DataType::Date),
      ("t", @types.DataType::Timestamp),
      ("x", @types.DataType::Decimal),
    ]),
  )
  let df = @io.parse_json_str(content, options=opts)
  assert_eq(df.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(df.get_column("t").dtype(), @types.DataType::Timestamp)
  assert_eq(df.get_column("x").dtype(), @types.DataType::Decimal)
  assert_eq(df.item(0, "d"), @types.Scalar::Date(19724L))
  assert_eq(df.item(0, "t"), @types.Scalar::Timestamp(0L))
  assert_eq(
    df.item(0, "x"),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(150L, scale=2)),
  )
  // A JSON number under a rider pin is the located refusal, the riders'
  // counterpart of "a JSON string never coerces into a pinned Int".
  let number = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("x", @types.DataType::Decimal)]),
  )
  let result = Ok(@io.parse_json_str("[{\"x\": 1.5}]", options=number)) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
          _,
          _,
          _,
          _,
        ),
      ),
    ),
  )
  // The resilient policy nulls the off-form cell and keeps the pin.
  let lenient = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("x", @types.DataType::Decimal)]),
    on_parse_error=Null,
  )
  let nulled = @io.parse_json_str("[{\"x\": 1.5}]", options=lenient)
  assert_eq(nulled.get_column("x").dtype(), @types.DataType::Decimal)
  assert_true(nulled.item(0, "x") is @types.Scalar::Null)
  // Every rider refuses a non-string the same way — a Number under the
  // temporal pins too, with the pin's own dtype in the located error.
  for pair in [("d", @types.DataType::Date), ("t", @types.DataType::Timestamp)] {
    let (name, dt) = pair
    let opts = @io.JsonReadOptions::JsonReadOptions(dtypes=Map([(name, dt)]))
    let bad : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.parse_json_str("[{\"d\": 12, \"t\": 1.5}]", options=opts),
    ) catch {
      e => Err(e)
    }
    match bad {
      Err(
        @types.DataError::ParseError(
          @types.ParseErrorDetail::Cell(_, _, _, expected, _),
        ),
      ) => assert_eq(expected, dt)
      _ => fail("expected a located ParseError for \{dt}")
    }
  }
  // A null cell stays null under a decimal pin.
  let with_null = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("x", @types.DataType::Decimal)]),
  )
  let nulled_row = @io.parse_json_str(
    "[{\"x\": null}, {\"x\": \"1.5\"}]",
    options=with_null,
  )
  assert_true(nulled_row.item(0, "x") is @types.Scalar::Null)
  assert_eq(
    nulled_row.item(1, "x"),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(150L, scale=2)),
  )
}

///|
test "parse_json_str: a Null pin and a misspelt name are refused like the CSV reader's" {
  let content = "[{\"a\": 1}]"
  // `Null` has no read parser; a name the input does not carry stays the
  // caller's false assertion.
  let unsupported = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("a", @types.DataType::Null)]),
  )
  let result = Ok(@io.parse_json_str(content, options=unsupported)) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  let missing = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("nope", @types.DataType::Int)]),
  )
  let result2 = Ok(@io.parse_json_str(content, options=missing)) catch {
    e => Err(e)
  }
  assert_true(result2 is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "an empty JSON array still checks its dtype pins" {
  let opts = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("emp_id", @types.DataType::Int)]),
  )
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("[]", options=opts),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "blank JSON still checks its dtype pins" {
  // The blank short-circuit predates the pin check and skipped it: a
  // misspelt pin rode an empty / whitespace-only / BOM-only file as a
  // silent 0×0 success where the empty array and the NDJSON / CSV
  // readers refuse. The short-circuit now asserts the pins too.
  let opts = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("emp_id", @types.DataType::Int)]),
  )
  for payload in ["", "  \n\t ", "\u{FEFF}"] {
    let result : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.parse_json_str(payload, options=opts),
    ) catch {
      e => Err(e)
    }
    assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  }
  // With no pins, the blank read keeps its 0×0 shape.
  let blank : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str("  \n\t "),
  ) catch {
    e => Err(e)
  }
  assert_true(blank is Ok(_))
  if blank is Ok(df) {
    assert_eq(df.nrows(), 0)
    assert_eq(df.ncols(), 0)
  }
}

// ── deep-nesting pre-scan ───────────────────────────────────

///|
test "nesting past 512 brackets refuses before the parse, not with an abort" {
  // 600 open brackets: the parser's per-level recursion would exhaust the
  // stack (a core abort nothing here could catch), so the pre-scan refuses
  // at the 513th with a located ParseError instead.
  let result : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.parse_json_str(String::make(600, '[')),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) =>
      assert_eq(
        m, "invalid JSON: nesting deeper than 512 brackets at line 1, column 513",
      )
    _ => fail("expected a deep-nesting ParseError")
  }
}

///|
test "a 500-deep nested array still parses under the cap" {
  // The wrapper array and object add two levels on top of the 500 — 502
  // total, under the 512 cap — so the read succeeds and the nested value
  // lands as its string fallback.
  let inner = String::make(500, '[') + String::make(500, ']')
  let payload = "[{\"v\":" + inner + "}]"
  let df = @io.parse_json_str(payload)
  assert_eq(df.shape(), (1, 1))
}

///|
test "brackets inside string literals do not count toward the depth" {
  // 600 open brackets, all inside one string cell: the scan tracks
  // quoting, so the payload parses and the cell carries them verbatim.
  let brackets = String::make(600, '[')
  let df = @io.parse_json_str("[{\"a\":\"\{brackets}\"}]")
  assert_eq(df.shape(), (1, 1))
  assert_eq(df.item(0, "a"), @types.Scalar::String(brackets))
}

///|
test "JSON writes a nested cell as the array or object it is" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "l",
      [
        @types.Scalar::List(
          @types.ListValue::ListValue([
            @types.Scalar::Int(1),
            @types.Scalar::Null,
            @types.Scalar::Int(2),
          ]),
        ),
        @types.Scalar::Null,
        @types.Scalar::List(@types.ListValue::ListValue([])),
      ],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
    @series.Series::from_scalars(
      "s",
      [
        @types.Scalar::Struct(
          @types.StructValue::StructValue([
            @types.FieldValue::FieldValue("a", @types.Scalar::Int(1)),
            @types.FieldValue::FieldValue("b", @types.Scalar::Bool(true)),
          ]),
        ),
        @types.Scalar::Struct(
          @types.StructValue::StructValue([
            @types.FieldValue::FieldValue("a", @types.Scalar::Null),
            @types.FieldValue::FieldValue("b", @types.Scalar::Bool(false)),
          ]),
        ),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Struct(
        @types.Schema::Schema([
          @types.Field::Field("a", @types.DataType::Int),
          @types.Field::Field("b", @types.DataType::Bool),
        ]),
      ),
    ),
  ])
  let text = @io.format_json(df)
  // Records in order; a nested cell is JSON of its own shape; a null
  // cell is `null`.
  assert_eq(
    text, "[{\"l\":[1,null,2],\"s\":{\"a\":1,\"b\":true}},{\"l\":null,\"s\":{\"a\":null,\"b\":false}},{\"l\":[],\"s\":null}]",
  )
}

///|
fn lv(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn fv(name : String, value : @types.Scalar) -> @types.FieldValue {
  @types.FieldValue::FieldValue(name, value)
}

///|
fn sv(fields : Array[@types.FieldValue]) -> @types.Scalar {
  @types.Scalar::Struct(@types.StructValue::StructValue(fields))
}

///|
fn int_list(cells : Array[Int64]) -> @types.Scalar {
  lv(cells.map(i => @types.Scalar::Int(i)))
}

///|
fn float_list(cells : Array[Double]) -> @types.Scalar {
  lv(cells.map(v => @types.Scalar::Float(v)))
}

///|
fn string_list(cells : Array[String]) -> @types.Scalar {
  lv(cells.map(s => @types.Scalar::String(s)))
}

///|
fn list_dtype(element : @types.DataType) -> @types.DataType {
  @types.DataType::List(element)
}

///|
fn one_field_struct(
  name : String,
  dtype : @types.DataType,
) -> @types.DataType raise @types.DataError {
  @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field(name, dtype)]),
  )
}

///|
fn struct_dtype(
  a : @types.DataType,
  b : @types.DataType,
) -> @types.DataType raise @types.DataError {
  @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("a", a),
      @types.Field::Field("b", b),
    ]),
  )
}

// ── nested columns: arrays and objects ───────────────────────────────

///|
test "JSON reads an array as a list column and an object as a struct column" {
  let content =
    #|[{"x":[1,2,3],"y":{"k":true}},{"x":null,"y":null},{"x":[],"y":{}}]
  let df = @io.parse_json_str(content)
  assert_eq(df.shape(), (3, 2))
  assert_eq(df.get_column("x").dtype(), list_dtype(@types.DataType::Int))
  assert_eq(df.get_column("x").to_scalars().copy(), [
    int_list([1, 2, 3]),
    @types.Scalar::Null,
    lv([]),
  ])
  // An object's fields follow the order the record spells them, and an
  // object with no field reads as a struct whose fields are all null.
  let one_bool = one_field_struct("k", @types.DataType::Bool)
  assert_eq(df.get_column("y").dtype(), one_bool)
  assert_eq(df.get_column("y").to_scalars().copy(), [
    sv([fv("k", @types.Scalar::Bool(true))]),
    @types.Scalar::Null,
    sv([fv("k", @types.Scalar::Null)]),
  ])
}

///|
test "JSON nests lists and structs to any depth" {
  let content =
    #|[{"x":[[1],[2,3]],"y":{"a":{"b":[1.5]},"c":[null]}}]
  let df = @io.parse_json_str(content)
  assert_eq(
    df.get_column("x").dtype(),
    list_dtype(list_dtype(@types.DataType::Int)),
  )
  assert_eq(df.get_column("x").to_scalars().copy(), [
    lv([int_list([1]), int_list([2, 3])]),
  ])
  assert_eq(
    df.get_column("y").dtype(),
    @types.DataType::Struct(
      @types.Schema::Schema([
        @types.Field::Field(
          "a",
          one_field_struct("b", list_dtype(@types.DataType::Float)),
        ),
        @types.Field::Field("c", list_dtype(@types.DataType::String)),
      ]),
    ),
  )
  assert_eq(
    df.get_column("y").dtype().to_string(),
    "Struct(a: Struct(b: List(Float)), c: List(String))",
  )
  assert_eq(df.get_column("y").to_scalars().copy(), [
    sv([
      fv("a", sv([fv("b", float_list([1.5]))])),
      fv("c", lv([@types.Scalar::Null])),
    ]),
  ])
}

///|
test "the element dtype is read off every element in the window" {
  // An empty list and a list of nulls name nothing and are passed over,
  // at the top of the column and inside a cell; the integers that follow
  // name the element dtype, and the nameless lists fit it.
  let content =
    #|[{"x":[]},{"x":[null]},{"x":[4]},{"x":[5]}]
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), list_dtype(@types.DataType::Int))
  assert_eq(df.get_column("x").to_scalars().copy(), [
    lv([]),
    lv([@types.Scalar::Null]),
    int_list([4]),
    int_list([5]),
  ])
  let inner =
    #|[{"x":[[],[7]]}]
  let nested = @io.parse_json_str(inner)
  assert_eq(
    nested.get_column("x").dtype(),
    list_dtype(list_dtype(@types.DataType::Int)),
  )
  assert_eq(nested.get_column("x").to_scalars().copy(), [
    lv([lv([]), int_list([7])]),
  ])
}

///|
test "a struct's fields are the union of its objects' fields" {
  // Each object names its fields; the column's struct takes them all, in
  // first-seen order, and an object that leaves one out reads a null
  // there — the rule the reader's own records follow. The last object
  // spells its fields in the other order and is read by name.
  let content =
    #|[{"p":{"a":1}},{"p":{"b":1.5}},{"p":{"a":2,"b":2.5}},{"p":{"b":3,"a":4}}]
  let df = @io.parse_json_str(content)
  assert_eq(
    df.get_column("p").dtype(),
    struct_dtype(@types.DataType::Int, @types.DataType::Float),
  )
  assert_eq(df.get_column("p").to_scalars().copy(), [
    sv([fv("a", @types.Scalar::Int(1)), fv("b", @types.Scalar::Null)]),
    sv([fv("a", @types.Scalar::Null), fv("b", @types.Scalar::Float(1.5))]),
    sv([fv("a", @types.Scalar::Int(2)), fv("b", @types.Scalar::Float(2.5))]),
    sv([fv("a", @types.Scalar::Int(4)), fv("b", @types.Scalar::Float(3.0))]),
  ])
}

///|
test "JSON nested numbers follow the top-level number rules" {
  // An integer-valued number is an `Int`, a fractional one a `Float`, a
  // list of mixed numbers a list of `Float`s, and a large integer keeps
  // its exact digits inside a list as it does at the top level.
  let content =
    #|[{"x":[1],"y":[1.5],"z":[1,2.5],"w":[9223372036854775807],"v":[1e2]}]
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), list_dtype(@types.DataType::Int))
  assert_eq(df.get_column("y").dtype(), list_dtype(@types.DataType::Float))
  assert_eq(df.get_column("z").dtype(), list_dtype(@types.DataType::Float))
  assert_eq(df.get_column("z").to_scalars().copy(), [float_list([1.0, 2.5])])
  assert_eq(df.get_column("w").to_scalars().copy(), [
    int_list([9_223_372_036_854_775_807L]),
  ])
  assert_eq(df.get_column("v").to_scalars().copy(), [int_list([100L])])
  // Strings and booleans inside a list.
  let kinds =
    #|[{"x":["a","b"],"y":[true,false]}]
  let typed = @io.parse_json_str(kinds)
  assert_eq(typed.get_column("x").dtype(), list_dtype(@types.DataType::String))
  assert_eq(typed.get_column("y").dtype(), list_dtype(@types.DataType::Bool))
  assert_eq(typed.get_column("x").to_scalars().copy(), [string_list(["a", "b"])])
  assert_eq(typed.get_column("y").to_scalars().copy(), [
    lv([@types.Scalar::Bool(true), @types.Scalar::Bool(false)]),
  ])
}

///|
test "elements no one dtype accepts read as their text" {
  // A list mixing numbers, strings, and booleans, or holding a list or an
  // object beside a scalar, has no dtype but `String`: each element is
  // kept as its text, the fallback a column mixing scalar dtypes takes.
  let content =
    #|[{"x":[1,"a"],"y":[true,1],"z":[1,[2]],"w":[{"k":1},"v"]}]
  let df = @io.parse_json_str(content)
  for name in ["x", "y", "z", "w"] {
    assert_eq(df.get_column(name).dtype(), list_dtype(@types.DataType::String))
  }
  assert_eq(df.get_column("x").to_scalars().copy(), [string_list(["1", "a"])])
  assert_eq(df.get_column("y").to_scalars().copy(), [string_list(["true", "1"])])
  assert_eq(df.get_column("z").to_scalars().copy(), [string_list(["1", "[2]"])])
  assert_eq(df.get_column("w").to_scalars().copy(), [
    string_list(["{\"k\":1}", "v"]),
  ])
  // A struct's field is read the same way.
  let field =
    #|[{"p":{"a":1}},{"p":{"a":"x"}}]
  let mixed = @io.parse_json_str(field)
  assert_eq(
    mixed.get_column("p").dtype(),
    one_field_struct("a", @types.DataType::String),
  )
  assert_eq(mixed.get_column("p").to_scalars().copy(), [
    sv([fv("a", @types.Scalar::String("1"))]),
    sv([fv("a", @types.Scalar::String("x"))]),
  ])
}

///|
test "a non-finite number inside a nested cell follows the float gate" {
  // A magnitude past the Double is an infinity: carried under the default
  // gate, and under the strict gate not a Float at all — its position
  // falls to text, as a scalar column of such tokens falls to `String`.
  let content =
    #|[{"x":[1.5,1e999]}]
  let carried = @io.parse_json_str(content)
  assert_eq(carried.get_column("x").dtype(), list_dtype(@types.DataType::Float))
  let cells = carried.get_column("x").to_scalars().copy()
  assert_true(cells[0] is @types.Scalar::List(v) && v.len() == 2)
  assert_true(
    cells[0] is @types.Scalar::List(v) &&
    v.get(0) is @types.Scalar::Float(a) &&
    a == 1.5,
  )
  assert_true(
    cells[0] is @types.Scalar::List(v) &&
    v.get(1) is @types.Scalar::Float(b) &&
    b.is_inf(),
  )
  let gated = @io.parse_json_str(
    content,
    options=@io.JsonReadOptions::JsonReadOptions(allow_nonfinite_floats=false),
  )
  assert_eq(gated.get_column("x").dtype(), list_dtype(@types.DataType::String))
  assert_eq(gated.get_column("x").to_scalars().copy(), [
    string_list(["1.5", "1e999"]),
  ])
}

///|
test "a position with no value to name a dtype defaults to String" {
  // No elements, no fields, every value null: the position has nothing to
  // say which dtype it carries and takes the all-null default, so the
  // list and the struct keep their shape.
  let content =
    #|[{"x":[],"y":{"a":null},"z":[null]},{"x":[],"y":{"a":null},"z":[null]}]
  let df = @io.parse_json_str(content)
  assert_eq(df.get_column("x").dtype(), list_dtype(@types.DataType::String))
  assert_eq(df.get_column("x").to_scalars().copy(), [lv([]), lv([])])
  assert_eq(
    df.get_column("y").dtype(),
    one_field_struct("a", @types.DataType::String),
  )
  assert_eq(df.get_column("y").to_scalars().copy(), [
    sv([fv("a", @types.Scalar::Null)]),
    sv([fv("a", @types.Scalar::Null)]),
  ])
  assert_eq(df.get_column("z").dtype(), list_dtype(@types.DataType::String))
  assert_eq(df.get_column("z").to_scalars().copy(), [
    lv([@types.Scalar::Null]),
    lv([@types.Scalar::Null]),
  ])
  // An object with no field names no column to build, so a window of only
  // those keeps each cell as its text.
  let empty =
    #|[{"x":{}},{"x":{}}]
  let text = @io.parse_json_str(empty)
  assert_eq(text.get_column("x").dtype(), @types.DataType::String)
  assert_eq(text.get_column("x").to_scalars().copy(), [
    @types.Scalar::String("{}"),
    @types.Scalar::String("{}"),
  ])
  // A nested column whose cells are all null stays a null String column,
  // like any other.
  let nulls =
    #|[{"x":null},{"x":null}]
  let absent = @io.parse_json_str(nulls)
  assert_eq(absent.get_column("x").dtype(), @types.DataType::String)
  assert_eq(absent.get_column("x").null_count(), 2)
}

///|
test "the inference window bounds a nested column's dtype" {
  // Two empty lists in a window of two name no element dtype, so the
  // column is a list of text, and the integer past the window is read as
  // text too. A window that reaches the naming cell infers the list of
  // integers, as the uncapped scan does.
  let content =
    #|[{"x":[]},{"x":[]},{"x":[1]}]
  let windowed = @io.parse_json_str(
    content,
    options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=2),
  )
  assert_eq(
    windowed.get_column("x").dtype(),
    list_dtype(@types.DataType::String),
  )
  assert_eq(windowed.get_column("x").to_scalars().copy(), [
    lv([]),
    lv([]),
    string_list(["1"]),
  ])
  for rows in [3, 0] {
    let df = @io.parse_json_str(
      content,
      options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=rows),
    )
    assert_eq(df.get_column("x").dtype(), list_dtype(@types.DataType::Int))
    assert_eq(df.get_column("x").to_scalars().copy(), [
      lv([]),
      lv([]),
      int_list([1]),
    ])
  }
  // A value past the window that does not fit the inferred dtype is a
  // parse failure at its record, under either policy.
  let late =
    #|[{"x":[1]},{"x":[2]},{"x":["a"]}]
  let strict = Ok(
    ignore(
      @io.parse_json_str(
        late,
        options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=2),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    strict
    is Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
          "x",
          3,
          @types.DataType::List(@types.DataType::Int),
          "[\"a\"]",
        ),
      ),
    ),
  )
  let lenient = @io.parse_json_str(
    late,
    options=@io.JsonReadOptions::JsonReadOptions(
      infer_schema_rows=2,
      on_parse_error=@io.OnParseError::Null,
    ),
  )
  assert_eq(lenient.get_column("x").to_scalars().copy(), [
    int_list([1]),
    int_list([2]),
    @types.Scalar::Null,
  ])
}

///|
test "a nested dtypes pin reads every cell under the named dtype" {
  // Without a pin the column is a list of text, the mixed elements
  // having no dtype but `String`.
  let content =
    #|[{"x":[1,"a"]}]
  let inferred = @io.parse_json_str(content)
  assert_eq(
    inferred.get_column("x").dtype(),
    list_dtype(@types.DataType::String),
  )
  // A `String` pin takes any element as its text, as a `String` column
  // takes any cell.
  let text = @io.parse_json_str(
    content,
    options=@io.JsonReadOptions::JsonReadOptions(
      dtypes=Map([("x", list_dtype(@types.DataType::String))]),
    ),
  )
  assert_eq(text.get_column("x").to_scalars().copy(), [string_list(["1", "a"])])
  // An integer element widens under a `Float` element dtype, the way a
  // top-level `Float` column reads an integer.
  let numbers =
    #|[{"x":[1,2]},{"x":[3]}]
  let floats = @io.parse_json_str(
    numbers,
    options=@io.JsonReadOptions::JsonReadOptions(
      dtypes=Map([("x", list_dtype(@types.DataType::Float))]),
    ),
  )
  assert_eq(floats.get_column("x").to_scalars().copy(), [
    float_list([1.0, 2.0]),
    float_list([3.0]),
  ])
  // A cell that does not fit the pin is a parse failure at its record —
  // an object where the pin names a list, or a JSON string where it names
  // a number (JSON has strong types: text is not an integer).
  let pinned = @io.JsonReadOptions::JsonReadOptions(
    dtypes=Map([("x", list_dtype(@types.DataType::Int))]),
  )
  let object =
    #|[{"x":[1]},{"x":{"k":1}}]
  let quoted =
    #|[{"x":[1]},{"x":["2"]}]
  for misfit in [object, quoted] {
    let strict = Ok(ignore(@io.parse_json_str(misfit, options=pinned))) catch {
      e => Err(e)
    }
    assert_true(
      strict
      is Err(
        @types.DataError::ParseError(
          @types.ParseErrorDetail::Cell(
            @types.CellParseLocation::Record,
            "x",
            2,
            @types.DataType::List(@types.DataType::Int),
            _,
          ),
        ),
      ),
    )
    // Under the resilient policy that cell reads as null.
    let lenient = @io.parse_json_str(
      misfit,
      options=@io.JsonReadOptions::JsonReadOptions(
        dtypes=Map([("x", list_dtype(@types.DataType::Int))]),
        on_parse_error=@io.OnParseError::Null,
      ),
    )
    assert_eq(lenient.get_column("x").to_scalars().copy(), [
      int_list([1]),
      @types.Scalar::Null,
    ])
  }
}

///|
test "a nested pin parses rider elements from the text the writer rendered" {
  // Without a pin a rider keeps its text, as a top-level rider column
  // does; with one the elements parse — the round trip a written-back
  // nested column needs.
  let content =
    #|[{"x":["2024-01-01","2024-01-02"],"y":[{"d":"1970-01-01"}]}]
  let text = @io.parse_json_str(content)
  assert_eq(text.get_column("x").dtype(), list_dtype(@types.DataType::String))
  let date_d = @types.DataType::Date
  let pinned = @io.parse_json_str(
    content,
    options=@io.JsonReadOptions::JsonReadOptions(
      dtypes=Map([
        ("x", list_dtype(date_d)),
        ("y", list_dtype(one_field_struct("d", date_d))),
      ]),
    ),
  )
  assert_eq(pinned.get_column("x").to_scalars().copy(), [
    lv([@types.Scalar::Date(19723L), @types.Scalar::Date(19724L)]),
  ])
  assert_eq(pinned.get_column("y").to_scalars().copy(), [
    lv([sv([fv("d", @types.Scalar::Date(0L))])]),
  ])
  // A timestamp and a decimal element parse the same way.
  let riders =
    #|[{"x":["2024-01-01T00:00:00.000000"],"y":["1.50"]}]
  let parsed = @io.parse_json_str(
    riders,
    options=@io.JsonReadOptions::JsonReadOptions(
      dtypes=Map([
        ("x", list_dtype(@types.DataType::Timestamp)),
        ("y", list_dtype(@types.DataType::Decimal)),
      ]),
    ),
  )
  assert_eq(parsed.get_column("x").to_scalars().copy(), [
    lv([@types.Scalar::Timestamp(1_704_067_200_000_000L)]),
  ])
  assert_eq(parsed.get_column("y").to_scalars().copy(), [
    lv([@types.Scalar::Decimal(@types.Dec128::of_int64_scale(150L, scale=2))]),
  ])
  // Text no rider parser accepts is a parse failure at its record, and a
  // `Duration` element has no text parser and fits nothing.
  let not_a_date =
    #|[{"x":["not-a-date"]}]
  let one_day =
    #|[{"x":["P1D"]}]
  let refused = Ok(
    ignore(
      @io.parse_json_str(
        not_a_date,
        options=@io.JsonReadOptions::JsonReadOptions(
          dtypes=Map([("x", list_dtype(date_d))]),
        ),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    refused
    is Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Record,
          "x",
          1,
          @types.DataType::List(@types.DataType::Date),
          "[\"not-a-date\"]",
        ),
      ),
    ),
  )
  let duration = Ok(
    ignore(
      @io.parse_json_str(
        one_day,
        options=@io.JsonReadOptions::JsonReadOptions(
          dtypes=Map([("x", list_dtype(@types.DataType::Duration))]),
        ),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(duration is Err(@types.DataError::ParseError(_)))
}

///|
test "a struct pin reads its fields by name, in the dtype's order" {
  // The object spells its fields in another order and carries one the
  // dtype does not name: the cell reads the dtype's fields, in the
  // dtype's order, and leaves the extra field behind. A field the object
  // leaves out reads as null.
  let dtype = struct_dtype(@types.DataType::Int, @types.DataType::String)
  let options = @io.JsonReadOptions::JsonReadOptions(dtypes=Map([("p", dtype)]))
  let content =
    #|[{"p":{"b":"x","a":1,"z":true}},{"p":{"a":2}}]
  let df = @io.parse_json_str(content, options~)
  assert_eq(df.get_column("p").to_scalars().copy(), [
    sv([fv("a", @types.Scalar::Int(1)), fv("b", @types.Scalar::String("x"))]),
    sv([fv("a", @types.Scalar::Int(2)), fv("b", @types.Scalar::Null)]),
  ])
  // An array where the pin names a struct does not fit, and neither does
  // an object whose field has a value of another dtype.
  let array =
    #|[{"p":[1]}]
  let off_type =
    #|[{"p":{"a":"x","b":"y"}}]
  for misfit in [array, off_type] {
    let strict = Ok(ignore(@io.parse_json_str(misfit, options~))) catch {
      e => Err(e)
    }
    assert_true(strict is Err(@types.DataError::ParseError(_)))
  }
}

///|
test "JSON round-trips nested columns through write_json and read_json" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "l",
      [int_list([1, 2]), @types.Scalar::Null, lv([])],
      dtype=list_dtype(@types.DataType::Int),
    ),
    @series.Series::from_scalars(
      "s",
      [
        sv([fv("a", @types.Scalar::Int(1)), fv("b", @types.Scalar::Bool(true))]),
        @types.Scalar::Null,
        sv([fv("a", @types.Scalar::Null), fv("b", @types.Scalar::Bool(false))]),
      ],
      dtype=struct_dtype(@types.DataType::Int, @types.DataType::Bool),
    ),
    @series.Series::from_ints("n", [1, 2, 3]),
  ])
  let path = "_build/io_json_nested_roundtrip.json"
  @io.write_json(path, df)
  assert_eq(@io.read_json(path), df)
  // The scalar caveats reach into a cell: an all-integral list of Floats
  // reads back as a list of Ints, a list of Dates as a list of their
  // text, and a non-finite Float inside a list as a null element.
  let caveats = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "f",
      [float_list([1.0, 2.0])],
      dtype=list_dtype(@types.DataType::Float),
    ),
    @series.Series::from_scalars(
      "d",
      [lv([@types.Scalar::Date(0L)])],
      dtype=list_dtype(@types.DataType::Date),
    ),
    @series.Series::from_scalars(
      "i",
      [float_list([1.0 / 0.0, 1.5])],
      dtype=list_dtype(@types.DataType::Float),
    ),
  ])
  @io.write_json(path, caveats)
  let back = @io.read_json(path)
  assert_eq(back.get_column("f").dtype(), list_dtype(@types.DataType::Int))
  assert_eq(back.get_column("d").dtype(), list_dtype(@types.DataType::String))
  assert_eq(back.get_column("i").to_scalars().copy(), [
    lv([@types.Scalar::Null, @types.Scalar::Float(1.5)]),
  ])
}

///|
test "NDJSON reads nested columns line by line" {
  let content =
    #|{"x":[1,2],"y":{"k":1}}
    #|{"x":null,"y":null}
    #|{"x":[3],"y":{"k":2}}
  let df = @io.parse_ndjson_str(content)
  assert_eq(df.shape(), (3, 2))
  assert_eq(df.get_column("x").to_scalars().copy(), [
    int_list([1, 2]),
    @types.Scalar::Null,
    int_list([3]),
  ])
  assert_eq(df.get_column("y").to_scalars().copy(), [
    sv([fv("k", @types.Scalar::Int(1))]),
    @types.Scalar::Null,
    sv([fv("k", @types.Scalar::Int(2))]),
  ])
  // A round trip on disk.
  let path = "_build/io_ndjson_nested_roundtrip.ndjson"
  @io.write_ndjson(path, df)
  assert_eq(@io.read_ndjson(path), df)
  // A misfit past the window is located at its file line.
  let late =
    #|{"x":[1]}
    #|{"x":[2]}
    #|{"x":["a"]}
  let strict = Ok(
    ignore(
      @io.parse_ndjson_str(
        late,
        options=@io.JsonReadOptions::JsonReadOptions(infer_schema_rows=2),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    strict
    is Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Line,
          "x",
          3,
          @types.DataType::List(@types.DataType::Int),
          "[\"a\"]",
        ),
      ),
    ),
  )
}

///|
test "a CSV pin to a nested dtype is refused" {
  // A CSV cell is one text field: there is no list or struct in it for
  // the pin to name.
  let refused = Ok(
    ignore(
      @io.parse_csv_str(
        "x\n1\n",
        options=@io.CsvReadOptions::CsvReadOptions(
          dtypes=Map([("x", list_dtype(@types.DataType::Int))]),
        ),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    refused is Err(@types.DataError::InvalidOperation(m)) &&
    m.contains("cannot be pinned to List(Int)") &&
    m.contains("a CSV cell carries no list or struct"),
  )
}
