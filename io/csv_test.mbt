// Blackbox tests for `@io.parse_csv_str` / `@io.format_csv` plus
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 4))
  assert_eq(df.columns(), ["n", "r", "b", "s"])
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("r").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").dtype(), @types.DataType::String)
  assert_eq(df.item(1, "n"), @types.Scalar::Int(2))
  assert_eq(df.item(1, "r"), @types.Scalar::Float(2.5))
  assert_eq(df.item(2, "b"), @types.Scalar::Bool(true))
  assert_eq(df.item(0, "s"), @types.Scalar::String("alpha"))
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
  assert_eq(df.item(0, "n"), @types.Scalar::Int(-5))
  assert_eq(df.item(1, "n"), @types.Scalar::Int(7))
  assert_eq(df.item(2, "n"), @types.Scalar::Int(10))
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("hex").dtype(), @types.DataType::String)
  assert_eq(df.get_column("grouped").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "hex"), @types.Scalar::String("0xFF"))
  assert_eq(df.item(1, "grouped"), @types.Scalar::String("2_000"))
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 4))
  assert_eq(df.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").dtype(), @types.DataType::String)
  for name in ["i", "f", "b", "s"] {
    assert_eq(df.item(1, name), @types.Scalar::Null)
    assert_eq(df.get_column(name).null_count(), 1)
  }
}

///|
test "parse_csv_str: has_header=false synthesises column1, column2, …" {
  let content =
    #|10,20,30
    #|11,21,31
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions(has_header=false))
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.columns(), ["column1", "column2", "column3"])
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.item(0, "column1"), @types.Scalar::Int(10))
  assert_eq(df.item(1, "column3"), @types.Scalar::Int(31))
}

///|
test "parse_csv_str: custom delimiter (semicolon) splits cells correctly" {
  let content =
    #|a;b;c
    #|1;2;3
    #|4;5;6
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions(delimiter=';'))
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.columns(), ["a", "b", "c"])
  assert_eq(df.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(df.item(1, "c"), @types.Scalar::Int(6))
}

///|
test "parse_csv_str: a delimiter colliding with the quote or a line terminator is rejected" {
  // `"` is the quote character and `\n` / `\r` terminate rows, so none can also
  // separate fields — the reader refuses them up front, the same configurations
  // format_csv refuses, instead of silently mis-splitting.
  for d in ['"', '\n', '\r'] {
    let options : @io.CsvReadOptions = @io.CsvReadOptions(delimiter=d)
    let result = Ok(@io.parse_csv_str("a,b\n1,2\n", options)) catch {
      e => Err(e)
    }
    assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  }
}

///|
test "format_csv: a delimiter colliding with the quote or a line terminator is rejected" {
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1, 2])])
  for d in ['"', '\n', '\r'] {
    let options : @io.CsvWriteOptions = @io.CsvWriteOptions(delimiter=d)
    let result = Ok(@io.format_csv(df, options)) catch { e => Err(e) }
    assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  }
}

///|
test "parse_csv_str / format_csv: a supplementary-plane (non-BMP) delimiter is rejected" {
  // U+1D11E (𝄞) is a UTF-16 surrogate pair; the per-code-unit tokenizer could
  // never match it, so without the guard a round-trip would silently merge
  // every column into one. Both surfaces refuse it up front.
  let read_opts : @io.CsvReadOptions = @io.CsvReadOptions(delimiter='\u{1D11E}')
  let r = Ok(@io.parse_csv_str("a,b\n1,2\n", read_opts)) catch { e => Err(e) }
  assert_true(r is Err(@types.DataError::InvalidOperation(_)))
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1, 2])])
  let write_opts : @io.CsvWriteOptions = @io.CsvWriteOptions(
    delimiter='\u{1D11E}',
  )
  let w = Ok(@io.format_csv(df, write_opts)) catch { e => Err(e) }
  assert_true(w is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "parse_csv_str: custom null_values let NA / N/A become null" {
  let content =
    #|a,b
    #|1,x
    #|NA,N/A
    #|3,z
    #|
  let df = @io.parse_csv_str(
    content,
    @io.CsvReadOptions(null_values=["NA", "N/A"]),
  )
  assert_eq(df.check_invariants(), Ok(()))
  // "a" is Int because NA was skipped during inference; "b" is
  // String because non-null cells "x"/"z" never parse as Int/Float/Bool.
  assert_eq(df.get_column("a").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("b").dtype(), @types.DataType::String)
  assert_eq(df.item(1, "a"), @types.Scalar::Null)
  assert_eq(df.item(1, "b"), @types.Scalar::Null)
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "x"), @types.Scalar::Float(1.5))
  assert_eq(df.item(2, "x"), @types.Scalar::Float(2.0))
}

