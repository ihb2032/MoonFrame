// Blackbox tests for the SAS interchange at the io layer — the
// file-level write/read round trip of the transport format, the reference
// writers' transport file and data sets through the entries, and the
// refusals a caller meets. (One-file-one-test exemption: none — this is
// the format's only test file at this layer; the codecs' own tests sit
// in their packages.)

///|
fn sas_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_float_options("ratio", [Some(1.5), None, Some(-0.25)]),
    @series.Series::from_string_options("label", [
      Some("café 日本語"),
      Some(""),
      None,
    ]),
    @series.Series::from_date_options("day", [Some(0L), Some(-1L), Some(19782L)]),
    @series.Series::from_timestamp_options("at", [
      Some(0L),
      Some(61500000000L),
      None,
    ]),
  ])
}

///|
test "write_sas / read_sas round-trip" {
  let df = sas_frame()
  let path = "_build/io_sas_roundtrip.xpt"
  @io.write_sas(df, path)
  let back = @io.read_sas(path)
  assert_eq(back.shape(), df.shape())
  assert_eq(back.columns(), df.columns())
  assert_eq(back.get_column("ratio").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Null,
    @types.Scalar::Float(-0.25),
  ])
  // The format has no missing string: a missing cell reads back empty.
  assert_eq(back.get_column("label").to_scalars(), [
    @types.Scalar::String("café 日本語"),
    @types.Scalar::String(""),
    @types.Scalar::String(""),
  ])
  assert_eq(back.get_column("day").to_scalars(), [
    @types.Scalar::Date(0L),
    @types.Scalar::Date(-1L),
    @types.Scalar::Date(19782L),
  ])
  assert_eq(back.get_column("at").to_scalars(), [
    @types.Scalar::Timestamp(0L),
    @types.Scalar::Timestamp(61500000000L),
    @types.Scalar::Null,
  ])
  // The bytes already in memory parse to the same frame, and the same
  // frame writes the same file.
  let bytes = @fs.read_file_to_bytes(path) catch { _ => b"" }
  assert_eq(@io.parse_sas(bytes).shape(), df.shape())
  @io.write_sas(df, "_build/io_sas_again.xpt")
  let again = @fs.read_file_to_bytes("_build/io_sas_again.xpt") catch {
    _ => b""
  }
  assert_eq(bytes, again)
  // The file opens with the transport format's library header record.
  assert_eq(
    @utf8.decode(bytes[0:41]) catch {
      _ => ""
    },
    "HEADER RECORD*******LIBRARY HEADER RECORD",
  )
  // An integer and a boolean are numbers in the file.
  let numeric = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("num", [1, -2]),
    @series.Series::from_bools("flag", [true, false]),
  ])
  @io.write_sas(numeric, path)
  let numbers = @io.read_sas(path)
  for name in numeric.columns() {
    assert_eq(numbers.get_column(name).dtype(), @types.DataType::Float)
  }
  assert_eq(numbers.get_column("num").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(-2.0),
  ])
  assert_eq(numbers.get_column("flag").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(0.0),
  ])
}

///|
test "the reference writer's file reads through the entries" {
  // A file of no variable reads as a frame of no column.
  assert_eq(
    @io.read_sas(".github/fixtures/xport/reference/zerovars_pyrs.xpt").shape(),
    (0, 0),
  )
  let df = @io.read_sas(".github/fixtures/xport/reference/plain_pyrs.xpt")
  assert_eq(df.shape(), (5, 4))
  assert_eq(df.columns(), ["num", "ratio", "flag", "label"])
  assert_eq(df.get_column("num").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("num").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(-2.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(5.0),
  ])
  // A missing cell, and a blank one.
  assert_eq(df.get_column("ratio").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Null,
    @types.Scalar::Float(-0.25),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(2.5),
  ])
  assert_eq(df.get_column("label").to_scalars(), [
    @types.Scalar::String("ab"),
    @types.Scalar::String("cdef"),
    @types.Scalar::String(""),
    @types.Scalar::String("ghij"),
    @types.Scalar::String("klmnöp"),
  ])
  // A date and a datetime under their formats.
  let dated = @io.read_sas(".github/fixtures/xport/reference/dates_pyrs.xpt")
  for column in dated.column_series() {
    assert_eq(column.dtype(), @types.DataType::Date)
  }
  let stamped = @io.read_sas(
    ".github/fixtures/xport/reference/datetimes_pyrs.xpt",
  )
  for column in stamped.column_series() {
    assert_eq(column.dtype(), @types.DataType::Timestamp)
  }
}

