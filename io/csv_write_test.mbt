// Blackbox tests for `@io.format_csv` / `@io.write_csv` — the write half
// of the CSV interchange, mirroring `csv_write.mbt` against the read half
// in `csv_test.mbt`. Covers the option surface (delimiter, null_value,
// formula sanitisation, header mode), the quoting rules, the write-side
// refusals (column-less frames, unsafe delimiters, unpaired surrogates),
// and the read-back round-trips that pin reader / writer agreement on
// the wire format.

///|
test "format_csv: a delimiter colliding with the quote or a line terminator is rejected" {
  let df = @frame.DataFrame::DataFrame([@series.Series::from_ints("a", [1, 2])])
  for d in ['"', '\n', '\r'] {
    let options : @io.CsvWriteOptions = @io.CsvWriteOptions::CsvWriteOptions(
      delimiter=d,
    )
    let result = Ok(@io.format_csv(df, options~)) catch { e => Err(e) }
    assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  }
}

///|
test "format_csv: header on, mixed dtypes, null cell becomes empty" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [Some(1), Some(2), None]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  let out = @io.format_csv(df)
  let expected =
    #|n,s
    #|1,a
    #|2,b
    #|,c
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: header off skips the first row" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", [1, 2]),
    @series.Series::from_ints("b", [3, 4]),
  ])
  let out = @io.format_csv(
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(header=false),
  )
  let expected =
    #|1,3
    #|2,4
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: custom delimiter (semicolon)" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", [1, 2]),
    @series.Series::from_strings("b", ["x", "y"]),
  ])
  let out = @io.format_csv(
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(delimiter=';'),
  )
  let expected =
    #|a;b
    #|1;x
    #|2;y
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: custom null_value rendering" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
  ])
  let out = @io.format_csv(
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(null_value="NA"),
  )
  let expected =
    #|n
    #|1
    #|NA
    #|3
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: formula sanitization covers spreadsheet trigger prefixes" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("s", [
      "=SUM(A1)", "+1", "-1", "@name", "\t=1", "\r=1", "",
    ]),
  ])
  let out = @io.format_csv(
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(sanitize_formulas=true),
  )
  assert_eq(out, "s\n'=SUM(A1)\n'+1\n'-1\n'@name\n'\t=1\n\"'\r=1\"\n\"\"\n")
}

///|
test "format_csv: formula sanitization changes only formula-like String cells" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_string_options("s", [Some("-1"), None, Some("a,b")]),
    @series.Series::from_ints("i", [-1, 2, 3]),
    @series.Series::from_floats("f", [-1.5, 2.5, 3.5]),
    @series.Series::from_bools("b", [true, false, true]),
  ])
  let out = @io.format_csv(
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(sanitize_formulas=true),
  )
  assert_eq(
    out, "s,i,f,b\n'-1,-1,-1.5,true\n,2,2.5,false\n\"a,b\",3,3.5,true\n",
  )
}

///|
test "format_csv: formula sanitization is opt-in and false is byte-identical" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("s", ["=SUM(A1)", "ordinary"]),
  ])
  let default_out = @io.format_csv(df)
  let explicit_false = @io.format_csv(
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(sanitize_formulas=false),
  )
  assert_eq(default_out, "s\n=SUM(A1)\nordinary\n")
  assert_eq(explicit_false, default_out)
}

///|
test "format_csv: quotes cells with delimiter, quote, newline, or CR" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("a", [
      "needs,comma", "needs\"quote", "needs\nlf", "needs\rcr",
    ]),
  ])
  let out = @io.format_csv(df)
  // Every body cell is quoted; the embedded double quote in row 2
  // is doubled per RFC 4180.
  let expected = "a\n\"needs,comma\"\n\"needs\"\"quote\"\n\"needs\nlf\"\n\"needs\rcr\"\n"
  assert_eq(out, expected)
}

///|
test "format_csv: also quotes header names that contain the delimiter" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("hello,world", [1, 2]),
  ])
  let out = @io.format_csv(df)
  let expected =
    #|"hello,world"
    #|1
    #|2
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: empty frame produces just the header row (or nothing)" {
  // 0 columns, 0 rows: nothing to emit even with header on. This is the shape
  // the column-less refusal below deliberately still writes — there are no rows
  // to lose, and both spellings read back as the same `0×0` frame.
  let empty = @frame.DataFrame::DataFrame([])
  let out = @io.format_csv(empty)
  assert_eq(out, "\n")
  assert_eq(@io.parse_csv_str(out).shape(), (0, 0))
  // header off + empty frame: still emits one blank record terminator
  // (no cells, only the trailing newline from the header branch).
  let out_no_header = @io.format_csv(
    empty,
    options=@io.CsvWriteOptions::CsvWriteOptions(header=false),
  )
  assert_eq(out_no_header, "")
}