///|
test "parse_csv_str: Bool inference accepts mixed casing (TRUE / False)" {
  let content =
    #|b
    #|TRUE
    #|False
    #|true
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.item(0, "b"), @types.Scalar::Bool(true))
  assert_eq(df.item(1, "b"), @types.Scalar::Bool(false))
  assert_eq(df.item(2, "b"), @types.Scalar::Bool(true))
}

///|
test "parse_csv_str: a column with no non-null samples defaults to String" {
  let content =
    #|empty,real
    #|,1
    #|,2
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
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
  // is reported as a structured cell error, since the dtype was chosen.
  let content =
    #|x
    #|1
    #|1.5
    #|
  let result = Ok(
    @io.parse_csv_str(content, @io.CsvReadOptions(infer_schema_rows=1)),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Row,
          "x",
          2,
          @types.DataType::Int,
          "1.5",
        ),
      ),
    ),
  )
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
  let df = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (3, 3))
  assert_eq(df.get_column("c").dtype(), @types.DataType::Int)
  assert_eq(df.item(1, "c"), @types.Scalar::Null)
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
  let result = Ok(
    @io.parse_csv_str(content, @io.CsvReadOptions(strict_column_count=true)),
  ) catch {
    e => Err(e)
  }
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
  let df = @io.parse_csv_str(
    content,
    @io.CsvReadOptions(strict_column_count=true),
  )
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.item(1, "c"), @types.Scalar::Int(6))
}

///|
test "parse_csv_str: malformed quotes remain lenient by default" {
  let cases : Array[(String, String)] = [
    ("a,b\n1,\"unclosed", "unclosed"),
    ("a\n\"ab\"cd", "abcd"),
    ("a\nab\"cd", "ab\"cd"),
  ]
  for case in cases {
    let (content, expected) = case
    let implicit = @io.parse_csv_str(content, @io.CsvReadOptions())
    let explicit = @io.parse_csv_str(
      content,
      @io.CsvReadOptions(strict_quotes=false),
    )
    assert_eq(implicit, explicit)
    let column = implicit.columns()[implicit.ncols() - 1]
    assert_eq(implicit.item(0, column), @types.Scalar::String(expected))
  }
}

///|
test "parse_csv_str: strict_quotes rejects all malformed quote shapes" {
  let cases : Array[(String, String)] = [
    ("a,b\n1,\"unclosed", "malformed CSV quote: unterminated quoted field"),
    (
      "a\n\"ab\"cd", "malformed CSV quote: unexpected character after a closing quote",
    ),
    ("a\nab\"cd", "malformed CSV quote: quote inside an unquoted field"),
  ]
  for case in cases {
    let (content, expected) = case
    let result = Ok(
      @io.parse_csv_str(content, @io.CsvReadOptions(strict_quotes=true)),
    ) catch {
      e => Err(e)
    }
    match result {
      Err(
        @types.DataError::ParseError(@types.ParseErrorDetail::Message(message))
      ) => assert_eq(message, expected)
      _ => fail("expected strict quote ParseError")
    }
  }
}

///|
test "parse_csv_str: strict_quotes accepts escaped quotes and quoted CRLF" {
  let options : @io.CsvReadOptions = @io.CsvReadOptions(
    delimiter=';',
    strict_column_count=true,
    strict_quotes=true,
  )
  let content = "a;b\r\n1;\"two\r\nlines\"\r\n2;\"say \"\"hi\"\"\"\r\n3;\r\n"
  let df = @io.parse_csv_str(content, options)
  assert_eq(df.shape(), (3, 2))
  assert_eq(df.item(0, "b"), @types.Scalar::String("two\r\nlines"))
  assert_eq(df.item(1, "b"), @types.Scalar::String("say \"hi\""))
  assert_eq(df.item(2, "b"), @types.Scalar::Null)
}

