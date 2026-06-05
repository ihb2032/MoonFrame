// Blackbox tests for `@io.parse_csv_str` / `@io.format_csv_str` plus
// the file-backed `read_csv` / `write_csv` thin wrappers.
//
// The fast path (string ↔ DataFrame) is exercised across header
// modes, custom delimiters, the null mapping, type inference, edge
// shapes (empty, single column, single row), and quoting. The
// file-backed variants round-trip a small frame to make sure the
// `@fs` wiring stays connected.

// ── parse_csv_str: happy paths ────────────────────────────────────────

///|
test "parse_csv_str infers Int / Float / Bool / String in declaration order" {
  let content =
    #|n,r,b,s
    #|1,1.5,true,alpha
    #|2,2.5,false,beta
    #|3,3.5,true,gamma
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 4))
  assert_eq(df.columns(), ["n", "r", "b", "s"])
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("r").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").dtype(), @types.DataType::String)
  assert_eq(df.get(1, "n"), @types.Scalar::Int(2))
  assert_eq(df.get(1, "r"), @types.Scalar::Float(2.5))
  assert_eq(df.get(2, "b"), @types.Scalar::Bool(true))
  assert_eq(df.get(0, "s"), @types.Scalar::String("alpha"))
}

///|
test "parse_csv_str: signed integers (+ / -) infer as Int" {
  // Exercises the sign-aware decimal screen in `parse_int_opt`: a
  // leading + or - is part of a valid base-10 integer literal.
  let content =
    #|n
    #|-5
    #|+7
    #|10
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
  assert_eq(df.get(0, "n"), @types.Scalar::Int(-5))
  assert_eq(df.get(1, "n"), @types.Scalar::Int(7))
  assert_eq(df.get(2, "n"), @types.Scalar::Int(10))
}

///|
test "parse_csv_str: non-decimal numeric forms stay String (no 0x / underscore)" {
  // `@string.parse_int` / `parse_double` accept 0x / 0o / 0b prefixes and
  // underscore grouping under their default rules; CSV inference must
  // not, so columns of hex codes or grouped numbers stay String
  // (matching pandas / polars) instead of being silently retyped.
  let content =
    #|hex,grouped
    #|0xFF,1_000
    #|0x10,2_000
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("hex").dtype(), @types.DataType::String)
  assert_eq(df.get_column("grouped").dtype(), @types.DataType::String)
  assert_eq(df.get(0, "hex"), @types.Scalar::String("0xFF"))
  assert_eq(df.get(1, "grouped"), @types.Scalar::String("2_000"))
}

///|
test "parse_csv_str: decimal integer overflowing Int64 falls back to Float" {
  // A well-formed decimal literal passes the decimal screen but
  // overflows 64-bit `Int64`, so `@string.parse_int64` raises and the
  // cell is rejected as Int; inference then falls through to Float
  // rather than erroring or keeping it as String.
  let content =
    #|big
    #|99999999999999999999
    #|1
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("big").dtype(), @types.DataType::Float)
}

///|
test "parse_csv_str: null values map to None for every inferred dtype" {
  // Empty cells in numeric / bool columns become null without
  // forcing the column down to String — they are skipped by the
  // inference pass and converted to None in the typed builder.
  let content =
    #|i,f,b,s
    #|1,1.5,true,a
    #|,,,
    #|3,3.5,false,c
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 4))
  assert_eq(df.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").dtype(), @types.DataType::String)
  for name in ["i", "f", "b", "s"] {
    assert_eq(df.get(1, name), @types.Scalar::Null)
    assert_eq(df.get_column(name).null_count(), 1)
  }
}

///|
test "parse_csv_str: has_header=false synthesises column1, column2, …" {
  let content =
    #|10,20,30
    #|11,21,31
    #|
  let df = @io.parse_csv_str(content, {
    has_header: false,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: false,
  })
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.columns(), ["column1", "column2", "column3"])
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.get(0, "column1"), @types.Scalar::Int(10))
  assert_eq(df.get(1, "column3"), @types.Scalar::Int(31))
}

///|
test "parse_csv_str: custom delimiter (semicolon) splits cells correctly" {
  let content =
    #|a;b;c
    #|1;2;3
    #|4;5;6
    #|
  let df = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ';',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: false,
  })
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.columns(), ["a", "b", "c"])
  assert_eq(df.get(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.get(1, "c"), @types.Scalar::Int(6))
}