///|
test "format_csv: a frame with rows but no columns is refused, not blanked out" {
  // `N×0` has no CSV spelling: a row with no fields is an empty line, and the
  // reader skips empty lines. Written, a `2×0` frame would be three blank lines
  // (header + two rows) and read back as `0×0` — both rows gone, no error.
  // Neither header setting can encode the shape, so both refuse.
  let nby0 = @frame.DataFrame::from_rows(@types.Schema::Schema([]), [[], []])
  assert_eq(nby0.shape(), (2, 0))
  let with_header = Ok(@io.format_csv(nby0)) catch { e => Err(e) }
  assert_true(with_header is Err(@types.DataError::InvalidOperation(_)))
  let without_header = Ok(
    @io.format_csv(
      nby0,
      options=@io.CsvWriteOptions::CsvWriteOptions(header=false),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(without_header is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "write_csv: the column-less refusal fires before the file is created" {
  let path = "_build/io_csv_rows_without_columns.csv"
  let nby0 = @frame.DataFrame::from_rows(@types.Schema::Schema([]), [[], [], []])
  let result = Ok(@io.write_csv(path, nby0)) catch { e => Err(e) }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  // `format_csv` runs first, so the refusal costs no half-written file.
  assert_false(@fs.path_exists(path))
}

///|
test "format_csv: 0 rows with declared schema emits header only" {
  let schema = @types.Schema::Schema([
    @types.Field::Field("a", @types.DataType::Int),
    @types.Field::Field("b", @types.DataType::String),
  ])
  let df = @frame.DataFrame::empty(schema)
  let out = @io.format_csv(df)
  let expected =
    #|a,b
    #|
  assert_eq(out, expected)
}

///|
test "parse_csv_str ∘ format_csv: round-trip preserves dtypes and values" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
    @series.Series::from_floats("r", [
      (1.5 : Double),
      (2.5 : Double),
      (3.5 : Double),
    ]),
    @series.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @series.Series::from_strings("s", ["alpha", "beta", "gamma"]),
  ])
  let text = @io.format_csv(df)
  let parsed = @io.parse_csv_str(text)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), df.shape())
  assert_eq(parsed.columns(), df.columns())
  for name in df.columns() {
    assert_eq(parsed.get_column(name).dtype(), df.get_column(name).dtype())
    for i in 0..<df.nrows() {
      assert_eq(parsed.item(i, name), df.item(i, name))
    }
  }
}

///|
test "round-trip: a single-column null row survives (no blank-line drop)" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
  ])
  let text = @io.format_csv(df)
  // The null row is emitted as a quoted empty, not a bare blank line the
  // reader's `skip_empty_lines` would discard.
  assert_eq(text, "n\n1\n\"\"\n3\n")
  let parsed = @io.parse_csv_str(text)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 1))
  assert_eq(parsed.get_column("n").dtype(), df.get_column("n").dtype())
  for i in 0..<3 {
    assert_eq(parsed.item(i, "n"), df.item(i, "n"))
  }
}

///|
test "round-trip: an all-null single column keeps every row" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("n", [None, None, None]),
  ])
  let text = @io.format_csv(df)
  assert_eq(text, "n\n\"\"\n\"\"\n\"\"\n")
  let parsed = @io.parse_csv_str(text)
  assert_eq(parsed.check_invariants(), Ok(()))
  // All rows preserved (previously collapsed to 0). An all-null column has
  // no probe to infer a type from, so it round-trips as String nulls.
  assert_eq(parsed.shape(), (3, 1))
  for i in 0..<3 {
    assert_eq(parsed.item(i, "n"), df.item(i, "n"))
  }
}

///|
test "round-trip: a single column named \"\" keeps its name and rows" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("", [10, 20, 30]),
  ])
  let text = @io.format_csv(df)
  // The empty header is written as `""`, so the first data row is not lifted
  // into the header and the column name is not lost.
  assert_eq(text, "\"\"\n10\n20\n30\n")
  let parsed = @io.parse_csv_str(text)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 1))
  assert_eq(parsed.columns(), [""])
  for i in 0..<3 {
    assert_eq(parsed.item(i, ""), df.item(i, ""))
  }
}

///|
test "format_csv: a wider frame's empty cells stay bare (single-column-only quoting)" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("a", [Some(1), None]),
    @series.Series::from_int_options("b", [None, Some(2)]),
  ])
  let out = @io.format_csv(df)
  // Two columns: every row carries the delimiter, so an empty cell is never
  // row-emptying and is left bare — the `""` forcing is single-column only.
  assert_eq(out, "a,b\n1,\n,2\n")
}

///|
test "parse_csv_str ∘ format_csv: round-trips quoted delimiters, quotes, and newlines" {
  // The highest-risk RFC-4180 feature: a String cell holding the
  // delimiter, an embedded double quote, or a line break must survive a
  // write→read round trip — the writer quotes/escapes it, and the reader
  // (NyaCSV with newlines-in-quotes) reassembles the multi-line record.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("text", [
      "needs,comma", "has \"quote\"", "two\nlines",
    ]),
    @series.Series::from_ints("n", [1, 2, 3]),
  ])
  let text = @io.format_csv(df)
  let parsed = @io.parse_csv_str(text)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.item(0, "text"), @types.Scalar::String("needs,comma"))
  assert_eq(parsed.item(1, "text"), @types.Scalar::String("has \"quote\""))
  assert_eq(parsed.item(2, "text"), @types.Scalar::String("two\nlines"))
  assert_eq(parsed.item(2, "n"), @types.Scalar::Int(3))
}