// ── parse_csv_str: edge / error paths ─────────────────────────────────

///|
test "parse_csv_str: empty content yields a 0x0 frame" {
  let df = @io.parse_csv_str("", @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: has_header=false on empty input also yields 0x0" {
  let df = @io.parse_csv_str("", @io.CsvReadOptions(has_header=false))
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: whitespace-only content collapses to a 0x0 frame" {
  // NyaCSV skips empty lines with the default options, so a single
  // newline parses to zero headers and zero rows; we collapse that
  // to a 0×0 frame via the `ncols == 0` early-return rather than
  // hand `DataFrame::new` an empty schema with synthesised names.
  let df = @io.parse_csv_str("\n", @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: has_header=false on row-less (whitespace) input yields 0x0" {
  // Non-empty content skips the empty-input short-circuit, but NyaCSV
  // reduces "\n" to zero rows; the has_header=false branch then takes the
  // `rows.is_empty()` path and synthesises zero column names → 0×0.
  let df = @io.parse_csv_str("\n", @io.CsvReadOptions(has_header=false))
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (0, 0))
}

///|
test "parse_csv_str: single column, single row" {
  let df = @io.parse_csv_str("only\n42\n", @io.CsvReadOptions())
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.shape(), (1, 1))
  assert_eq(df.item(0, "only"), @types.Scalar::Int(42))
}

///|
test "parse_csv_str: duplicate header is rejected up front" {
  let content =
    #|a,a
    #|1,2
    #|
  assert_eq(
    Ok(@io.parse_csv_str(content, @io.CsvReadOptions())) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("a")),
  )
}

///|
test "parse_csv_str: non-numeric in a Float-locked column is structured" {
  // Inference locks Float on the first two rows, then row 3 is
  // "oops" — a value that can't be coerced to Float.
  let content =
    #|x
    #|1.5
    #|2.5
    #|oops
    #|
  let result = Ok(
    @io.parse_csv_str(content, @io.CsvReadOptions(infer_schema_rows=2)),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Row,
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
test "parse_csv_str: non-bool value outside inference is structured" {
  // Lock Bool on the first two rows, then a "maybe" in row 3.
  let content =
    #|b
    #|true
    #|false
    #|maybe
    #|
  let result = Ok(
    @io.parse_csv_str(content, @io.CsvReadOptions(infer_schema_rows=2)),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Row,
          "b",
          3,
          @types.DataType::Bool,
          "maybe",
        ),
      ),
    ),
  )
}

///|
test "parse_csv_str: non-int outside the inference window is structured" {
  let content =
    #|n
    #|1
    #|2
    #|x
    #|
  let result = Ok(
    @io.parse_csv_str(content, @io.CsvReadOptions(infer_schema_rows=2)),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Row,
          "n",
          3,
          @types.DataType::Int,
          "x",
        ),
      ),
    ),
  )
}

// ── parse_csv_str: O4 read resilience (scan-all / on_parse_error / nan) ──

///|
test "parse_csv_str: infer_schema_rows=0 scans every row to fix late dtype shifts" {
  // Row 1 looks Int; row 2 is a Float. A 1-row window locks Int and then
  // rejects the Float (the `infer_schema_rows=1` test above). Scanning every
  // row (`0`, Polars' `infer_schema_length=None`) sees the Float during
  // inference and types the column Float — no ParseError, no prefix
  // mis-guess. (Under the old `0 → all-null window → String` rule this
  // column would have come back String, so the Float dtype also pins the
  // redefined `0` semantics.)
  let content =
    #|x
    #|1
    #|1.5
    #|
  let df = @io.parse_csv_str(content, @io.CsvReadOptions(infer_schema_rows=0))
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(df.item(0, "x"), @types.Scalar::Float(1.0))
  assert_eq(df.item(1, "x"), @types.Scalar::Float(1.5))
}