///|
test "parse_csv_str: custom null_values let NA / N/A become null" {
  let content =
    #|a,b
    #|1,x
    #|NA,N/A
    #|3,z
    #|
  let df = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: ["NA", "N/A"],
    strict_column_count: false,
  })
  assert_eq(df.check_invariants(), Ok(()))
  // "a" is Int because NA was skipped during inference; "b" is
  // String because non-null cells "x"/"z" never parse as Int/Float/Bool.
  assert_eq(df.get_column("a").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("b").dtype(), @types.DataType::String)
  assert_eq(df.get(1, "a"), @types.Scalar::Null)
  assert_eq(df.get(1, "b"), @types.Scalar::Null)
}

///|
test "parse_csv_str: Int promotes to Float when later rows mix in 1.5" {
  // The inference pass walks rows in order — once the second row
  // forces Float, the third "2" rendering still parses fine.
  let content =
    #|x
    #|1
    #|1.5
    #|2
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.get(0, "x"), @types.Scalar::Float(1.0))
  assert_eq(df.get(1, "x"), @types.Scalar::Float(1.5))
  assert_eq(df.get(2, "x"), @types.Scalar::Float(2.0))
}

///|
test "parse_csv_str: Bool inference accepts mixed casing (TRUE / False)" {
  let content =
    #|b
    #|TRUE
    #|False
    #|true
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get(0, "b"), @types.Scalar::Bool(true))
  assert_eq(df.get(1, "b"), @types.Scalar::Bool(false))
  assert_eq(df.get(2, "b"), @types.Scalar::Bool(true))
}

///|
test "parse_csv_str: a column with no non-null samples defaults to String" {
  let content =
    #|empty,real
    #|,1
    #|,2
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  // The "empty" column has nothing to disambiguate on, so inference
  // lands on String (and every cell is null because the empty
  // string is in the default null_values).
  assert_eq(df.get_column("empty").dtype(), @types.DataType::String)
  assert_eq(df.get_column("empty").null_count(), 2)
  assert_eq(df.get_column("real").dtype(), @types.DataType::Int)
}

///|
test "parse_csv_str: infer_schema_rows limits the inference window" {
  // First row is "1" (Int); second row is "1.5" (Float). With a
  // window of 1, inference locks Int — and then the Float in row 2
  // is reported as a ParseError, since the dtype was already chosen.
  let content =
    #|x
    #|1
    #|1.5
    #|
  let result = try? @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 1,
    null_values: [""],
    strict_column_count: false,
  })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_csv_str: short data rows pad to null cells" {
  // Row 2 has only 2 cells while the header declares 3. The
  // missing cell falls through to the empty string and is null-
  // mapped, so the column stays Int.
  let content =
    #|a,b,c
    #|1,2,3
    #|4,5
    #|7,8,9
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 3))
  assert_eq(df.get_column("c").dtype(), @types.DataType::Int)
  assert_eq(df.get(1, "c"), @types.Scalar::Null)
}

///|
test "parse_csv_str: strict_column_count rejects a ragged row" {
  // With the strict guard on, a data row whose width differs from the
  // header (row 2 here has 2 cells, not 3) surfaces as ParseError
  // instead of being silently null-padded by the lenient path above.
  let content =
    #|a,b,c
    #|1,2,3
    #|4,5
    #|7,8,9
    #|
  let result = try? @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: true,
  })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_csv_str: strict_column_count passes a uniform-width frame" {
  // Every data row matches the header width, so the strict guard is a
  // no-op and parsing proceeds exactly as the lenient path would.
  let content =
    #|a,b,c
    #|1,2,3
    #|4,5,6
    #|
  let df = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: true,
  })
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.get(1, "c"), @types.Scalar::Int(6))
}

// ── parse_csv_str: edge / error paths ─────────────────────────────────