///|
test "write_csv then read_csv round-trips a small frame on disk" {
  let path = "_build/io_csv_test_roundtrip.csv"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("n", [1, 2, 3]),
    @series.Series::from_strings("s", ["x", "y", "z"]),
  ])
  @io.write_csv(path, df)
  let parsed = @io.read_csv(path)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.columns(), ["n", "s"])
  assert_eq(parsed.item(2, "n"), @types.Scalar::Int(3))
  assert_eq(parsed.item(0, "s"), @types.Scalar::String("x"))
}

///|
test "write_csv refuses a cell holding an unpaired surrogate" {
  // A lone surrogate can sit in a cell, but the UTF-8
  // file encoder would merge it with the *following* code unit — here the
  // delimiter after column `a` — silently shifting every later cell
  // boundary. The write is refused up front instead, matching
  // `validate_csv_delimiter`'s reject-rather-than-corrupt philosophy.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("a", [lone_surrogate_str(0xD800)]),
    @series.Series::from_ints("b", [1]),
  ])
  let w = Ok(@io.write_csv("_build/io_csv_surrogate_reject.csv", df)) catch {
    e => Err(e)
  }
  assert_true(w is Err(@types.DataError::InvalidOperation(_)))
  // A bare *low* surrogate (not preceded by a high one) is just as
  // ill-formed and is refused by the same guard.
  let df_low = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("a", [lone_surrogate_str(0xDC00)]),
  ])
  let w_low = Ok(@io.write_csv("_build/io_csv_surrogate_reject.csv", df_low)) catch {
    e => Err(e)
  }
  assert_true(w_low is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "U+FEFF is rejected as a CSV delimiter" {
  // Every read strips a leading U+FEFF as a byte-order mark before
  // tokenizing, so a U+FEFF delimiter whose first field is empty loses its
  // leading delimiter on read-back and every cell shifts left — rejected
  // like the quote/terminator/non-BMP collisions.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("a", ["x"]),
  ])
  let opts : @io.CsvWriteOptions = @io.CsvWriteOptions::CsvWriteOptions(
    delimiter='\u{FEFF}',
  )
  assert_true(
    (Ok(@io.format_csv(df, options=opts)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "write_csv still writes well-formed surrogate pairs" {
  // The guard only rejects *unpaired* surrogates: a supplementary-plane
  // character stored as a proper pair round-trips unharmed.
  let path = "_build/io_csv_surrogate_pair_ok.csv"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("s", ["𝄞clef"]),
  ])
  @io.write_csv(path, df)
  assert_eq(@io.read_csv(path), df)
}

///|
test "write_csv + read_csv honour a custom options shape" {
  let path = "_build/io_csv_test_custom.csv"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("a", [Some(1), None]),
    @series.Series::from_strings("b", ["p", "q"]),
  ])
  let write_opts : @io.CsvWriteOptions = @io.CsvWriteOptions::CsvWriteOptions(
    delimiter=';',
    null_value="NA",
  )
  let read_opts : @io.CsvReadOptions = @io.CsvReadOptions::CsvReadOptions(
    delimiter=';',
    null_values=["NA"],
  )
  @io.write_csv(path, df, options=write_opts)
  let parsed = @io.read_csv(path, options=read_opts)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(parsed.item(1, "a"), @types.Scalar::Null)
  assert_eq(parsed.item(0, "b"), @types.Scalar::String("p"))
}

///|
test "write_csv forwards formula sanitization from its options" {
  let path = "_build/io_csv_formula_sanitized.csv"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("s", ["=SUM(A1)"]),
  ])
  @io.write_csv(
    path,
    df,
    options=@io.CsvWriteOptions::CsvWriteOptions(sanitize_formulas=true),
  )
  let parsed = @io.read_csv(path)
  assert_eq(parsed.item(0, "s"), @types.Scalar::String("'=SUM(A1)"))
}

///|
test "write_csv: invalid path surfaces as IoError" {
  // Write into a directory that does not exist. The native fs
  // backend rejects the open call with an IOError; we promote it
  // to the DataError variant.
  let df = @frame.DataFrame::DataFrame([@series.Series::from_ints("a", [1])])
  let result = Ok(@io.write_csv("_build/no_such_dir_io_test/file.csv", df)) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_csv with options: invalid path surfaces as IoError" {
  let df = @frame.DataFrame::DataFrame([@series.Series::from_ints("a", [1])])
  let result = Ok(
    @io.write_csv(
      "_build/no_such_dir_io_test_2/file.csv",
      df,
      options=@io.CsvWriteOptions::CsvWriteOptions(
        header=false,
        null_value="NA",
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "CsvWriteOptions defaults every field" {
  let opts = @io.CsvWriteOptions::CsvWriteOptions()
  assert_eq(opts.header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.null_value, "")
  assert_eq(opts.sanitize_formulas, false)
}
