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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 4))
  assert_eq(df.columns(), ["n", "r", "b", "s"])
  assert_eq(df.get_column("n").unwrap().dtype(), @types.DataType::Int)
  assert_eq(df.get_column("r").unwrap().dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").unwrap().dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").unwrap().dtype(), @types.DataType::String)
  assert_eq(df.get(1, "n"), Ok(@types.Scalar::Int(2)))
  assert_eq(df.get(1, "r"), Ok(@types.Scalar::Float(2.5)))
  assert_eq(df.get(2, "b"), Ok(@types.Scalar::Bool(true)))
  assert_eq(df.get(0, "s"), Ok(@types.Scalar::String("alpha")))
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 4))
  assert_eq(df.get_column("i").unwrap().dtype(), @types.DataType::Int)
  assert_eq(df.get_column("f").unwrap().dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").unwrap().dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").unwrap().dtype(), @types.DataType::String)
  for name in ["i", "f", "b", "s"] {
    assert_eq(df.get(1, name), Ok(@types.Scalar::Null))
    assert_eq(df.get_column(name).unwrap().null_count(), 1)
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
  }).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.columns(), ["column1", "column2", "column3"])
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.get(0, "column1"), Ok(@types.Scalar::Int(10)))
  assert_eq(df.get(1, "column3"), Ok(@types.Scalar::Int(31)))
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
  }).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.columns(), ["a", "b", "c"])
  assert_eq(df.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(df.get(1, "c"), Ok(@types.Scalar::Int(6)))
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
  }).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  // "a" is Int because NA was skipped during inference; "b" is
  // String because non-null cells "x"/"z" never parse as Int/Float/Bool.
  assert_eq(df.get_column("a").unwrap().dtype(), @types.DataType::Int)
  assert_eq(df.get_column("b").unwrap().dtype(), @types.DataType::String)
  assert_eq(df.get(1, "a"), Ok(@types.Scalar::Null))
  assert_eq(df.get(1, "b"), Ok(@types.Scalar::Null))
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("x").unwrap().dtype(), @types.DataType::Float)
  assert_eq(df.get(0, "x"), Ok(@types.Scalar::Float(1.0)))
  assert_eq(df.get(1, "x"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(df.get(2, "x"), Ok(@types.Scalar::Float(2.0)))
}

///|
test "parse_csv_str: Bool inference accepts mixed casing (TRUE / False)" {
  let content =
    #|b
    #|TRUE
    #|False
    #|true
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("b").unwrap().dtype(), @types.DataType::Bool)
  assert_eq(df.get(0, "b"), Ok(@types.Scalar::Bool(true)))
  assert_eq(df.get(1, "b"), Ok(@types.Scalar::Bool(false)))
  assert_eq(df.get(2, "b"), Ok(@types.Scalar::Bool(true)))
}

///|
test "parse_csv_str: a column with no non-null samples defaults to String" {
  let content =
    #|empty,real
    #|,1
    #|,2
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  // The "empty" column has nothing to disambiguate on, so inference
  // lands on String (and every cell is null because the empty
  // string is in the default null_values).
  assert_eq(df.get_column("empty").unwrap().dtype(), @types.DataType::String)
  assert_eq(df.get_column("empty").unwrap().null_count(), 2)
  assert_eq(df.get_column("real").unwrap().dtype(), @types.DataType::Int)
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
  let result = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 1,
    null_values: [""],
  })
  match result {
    Err(@types.DataError::ParseError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 3))
  assert_eq(df.get_column("c").unwrap().dtype(), @types.DataType::Int)
  assert_eq(df.get(1, "c"), Ok(@types.Scalar::Null))
}

// ── parse_csv_str: edge / error paths ─────────────────────────────────

///|
test "parse_csv_str: empty content yields a 0x0 frame" {
  let df = @io.parse_csv_str("", @io.CsvReadOptions::default()).unwrap()
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
  }).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: whitespace-only content collapses to a 0x0 frame" {
  // NyaCSV skips empty lines with the default options, so a single
  // newline parses to zero headers and zero rows; we collapse that
  // to a 0×0 frame via the `ncols == 0` early-return rather than
  // hand `DataFrame::new` an empty schema with synthesised names.
  let df = @io.parse_csv_str("\n", @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: single column, single row" {
  let df = @io.parse_csv_str("only\n42\n", @io.CsvReadOptions::default()).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (1, 1))
  assert_eq(df.get(0, "only"), Ok(@types.Scalar::Int(42)))
}