///|
test "parse_csv_str: empty content yields a 0x0 frame" {
  let df = @io.parse_csv_str("", @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: has_header=false on empty input also yields 0x0" {
  let df = @io.parse_csv_str("", {
    has_header: false,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: false,
  })
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: whitespace-only content collapses to a 0x0 frame" {
  // NyaCSV skips empty lines with the default options, so a single
  // newline parses to zero headers and zero rows; we collapse that
  // to a 0×0 frame via the `ncols == 0` early-return rather than
  // hand `DataFrame::new` an empty schema with synthesised names.
  let df = @io.parse_csv_str("\n", @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: has_header=false on row-less (whitespace) input yields 0x0" {
  // Non-empty content skips the empty-input short-circuit, but NyaCSV
  // reduces "\n" to zero rows; the has_header=false branch then takes the
  // `rows.is_empty()` path and synthesises zero column names → 0×0.
  let df = @io.parse_csv_str("\n", {
    has_header: false,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: false,
  })
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: single column, single row" {
  let df = @io.parse_csv_str("only\n42\n", @io.CsvReadOptions::default())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (1, 1))
  assert_eq(df.get(0, "only"), @types.Scalar::Int(42))
}

///|
test "parse_csv_str: duplicate header is rejected up front" {
  let content =
    #|a,a
    #|1,2
    #|
  assert_eq(
    try? @io.parse_csv_str(content, @io.CsvReadOptions::default()),
    Err(@types.DataError::DuplicateColumn("a")),
  )
}

///|
test "parse_csv_str: non-numeric in a Float-locked column becomes ParseError" {
  // Inference locks Float on the first two rows, then row 3 is
  // "oops" — a value that can't be coerced to Float.
  let content =
    #|x
    #|1.5
    #|2.5
    #|oops
    #|
  let result = try? @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 2,
    null_values: [""],
    strict_column_count: false,
  })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_csv_str: non-bool value outside the inference window is ParseError" {
  // Lock Bool on the first two rows, then a "maybe" in row 3.
  let content =
    #|b
    #|true
    #|false
    #|maybe
    #|
  let result = try? @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 2,
    null_values: [""],
    strict_column_count: false,
  })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "parse_csv_str: non-int outside the inference window is ParseError" {
  let content =
    #|n
    #|1
    #|2
    #|x
    #|
  let result = try? @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 2,
    null_values: [""],
    strict_column_count: false,
  })
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

// ── format_csv_str: happy paths ───────────────────────────────────────

///|
test "format_csv_str: header on, mixed dtypes, null cell becomes empty" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("n", [Some(1), Some(2), None]),
    @frame.Series::from_strings("s", ["a", "b", "c"]),
  ])
  let out = @io.format_csv_str(df, @io.CsvWriteOptions::default())
  let expected =
    #|n,s
    #|1,a
    #|2,b
    #|,c
    #|
  assert_eq(out, expected)
}

///|
test "format_csv_str: header off skips the first row" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2]),
    @frame.Series::from_ints("b", [3, 4]),
  ])
  let out = @io.format_csv_str(df, {
    header: false,
    delimiter: ',',
    null_value: "",
  })
  let expected =
    #|1,3
    #|2,4
    #|
  assert_eq(out, expected)
}

///|
test "format_csv_str: custom delimiter (semicolon)" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2]),
    @frame.Series::from_strings("b", ["x", "y"]),
  ])
  let out = @io.format_csv_str(df, {
    header: true,
    delimiter: ';',
    null_value: "",
  })
  let expected =
    #|a;b
    #|1;x
    #|2;y
    #|
  assert_eq(out, expected)
}

///|
test "format_csv_str: custom null_value rendering" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("n", [Some(1), None, Some(3)]),
  ])
  let out = @io.format_csv_str(df, {
    header: true,
    delimiter: ',',
    null_value: "NA",
  })
  let expected =
    #|n
    #|1
    #|NA
    #|3
    #|
  assert_eq(out, expected)
}

///|
test "format_csv_str: quotes cells with delimiter, quote, newline, or CR" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_strings("a", [
      "needs,comma", "needs\"quote", "needs\nlf", "needs\rcr",
    ]),
  ])
  let out = @io.format_csv_str(df, @io.CsvWriteOptions::default())
  // Every body cell is quoted; the embedded double quote in row 2
  // is doubled per RFC 4180.
  let expected = "a\n\"needs,comma\"\n\"needs\"\"quote\"\n\"needs\nlf\"\n\"needs\rcr\"\n"
  assert_eq(out, expected)
}

///|
test "format_csv_str: also quotes header names that contain the delimiter" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("hello,world", [1, 2]),
  ])
  let out = @io.format_csv_str(df, @io.CsvWriteOptions::default())
  let expected =
    #|"hello,world"
    #|1
    #|2
    #|
  assert_eq(out, expected)
}

