// Blackbox tests for the Stata interchange at the io layer — the
// file-level write/read round trip, the projection rule, the reference
// implementation's files through the entries, and the refusals a caller
// meets. (One-file-one-test exemption: none — this is the format's only
// test file at this layer; the codec's own tests sit beside it.)

///|
fn stata_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("num", [Some(1), None, Some(-7)]),
    @series.Series::from_string_options("label", [
      Some("café 日本語"),
      Some(""),
      None,
    ]),
    @series.Series::from_date_options("day", [Some(0L), Some(-1L), Some(19782L)]),
    @series.Series::from_float_options("ratio", [Some(1.5), Some(-0.25), None]),
  ])
}

///|
test "write_stata / read_stata round-trip" {
  let df = stata_frame()
  let path = "_build/io_stata_roundtrip.dta"
  @io.write_stata(df, path)
  let back = @io.read_stata(path)
  assert_eq(back.shape(), df.shape())
  assert_eq(back.columns(), df.columns())
  assert_eq(back.get_column("num").to_scalars(), [
    @types.Scalar::Int(1L),
    @types.Scalar::Null,
    @types.Scalar::Int(-7L),
  ])
  assert_eq(back.get_column("day").to_scalars(), [
    @types.Scalar::Date(0L),
    @types.Scalar::Date(-1L),
    @types.Scalar::Date(19782L),
  ])
  assert_eq(back.get_column("ratio").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(-0.25),
    @types.Scalar::Null,
  ])
  // The format has no missing string: a missing cell reads back empty.
  assert_eq(back.get_column("label").to_scalars(), [
    @types.Scalar::String("café 日本語"),
    @types.Scalar::String(""),
    @types.Scalar::String(""),
  ])
  // The bytes already in memory parse to the same frame, and the same
  // frame writes the same file.
  let bytes = @fs.read_file_to_bytes(path) catch { _ => b"" }
  assert_eq(@io.parse_stata(bytes).shape(), df.shape())
  @io.write_stata(df, "_build/io_stata_again.dta")
  let again = @fs.read_file_to_bytes("_build/io_stata_again.dta") catch {
    _ => b""
  }
  assert_eq(bytes, again)
  // The file opens as a release 118 dataset.
  assert_eq(bytes[0], b'<')
  assert_eq(bytes[28:31], b"118")
  // A Bool column writes as 0 / 1 and reads back as Int.
  let flagged = @frame.DataFrame::DataFrame([
    @series.Series::from_bools("flag", [true, false]),
  ])
  @io.write_stata(flagged, path)
  let flags = @io.read_stata(path)
  assert_eq(flags.get_column("flag").dtype(), @types.DataType::Int)
  assert_eq(flags.get_column("flag").to_scalars(), [
    @types.Scalar::Int(1L),
    @types.Scalar::Int(0L),
  ])
}

///|
test "read_stata projection names the columns it keeps" {
  let df = stata_frame()
  let path = "_build/io_stata_projection.dta"
  @io.write_stata(df, path)
  let back = @io.read_stata(path, projection=["day", "num"])
  assert_eq(back.columns(), ["num", "day"])
  assert_eq(back.nrows(), 3)
  // A name the file does not carry builds no column — lenient like the
  // other readers' projection, the rows over zero columns.
  let miss = @io.read_stata(path, projection=["nope"])
  assert_eq(miss.columns(), [])
  assert_eq(miss.nrows(), 3)
  // The whole frame without a projection, and the projection over bytes.
  assert_eq(@io.read_stata(path).shape(), df.shape())
  let bytes = @fs.read_file_to_bytes(path) catch { _ => b"" }
  assert_eq(@io.parse_stata(bytes, projection=["ratio"]).columns(), ["ratio"])
}