///|
test "parse_csv_str: duplicate header is rejected up front" {
  let content =
    #|a,a
    #|1,2
    #|
  let result = @io.parse_csv_str(content, @io.CsvReadOptions::default())
  assert_eq(result, Err(@types.DataError::DuplicateColumn("a")))
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
  let result = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 2,
    null_values: [""],
  })
  match result {
    Err(@types.DataError::ParseError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
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
  let result = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 2,
    null_values: [""],
  })
  match result {
    Err(@types.DataError::ParseError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
}

///|
test "parse_csv_str: non-int outside the inference window is ParseError" {
  let content =
    #|n
    #|1
    #|2
    #|x
    #|
  let result = @io.parse_csv_str(content, {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 2,
    null_values: [""],
  })
  match result {
    Err(@types.DataError::ParseError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
}

// ── format_csv_str: happy paths ───────────────────────────────────────

///|
test "format_csv_str: header on, mixed dtypes, null cell becomes empty" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("n", [Some(1), Some(2), None]),
    @frame.Series::from_strings("s", ["a", "b", "c"]),
  ]).unwrap()
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
  ]).unwrap()
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
  ]).unwrap()
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
  ]).unwrap()
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
  ]).unwrap()
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
  ]).unwrap()
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
  let empty = @frame.DataFrame::new([]).unwrap()
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
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
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
      (1.5 : Float),
      (2.5 : Float),
      (3.5 : Float),
    ]),
    @frame.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @frame.Series::from_strings("s", ["alpha", "beta", "gamma"]),
  ]).unwrap()
  let text = @io.format_csv_str(df, @io.CsvWriteOptions::default())
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions::default()).unwrap()
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), df.shape())
  assert_eq(parsed.columns(), df.columns())
  for name in df.columns() {
    assert_eq(
      parsed.get_column(name).unwrap().dtype(),
      df.get_column(name).unwrap().dtype(),
    )
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
  ]).unwrap()
  assert_eq(@io.write_csv(path, df), Ok(()))
  let parsed = @io.read_csv(path).unwrap()
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.get(2, "n"), Ok(@types.Scalar::Int(3)))
  assert_eq(parsed.get(0, "s"), Ok(@types.Scalar::String("x")))
}

///|
test "write_csv_with_options + read_csv_with_options honour custom shape" {
  let path = "_build/io_csv_test_custom.csv"
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None]),
    @frame.Series::from_strings("b", ["p", "q"]),
  ]).unwrap()
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
  }
  assert_eq(@io.write_csv_with_options(path, df, write_opts), Ok(()))
  let parsed = @io.read_csv_with_options(path, read_opts).unwrap()
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(parsed.get(1, "a"), Ok(@types.Scalar::Null))
  assert_eq(parsed.get(0, "b"), Ok(@types.Scalar::String("p")))
}

///|
test "read_csv: missing file surfaces as IoError, not panic" {
  let result = @io.read_csv("_build/io_csv_test_does_not_exist.csv")
  match result {
    Err(@types.DataError::IoError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
}

///|
test "read_csv_with_options: missing file surfaces as IoError" {
  let result = @io.read_csv_with_options(
    "_build/io_csv_test_does_not_exist.csv",
    @io.CsvReadOptions::default(),
  )
  match result {
    Err(@types.DataError::IoError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
}

///|
test "write_csv: invalid path surfaces as IoError" {
  // Write into a directory that does not exist. The native fs
  // backend rejects the open call with an IOError; we promote it
  // to the DataError variant.
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [1])]).unwrap()
  let result = @io.write_csv("_build/no_such_dir_io_test/file.csv", df)
  match result {
    Err(@types.DataError::IoError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
}

///|
test "write_csv_with_options: invalid path surfaces as IoError" {
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [1])]).unwrap()
  let result = @io.write_csv_with_options(
    "_build/no_such_dir_io_test_2/file.csv",
    df,
    @io.CsvWriteOptions::default(),
  )
  match result {
    Err(@types.DataError::IoError(_)) => ()
    other => {
      let _ = other
      assert_eq(true, false)
    }
  }
}

// ── CsvReadOptions / CsvWriteOptions defaults ─────────────────────────

///|
test "CsvReadOptions::default exposes expected defaults" {
  let opts = @io.CsvReadOptions::default()
  assert_eq(opts.has_header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.infer_schema_rows, 100)
  assert_eq(opts.null_values, [""])
}

///|
test "CsvWriteOptions::default exposes expected defaults" {
  let opts = @io.CsvWriteOptions::default()
  assert_eq(opts.header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.null_value, "")
}