///|
test "format_csv_str: empty frame produces just the header row (or nothing)" {
  // 0 columns, 0 rows: nothing to emit even with header on.
  let empty = @frame.DataFrame::new([])
  let out = @io.format_csv_str(empty, @io.CsvWriteOptions::default())
  assert_eq(out, "\n")
  // header off + empty frame: still emits one blank record terminator
  // (no cells, only the trailing newline from the header branch).
  let out_no_header = @io.format_csv_str(empty, {
    header: false,
    delimiter: ',',
    null_value: "",
  })
  assert_eq(out_no_header, "")
}

///|
test "format_csv_str: 0 rows with declared schema emits header only" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::String),
  ])
  let df = @frame.DataFrame::empty(schema)
  let out = @io.format_csv_str(df, @io.CsvWriteOptions::default())
  let expected =
    #|a,b
    #|
  assert_eq(out, expected)
}

// ── round trip via parse_csv_str / format_csv_str ─────────────────────

///|
test "parse_csv_str ∘ format_csv_str: round-trip preserves dtypes and values" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("n", [Some(1), None, Some(3)]),
    @frame.Series::from_floats("r", [
      (1.5 : Double),
      (2.5 : Double),
      (3.5 : Double),
    ]),
    @frame.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @frame.Series::from_strings("s", ["alpha", "beta", "gamma"]),
  ])
  let text = @io.format_csv_str(df, @io.CsvWriteOptions::default())
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions::default())
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), df.shape())
  assert_eq(parsed.columns(), df.columns())
  for name in df.columns() {
    assert_eq(parsed.get_column(name).dtype(), df.get_column(name).dtype())
    for i in 0..<df.nrows() {
      assert_eq(parsed.get(i, name), df.get(i, name))
    }
  }
}

// ── read_csv / write_csv: file-system path ────────────────────────────

///|
test "write_csv then read_csv round-trips a small frame on disk" {
  let path = "_build/io_csv_test_roundtrip.csv"
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("n", [1, 2, 3]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ])
  @io.write_csv(path, df)
  let parsed = @io.read_csv(path)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.get(2, "n"), @types.Scalar::Int(3))
  assert_eq(parsed.get(0, "s"), @types.Scalar::String("x"))
}

///|
test "write_csv_with_options + read_csv_with_options honour custom shape" {
  let path = "_build/io_csv_test_custom.csv"
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None]),
    @frame.Series::from_strings("b", ["p", "q"]),
  ])
  let write_opts : @io.CsvWriteOptions = {
    header: true,
    delimiter: ';',
    null_value: "NA",
  }
  let read_opts : @io.CsvReadOptions = {
    has_header: true,
    delimiter: ';',
    infer_schema_rows: 100,
    null_values: ["NA"],
    strict_column_count: false,
  }
  @io.write_csv_with_options(path, df, write_opts)
  let parsed = @io.read_csv_with_options(path, read_opts)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.get(0, "a"), @types.Scalar::Int(1))
  assert_eq(parsed.get(1, "a"), @types.Scalar::Null)
  assert_eq(parsed.get(0, "b"), @types.Scalar::String("p"))
}

///|
test "read_csv: missing file surfaces as IoError, not panic" {
  let result = try? @io.read_csv("_build/io_csv_test_does_not_exist.csv")
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "read_csv_with_options: missing file surfaces as IoError" {
  let result = try? @io.read_csv_with_options(
    "_build/io_csv_test_does_not_exist.csv",
    @io.CsvReadOptions::default(),
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_csv: invalid path surfaces as IoError" {
  // Write into a directory that does not exist. The native fs
  // backend rejects the open call with an IOError; we promote it
  // to the DataError variant.
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [1])])
  let result = try? @io.write_csv("_build/no_such_dir_io_test/file.csv", df)
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_csv_with_options: invalid path surfaces as IoError" {
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [1])])
  let result = try? @io.write_csv_with_options(
    "_build/no_such_dir_io_test_2/file.csv",
    df,
    @io.CsvWriteOptions::default(),
  )
  assert_true(result is Err(@types.DataError::IoError(_)))
}

// ── CsvReadOptions / CsvWriteOptions defaults ─────────────────────────

///|
test "CsvReadOptions::default exposes expected defaults" {
  let opts = @io.CsvReadOptions::default()
  assert_eq(opts.has_header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.infer_schema_rows, 100)
  assert_eq(opts.null_values, [""])
  assert_eq(opts.strict_column_count, false)
}

///|
test "CsvWriteOptions::default exposes expected defaults" {
  let opts = @io.CsvWriteOptions::default()
  assert_eq(opts.header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.null_value, "")
}
