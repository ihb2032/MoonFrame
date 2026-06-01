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
    @frame.Series::from_ints("n", [1, 2, 3]),
    @frame.Series::from_strings("s", ["a", "b", "c"]),
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
    @frame.Series::from_int_options("n", [Some(1), None]),
    @frame.Series::from_string_options("s", [None, Some("x")]),
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
    @frame.Series::from_strings("s", ["a\"b\\c\nd\te"]),
  ])
  assert_eq(@io.format_json_records(df), "[{\"s\":\"a\\\"b\\\\c\\nd\\te\"}]")
}

///|
test "format_json_records: zero-row frame emits an empty array" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)])
  let df = @frame.DataFrame::empty(schema)
  assert_eq(@io.format_json_records(df), "[]")
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
  assert_eq(df.get(0, "i"), @types.Scalar::Int(1))
  assert_eq(df.get(0, "f"), @types.Scalar::Float(1.5))
  assert_eq(df.get(0, "b"), @types.Scalar::Bool(true))
  assert_eq(df.get(0, "s"), @types.Scalar::String("hello"))
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
    assert_eq(df.get(1, name), @types.Scalar::Null)
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
  assert_eq(df.get(0, "n"), @types.Scalar::Float(1.0))
  assert_eq(df.get(1, "n"), @types.Scalar::Float(2.5))
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
test "parse_json_records_str: missing fields become nulls" {
  // The second record lacks `b`; the column-collection pass keeps
  // both columns and the builder slots in a null for the missing
  // field.
  let content = "[{\"a\":1,\"b\":2},{\"a\":3}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.shape(), (2, 2))
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.get(1, "b"), @types.Scalar::Null)
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
  assert_eq(df.get(0, "b"), @types.Scalar::Null)
  assert_eq(df.get(1, "a"), @types.Scalar::Null)
}

///|
test "parse_json_records_str: mixed-dtype column falls back to String" {
  // `1` is an Int candidate, `"two"` is a String candidate — no
  // single dtype accepts both, so the inference order ends at the
  // String fallback and numeric cells are restringified.
  let content = "[{\"x\":1},{\"x\":\"two\"},{\"x\":3}]"
  let df = @io.parse_json_records_str(content, @io.JsonReadOptions::default())
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.get(0, "x"), @types.Scalar::String("1"))
  assert_eq(df.get(1, "x"), @types.Scalar::String("two"))
  assert_eq(df.get(2, "x"), @types.Scalar::String("3"))
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
test "parse_json_records_str: non-array top-level returns ParseError" {
  let result = try? @io.parse_json_records_str(
    "{\"a\":1}",
    @io.JsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: non-object record returns ParseError" {
  let result = try? @io.parse_json_records_str(
    "[1,2,3]",
    @io.JsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: malformed JSON returns ParseError" {
  let result = try? @io.parse_json_records_str(
    "[{",
    @io.JsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: typed mismatch past inference window errors" {
  // First two records lock the dtype on Int; the third sneaks in a
  // string. The builder rejects the unparseable cell with
  // ParseError rather than silently widening the column.
  let content = "[{\"x\":1},{\"x\":2},{\"x\":\"three\"}]"
  let result = try? @io.parse_json_records_str(content, { infer_schema_rows: 2 })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: Float column with non-number past inference errors" {
  // Inference locks Float on the first two records; the third
  // sneaks a string in, which `json_value_as_float` rejects.
  let content = "[{\"x\":1.5},{\"x\":2.5},{\"x\":\"oops\"}]"
  let result = try? @io.parse_json_records_str(content, { infer_schema_rows: 2 })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_json_records_str: Bool column with non-bool past inference errors" {
  // Locks Bool on the first two records, then rejects the numeric
  // cell — `json_value_as_bool` refuses `Number(1)` per the same
  // convention `parse_csv_str` uses for `parse_bool_opt`.
  let content = "[{\"x\":true},{\"x\":false},{\"x\":1}]"
  let result = try? @io.parse_json_records_str(content, { infer_schema_rows: 2 })
  assert_true(result is Err(@types.DataError::ParseError(_)))
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
  assert_eq(df.get(0, "x"), @types.Scalar::String("true"))
  assert_eq(df.get(1, "x"), @types.Scalar::String("false"))
  assert_eq(df.get(2, "x"), @types.Scalar::String("1"))
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
  assert_eq(df.get(0, "x"), @types.Scalar::String("[1,2,3]"))
  assert_eq(df.get(1, "x"), @types.Scalar::String("{\"k\":1}"))
}

// ── read_json / write_json_records: file-system path ────────────────

///|
test "write_json_records then read_json round-trips a small frame on disk" {
  let path = "_build/io_json_test_roundtrip.json"
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("n", [1, 2, 3]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ])
  @io.write_json_records(path, df)
  let parsed = @io.read_json(path)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.get(2, "n"), @types.Scalar::Int(3))
  assert_eq(parsed.get(0, "s"), @types.Scalar::String("x"))
}

///|
test "read_json_with_options honours a custom inference window" {
  let path = "_build/io_json_test_custom.json"
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), Some(2), Some(3)]),
  ])
  @io.write_json_records(path, df)
  let parsed = @io.read_json_with_options(path, { infer_schema_rows: 1 })
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.get_column("a").dtype(), @types.DataType::Int)
}

///|
test "read_json: missing file surfaces as IoError, not panic" {
  let result = try? @io.read_json("_build/io_json_test_does_not_exist.json")
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "read_json_with_options: missing file surfaces as IoError" {
  let result = try? @io.read_json_with_options(
    "_build/io_json_test_does_not_exist.json",
    @io.JsonReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_json_records: invalid path surfaces as IoError" {
  // Same shape as the CSV writer error test: aim the writer at a
  // directory that doesn't exist so the underlying `@fs` call
  // surfaces `IOError`, which we promote to `DataError::IoError`.
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [1])])
  let result = try? @io.write_json_records(
    "_build/no_such_dir_io_json_test/file.json", df,
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

// ── round-trip ──────────────────────────────────────────────────────

///|
test "format_json_records / parse_json_records_str round-trip preserves data" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("n", [Some(1), None, Some(3)]),
    @frame.Series::from_floats("r", [
      (1.5 : Double),
      (2.5 : Double),
      (3.5 : Double),
    ]),
    @frame.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @frame.Series::from_strings("s", ["a", "b", "c"]),
  ])
  let json = @io.format_json_records(df)
  let df2 = @io.parse_json_records_str(json, @io.JsonReadOptions::default())
  assert_eq(df, df2)
}