///|
test "parse_csv_str: on_parse_error=Null downgrades an out-of-window misfit to null" {
  // Inference locks Int on the first two rows; row 3 ("x") can't parse as
  // Int. With `Raise` (the default, exercised above) this is a ParseError;
  // with `Null` the offending cell becomes null and the column keeps its
  // inferred Int dtype — Polars' `ignore_errors=True`.
  let content =
    #|n
    #|1
    #|2
    #|x
    #|
  let df = @io.parse_csv_str(
    content,
    @io.CsvReadOptions(
      infer_schema_rows=2,
      on_parse_error=@io.OnParseError::Null,
    ),
  )
  assert_eq(df.check_invariants(), Ok(()))
  assert_eq(df.get_column("n").dtype(), @types.DataType::Int)
  assert_eq(df.item(0, "n"), @types.Scalar::Int(1))
  assert_eq(df.item(2, "n"), @types.Scalar::Null)
  assert_eq(df.get_column("n").null_count(), 1)
}

///|
test "parse_csv_str: allow_nonfinite_floats gates nan / inf float inference" {
  // `nan` / `inf` are literals `@string.parse_double` accepts, so by
  // default a column of them infers Float (the non-finite cells become
  // Double NaN / ±Infinity). Turning the gate off rejects those literals
  // during inference, so the column falls back to String instead of being
  // silently retyped — the F5 escape hatch.
  let content =
    #|x
    #|nan
    #|1.5
    #|inf
    #|
  let as_float = @io.parse_csv_str(content, @io.CsvReadOptions())
  assert_eq(as_float.check_invariants(), Ok(()))
  assert_eq(as_float.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(as_float.item(1, "x"), @types.Scalar::Float(1.5))
  // The non-finite cells stay Float (NaN / +Infinity), not null.
  assert_true(as_float.item(0, "x") is @types.Scalar::Float(_))
  assert_true(as_float.item(2, "x") is @types.Scalar::Float(_))
  let as_string = @io.parse_csv_str(
    content,
    @io.CsvReadOptions(allow_nonfinite_floats=false),
  )
  assert_eq(as_string.get_column("x").dtype(), @types.DataType::String)
  assert_eq(as_string.item(0, "x"), @types.Scalar::String("nan"))
  assert_eq(as_string.item(1, "x"), @types.Scalar::String("1.5"))
  assert_eq(as_string.item(2, "x"), @types.Scalar::String("inf"))
}

///|
test "parse_csv_str: allow_nonfinite=false rejects a leading inf (is_inf gate)" {
  // Regression for the `parse_float_opt` non-finite gate: its `x.is_inf()`
  // arm is only reached when a cell parses to ±Infinity *without* a NaN
  // ahead of it short-circuiting `is_nan() || is_inf()`. With `inf` as the
  // first cell, float inference probes it directly, hits `is_inf()`, rejects
  // it, and the column falls back to String instead of Float.
  let content =
    #|x
    #|inf
    #|2.5
    #|
  let df = @io.parse_csv_str(
    content,
    @io.CsvReadOptions(allow_nonfinite_floats=false),
  )
  assert_eq(df.get_column("x").dtype(), @types.DataType::String)
  assert_eq(df.item(0, "x"), @types.Scalar::String("inf"))
  assert_eq(df.item(1, "x"), @types.Scalar::String("2.5"))
}

// ── format_csv: happy paths ───────────────────────────────────────

///|
test "format_csv: header on, mixed dtypes, null cell becomes empty" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), Some(2), None]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions())
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
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("a", [1, 2]),
    @series.Series::from_ints("b", [3, 4]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions(header=false))
  let expected =
    #|1,3
    #|2,4
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: custom delimiter (semicolon)" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("a", [1, 2]),
    @series.Series::from_strings("b", ["x", "y"]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions(delimiter=';'))
  let expected =
    #|a;b
    #|1;x
    #|2;y
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: custom null_value rendering" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions(null_value="NA"))
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
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", [
      "=SUM(A1)", "+1", "-1", "@name", "\t=1", "\r=1", "",
    ]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions(sanitize_formulas=true))
  assert_eq(out, "s\n'=SUM(A1)\n'+1\n'-1\n'@name\n'\t=1\n\"'\r=1\"\n\"\"\n")
}