///|
test "a data set reads through the entries, told from a transport file by its first bytes" {
  // The reference writer's 32-bit table.
  let path = ".github/fixtures/sas7bdat/reference/w32_pyrs.sas7bdat"
  let written = @io.read_sas(path)
  assert_eq(written.shape(), (2, 2))
  assert_eq(written.columns(), ["a", "b"])
  assert_eq(written.get_column("a").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
  ])
  assert_eq(written.get_column("b").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("yy"),
  ])
  // A data set SAS wrote, its text windows-1252 under a code that records
  // no character set.
  let cars = @io.read_sas(".github/fixtures/sas7bdat/reference/cars.sas7bdat")
  assert_eq(cars.shape(), (392, 4))
  assert_eq(cars.get_column("MPG").to_scalars()[0], @types.Scalar::Float(18.0))
  // A 64-bit data set with a date column and a missing cell.
  let dated = @io.read_sas(
    ".github/fixtures/sas7bdat/reference/test16.sas7bdat",
  )
  assert_eq(dated.shape(), (10, 100))
  assert_eq(dated.get_column("Column4").dtype(), @types.DataType::Date)
  assert_eq(
    dated.get_column("Column4").to_scalars()[0],
    @types.Scalar::Date(-1483L),
  )
  assert_eq(dated.get_column("Column8").to_scalars()[0], @types.Scalar::Null)
  // The bytes already in memory parse to the same frame.
  let bytes = @fs.read_file_to_bytes(path) catch { _ => b"" }
  assert_eq(@io.parse_sas(bytes).shape(), written.shape())
}

///|
/// The error an entry raises; a frame answered instead fails the test.
fn sas_raised(
  read : () -> @frame.DataFrame raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(ignore(read())) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the file read as a frame")
    Err(e) => e
  }
}

///|
test "the SAS entries raise the errors a caller meets" {
  // A path that cannot be read is the read's IoError.
  let missing = sas_raised(() => @io.read_sas("_build/no_such_sas.xpt"))
  assert_true(missing is @types.DataError::IoError(_))
  // A path that cannot be written is the write's IoError.
  let df = sas_frame()
  let unwritable = Ok(ignore(@io.write_sas(df, "_build/no_such_dir_z/out.xpt"))) catch {
    e => Err(e)
  }
  assert_true(unwritable is Err(@types.DataError::IoError(_)))
  // A column whose name the format does not hold, and two that differ
  // only in case.
  let named = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("far_too_long_a_name", [1]),
  ])
  assert_eq(
    sas_raised(() => {
      @io.parse_sas(@xport.write_xport_bytes(named.column_series()))
    }),
    @types.DataError::InvalidOperation(
      "xport: cannot write column 1: \"far_too_long_a_name\" is not a name the transport format holds, which is one to eight ASCII letters, digits or underscores opening on a letter or an underscore",
    ),
  )
  let alike = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("sales", [1]),
    @series.Series::from_ints("SALES", [2]),
  ])
  assert_eq(
    sas_raised(() => {
      @io.parse_sas(@xport.write_xport_bytes(alike.column_series()))
    }),
    @types.DataError::InvalidOperation(
      "xport: cannot write column 2: its name \"SALES\" and column 1's name \"sales\" differ only in case, and the transport format holds them as one variable",
    ),
  )
  // A column of a dtype the format has no type for.
  let spanned = @frame.DataFrame::DataFrame([
    @series.Series::from_duration_options("span", [Some(5L)]),
  ])
  assert_eq(
    sas_raised(() => {
      @io.parse_sas(@xport.write_xport_bytes(spanned.column_series()))
    }),
    @types.DataError::Unsupported(
      "xport: cannot write column \"span\": the transport format does not carry a column of dtype Duration",
    ),
  )
  // Bytes that open with neither a transport file's header record nor a
  // data set's signature.
  let junk = sas_raised(() => {
    @io.parse_sas(b"not a sas file at all, just some bytes")
  })
  assert_eq(
    junk,
    @types.DataError::Unsupported(
      "sas: the bytes open with neither a transport file's library header record nor a data set's signature",
    ),
  )
  // A transport file cut short inside its header record, a data set cut
  // short inside its header, and a data set in a character set this reader
  // does not decode.
  let opening = sas_raised(() => {
    @io.parse_sas(b"HEADER RECORD*******LIBRARY HEADER REC")
  })
  assert_eq(
    opening,
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "xport: byte 0: the file ends at byte 38 inside the library header record (bytes 0 to 79)",
      ),
    ),
  )
  let whole = @fs.read_file_to_bytes(
    ".github/fixtures/sas7bdat/reference/w32_pyrs.sas7bdat",
  ) catch {
    _ => b""
  }
  let header_cut = sas_raised(() => @io.parse_sas(whole[0:100].to_owned()))
  assert_true(header_cut is @types.DataError::ParseError(_))
  let charset = sas_raised(() => {
    @io.read_sas(".github/fixtures/sas7bdat/reference/shiftjis_syn.sas7bdat")
  })
  assert_eq(
    charset,
    @types.DataError::Unsupported(
      "sas7bdat: byte 70: the character-set field names shift_jis (code 138), and this reader decodes UTF-8 (code 20) and the single-byte character sets",
    ),
  )
  // A file cut short inside its header records. It is this test's own
  // file: what another test wrote, and when, is not relied on.
  let own = "_build/io_sas_errors.xpt"
  @io.write_sas(df, own)
  let whole = @fs.read_file_to_bytes(own)
  let cut = sas_raised(() => @io.parse_sas(whole[0:100].to_owned()))
  assert_true(
    cut
    is @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "xport: byte 80: the file ends at byte 100 inside the library's description records (bytes 80 to 239)",
      ),
    ),
  )
}