///|
test "the reference implementation's files read through the entries" {
  // A release 118 file, little-endian, with long strings and a date and
  // a clock column under the date families.
  let le = @io.read_stata(".github/fixtures/stata/reference/pandas_v118_le.dta")
  assert_eq(le.shape(), (6, 12))
  assert_eq(le.get_column("date").dtype(), @types.DataType::Date)
  assert_eq(le.get_column("date").to_scalars(), [
    @types.Scalar::Date(-3653L),
    @types.Scalar::Date(0L),
    @types.Scalar::Date(19782L),
    @types.Scalar::Date(-25567L),
    @types.Scalar::Date(10957L),
    @types.Scalar::Date(-3653L),
  ])
  assert_eq(le.get_column("stamp").dtype(), @types.DataType::Timestamp)
  assert_eq(
    le.get_column("strl").to_scalars()[0],
    @types.Scalar::String("short"),
  )
  // The same table as its release 119, big-endian file.
  let be = @io.read_stata(".github/fixtures/stata/reference/pandas_v119_be.dta")
  assert_eq(be.shape(), le.shape())
  for name in le.columns() {
    assert_eq(
      be.get_column(name).to_scalars(),
      le.get_column(name).to_scalars(),
    )
  }
  // A projection over a reference file.
  let picked = @io.read_stata(
    ".github/fixtures/stata/reference/pandas_v118_le.dta",
    projection=["labelled"],
  )
  assert_eq(picked.columns(), ["labelled"])
  assert_eq(picked.get_column("labelled").to_scalars(), [
    @types.Scalar::Int(1L),
    @types.Scalar::Int(2L),
    @types.Scalar::Int(1L),
    @types.Scalar::Int(3L),
    @types.Scalar::Int(2L),
    @types.Scalar::Int(1L),
  ])
}

///|
test "the Stata entries raise the errors a caller meets" {
  // A path that cannot be read is the read's IoError.
  let missing = Ok(ignore(@io.read_stata("_build/no_such_stata.dta"))) catch {
    e => Err(e)
  }
  assert_true(missing is Err(@types.DataError::IoError(_)))
  // A path that cannot be written is the write's IoError.
  let df = stata_frame()
  let unwritable = Ok(
    ignore(@io.write_stata(df, "_build/no_such_dir_z/out.dta")),
  ) catch {
    e => Err(e)
  }
  assert_true(unwritable is Err(@types.DataError::IoError(_)))
  // A column whose name the format forbids.
  let named = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("gdp/cap", [1]),
  ])
  let refused = Ok(ignore(@io.write_stata(named, "_build/io_stata_named.dta"))) catch {
    e => Err(e)
  }
  assert_eq(
    refused,
    Err(
      @types.DataError::InvalidOperation(
        "the column name \"gdp/cap\" holds U+002F, outside the letters, digits and underscore a Stata variable name allows",
      ),
    ),
  )
  // A column of a dtype the format has no type for.
  let spanned = @frame.DataFrame::DataFrame([
    @series.Series::from_duration_options("span", [Some(5L)]),
  ])
  let span = Ok(ignore(@io.write_stata(spanned, "_build/io_stata_span.dta"))) catch {
    e => Err(e)
  }
  assert_eq(
    span,
    Err(
      @types.DataError::Unsupported(
        "stata cannot carry column \"span\" of dtype Duration",
      ),
    ),
  )
  // Bytes whose first byte names a release this reader does not read.
  let junk = Ok(ignore(@io.parse_stata(b"not a stata file"))) catch {
    e => Err(e)
  }
  assert_eq(
    junk,
    Err(
      @types.DataError::Unsupported(
        "the file declares release 110; this reader reads releases 113 to 119",
      ),
    ),
  )
  // A file that ends inside its header.
  let cut = Ok(ignore(@io.parse_stata(b"\x71\x02"))) catch { e => Err(e) }
  assert_eq(
    cut,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "stata: the file ends at byte 2 before the 2 bytes needed at offset 2",
        ),
      ),
    ),
  )
}