///|
test "format_csv: formula sanitization changes only formula-like String cells" {
  let df = @frame.DataFrame::new([
    @series.Series::from_string_options("s", [Some("-1"), None, Some("a,b")]),
    @series.Series::from_ints("i", [-1, 2, 3]),
    @series.Series::from_floats("f", [-1.5, 2.5, 3.5]),
    @series.Series::from_bools("b", [true, false, true]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions(sanitize_formulas=true))
  assert_eq(
    out, "s,i,f,b\n'-1,-1,-1.5,true\n,2,2.5,false\n\"a,b\",3,3.5,true\n",
  )
}

///|
test "format_csv: formula sanitization is opt-in and false is byte-identical" {
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", ["=SUM(A1)", "ordinary"]),
  ])
  let default_out = @io.format_csv(df, @io.CsvWriteOptions())
  let explicit_false = @io.format_csv(
    df,
    @io.CsvWriteOptions(sanitize_formulas=false),
  )
  assert_eq(default_out, "s\n=SUM(A1)\nordinary\n")
  assert_eq(explicit_false, default_out)
}

///|
test "format_csv: quotes cells with delimiter, quote, newline, or CR" {
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("a", [
      "needs,comma", "needs\"quote", "needs\nlf", "needs\rcr",
    ]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions())
  // Every body cell is quoted; the embedded double quote in row 2
  // is doubled per RFC 4180.
  let expected = "a\n\"needs,comma\"\n\"needs\"\"quote\"\n\"needs\nlf\"\n\"needs\rcr\"\n"
  assert_eq(out, expected)
}

///|
test "format_csv: also quotes header names that contain the delimiter" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("hello,world", [1, 2]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions())
  let expected =
    #|"hello,world"
    #|1
    #|2
    #|
  assert_eq(out, expected)
}

///|
test "format_csv: empty frame produces just the header row (or nothing)" {
  // 0 columns, 0 rows: nothing to emit even with header on.
  let empty = @frame.DataFrame::new([])
  let out = @io.format_csv(empty, @io.CsvWriteOptions())
  assert_eq(out, "\n")
  // header off + empty frame: still emits one blank record terminator
  // (no cells, only the trailing newline from the header branch).
  let out_no_header = @io.format_csv(empty, @io.CsvWriteOptions(header=false))
  assert_eq(out_no_header, "")
}

///|
test "format_csv: 0 rows with declared schema emits header only" {
  let schema = @types.Schema::new([
    @types.Field("a", @types.DataType::Int),
    @types.Field("b", @types.DataType::String),
  ])
  let df = @frame.DataFrame::empty(schema)
  let out = @io.format_csv(df, @io.CsvWriteOptions())
  let expected =
    #|a,b
    #|
  assert_eq(out, expected)
}

///|
test "parse_csv_str: strips a leading UTF-8 BOM from the first column name" {
  // Excel / Windows tools prepend a U+FEFF BOM; it must not become part of
  // the first header (which would make `get_column(\"id\")` miss).
  let text = "\u{FEFF}id,val\n1,2\n"
  let df = @io.parse_csv_str(text, @io.CsvReadOptions())
  assert_eq(df.columns(), ["id", "val"])
  assert_eq(df.shape(), (1, 2))
  assert_eq(df.item(0, "id"), @types.Scalar::Int(1))
  assert_eq(df.item(0, "val"), @types.Scalar::Int(2))
}

// ── round trip via parse_csv_str / format_csv ─────────────────────

///|
test "parse_csv_str ∘ format_csv: round-trip preserves dtypes and values" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
    @series.Series::from_floats("r", [
      (1.5 : Double),
      (2.5 : Double),
      (3.5 : Double),
    ]),
    @series.Series::from_bool_options("b", [Some(true), Some(false), None]),
    @series.Series::from_strings("s", ["alpha", "beta", "gamma"]),
  ])
  let text = @io.format_csv(df, @io.CsvWriteOptions())
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions())
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
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [Some(1), None, Some(3)]),
  ])
  let text = @io.format_csv(df, @io.CsvWriteOptions())
  // The null row is emitted as a quoted empty, not a bare blank line the
  // reader's `skip_empty_lines` would discard.
  assert_eq(text, "n\n1\n\"\"\n3\n")
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions())
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 1))
  assert_eq(parsed.get_column("n").dtype(), df.get_column("n").dtype())
  for i in 0..<3 {
    assert_eq(parsed.item(i, "n"), df.item(i, "n"))
  }
}

///|
test "round-trip: an all-null single column keeps every row" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("n", [None, None, None]),
  ])
  let text = @io.format_csv(df, @io.CsvWriteOptions())
  assert_eq(text, "n\n\"\"\n\"\"\n\"\"\n")
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions())
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
  let df = @frame.DataFrame::new([@series.Series::from_ints("", [10, 20, 30])])
  let text = @io.format_csv(df, @io.CsvWriteOptions())
  // The empty header is written as `""`, so the first data row is not lifted
  // into the header and the column name is not lost.
  assert_eq(text, "\"\"\n10\n20\n30\n")
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions())
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 1))
  assert_eq(parsed.columns(), [""])
  for i in 0..<3 {
    assert_eq(parsed.item(i, ""), df.item(i, ""))
  }
}

///|
test "format_csv: a wider frame's empty cells stay bare (single-column-only quoting)" {
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("a", [Some(1), None]),
    @series.Series::from_int_options("b", [None, Some(2)]),
  ])
  let out = @io.format_csv(df, @io.CsvWriteOptions())
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
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("text", [
      "needs,comma", "has \"quote\"", "two\nlines",
    ]),
    @series.Series::from_ints("n", [1, 2, 3]),
  ])
  let text = @io.format_csv(df, @io.CsvWriteOptions())
  let parsed = @io.parse_csv_str(text, @io.CsvReadOptions())
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.shape(), (3, 2))
  assert_eq(parsed.item(0, "text"), @types.Scalar::String("needs,comma"))
  assert_eq(parsed.item(1, "text"), @types.Scalar::String("has \"quote\""))
  assert_eq(parsed.item(2, "text"), @types.Scalar::String("two\nlines"))
  assert_eq(parsed.item(2, "n"), @types.Scalar::Int(3))
}

// ── read_csv / write_csv: file-system path ────────────────────────────

///|
test "write_csv then read_csv round-trips a small frame on disk" {
  let path = "_build/io_csv_test_roundtrip.csv"
  let df = @frame.DataFrame::new([
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
  // A lone surrogate is ingestible (JSON's \uD800 escape), but the UTF-8
  // file encoder would merge it with the *following* code unit — here the
  // delimiter after column `a` — silently shifting every later cell
  // boundary. The write is refused up front instead, matching
  // `validate_csv_delimiter`'s reject-rather-than-corrupt philosophy.
  let df = @io.parse_ndjson_str(
    "{\"a\":\"\\ud800\",\"b\":1}\n",
    @io.JsonReadOptions(),
  )
  let w = Ok(@io.write_csv("_build/io_csv_surrogate_reject.csv", df)) catch {
    e => Err(e)
  }
  assert_true(w is Err(@types.DataError::InvalidOperation(_)))
  // A bare *low* surrogate (not preceded by a high one) is just as
  // ill-formed and is refused by the same guard.
  let df_low = @io.parse_ndjson_str(
    "{\"a\":\"\\udc00\"}\n",
    @io.JsonReadOptions(),
  )
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
  let df = @frame.DataFrame::new([@series.Series::from_strings("a", ["x"])])
  let opts : @io.CsvWriteOptions = @io.CsvWriteOptions(delimiter='\u{FEFF}')
  assert_true(
    (Ok(@io.format_csv(df, opts)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a leading U+FEFF in the first column name survives the round-trip" {
  // Bare at byte 0 the U+FEFF would be stripped as a BOM on read-back,
  // silently renaming the column; the writer force-quotes the file's very
  // first field so a leading quote shields it.
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("\u{FEFF}id", ["v"]),
    @series.Series::from_strings("b", ["w"]),
  ])
  let back = @io.parse_csv_str(
    @io.format_csv(df, @io.CsvWriteOptions()),
    @io.CsvReadOptions(),
  )
  assert_eq(back.columns(), ["\u{FEFF}id", "b"])
  assert_eq(back, df)
}

///|
test "write_csv still writes well-formed surrogate pairs" {
  // The guard only rejects *unpaired* surrogates: a supplementary-plane
  // character stored as a proper pair round-trips unharmed.
  let path = "_build/io_csv_surrogate_pair_ok.csv"
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", ["𝄞clef"]),
  ])
  @io.write_csv(path, df)
  assert_eq(@io.read_csv(path), df)
}

///|
test "write_csv_with_options + read_csv_with_options honour custom shape" {
  let path = "_build/io_csv_test_custom.csv"
  let df = @frame.DataFrame::new([
    @series.Series::from_int_options("a", [Some(1), None]),
    @series.Series::from_strings("b", ["p", "q"]),
  ])
  let write_opts : @io.CsvWriteOptions = @io.CsvWriteOptions(
    delimiter=';',
    null_value="NA",
  )
  let read_opts : @io.CsvReadOptions = @io.CsvReadOptions(delimiter=';', null_values=[
    "NA",
  ])
  @io.write_csv_with_options(path, df, write_opts)
  let parsed = @io.read_csv_with_options(path, read_opts)
  assert_eq(parsed.check_invariants(), Ok(()))
  assert_eq(parsed.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(parsed.item(1, "a"), @types.Scalar::Null)
  assert_eq(parsed.item(0, "b"), @types.Scalar::String("p"))
}

///|
test "write_csv_with_options forwards formula sanitization" {
  let path = "_build/io_csv_formula_sanitized.csv"
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("s", ["=SUM(A1)"]),
  ])
  @io.write_csv_with_options(
    path,
    df,
    @io.CsvWriteOptions(sanitize_formulas=true),
  )
  let parsed = @io.read_csv(path)
  assert_eq(parsed.item(0, "s"), @types.Scalar::String("'=SUM(A1)"))
}

///|
test "CSV file readers forward strict quote validation" {
  let path = "_build/io_csv_strict_quotes.csv"
  @fs.write_string_to_file(path, "a,b\n1,\"unclosed")
  let eager = Ok(
    @io.read_csv_with_options(path, @io.CsvReadOptions(strict_quotes=true)),
  ) catch {
    e => Err(e)
  }
  let projected = Ok(
    @io.read_csv_projected(path, @io.CsvReadOptions(strict_quotes=true), ["a"]),
  ) catch {
    e => Err(e)
  }
  assert_true(eager is Err(@types.DataError::ParseError(_)))
  assert_true(projected is Err(@types.DataError::ParseError(_)))
}

///|
test "read_csv: missing file surfaces as IoError, not panic" {
  let result = Ok(@io.read_csv("_build/io_csv_test_does_not_exist.csv")) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "read_csv_with_options: missing file surfaces as IoError" {
  let result = Ok(
    @io.read_csv_with_options(
      "_build/io_csv_test_does_not_exist.csv",
      @io.CsvReadOptions(),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_csv: invalid path surfaces as IoError" {
  // Write into a directory that does not exist. The native fs
  // backend rejects the open call with an IOError; we promote it
  // to the DataError variant.
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let result = Ok(@io.write_csv("_build/no_such_dir_io_test/file.csv", df)) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "write_csv_with_options: invalid path surfaces as IoError" {
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let result = Ok(
    @io.write_csv_with_options(
      "_build/no_such_dir_io_test_2/file.csv",
      df,
      @io.CsvWriteOptions(),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

// ── CsvReadOptions / CsvWriteOptions defaults ─────────────────────────

///|
test "CsvReadOptions::default exposes expected defaults" {
  let opts = @io.CsvReadOptions()
  assert_eq(opts.has_header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.infer_schema_rows, 100)
  assert_eq(opts.null_values(), [""])
  assert_eq(opts.strict_column_count, false)
  assert_eq(opts.on_parse_error, @io.OnParseError::Raise)
  assert_eq(opts.allow_nonfinite_floats, true)
}

///|
test "CsvWriteOptions::default exposes expected defaults" {
  let opts = @io.CsvWriteOptions()
  assert_eq(opts.header, true)
  assert_eq(opts.delimiter, ',')
  assert_eq(opts.null_value, "")
}
