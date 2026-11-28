// Blackbox tests for the SPSS system-file interchange at the io layer — the
// reference writer's files through the entries, and the refusals a caller
// meets. (One-file-one-test exemption: none — this is the format's only test
// file at this layer; the codec's own tests sit in its package.)

///|
/// The bytes of a file of the reference corpus, already in memory.
fn spss_bytes(name : String) -> Bytes {
  @fs.read_file_to_bytes(".github/fixtures/spss/reference/\{name}") catch {
    _ => b""
  }
}

///|
test "the reference writer's system files read through the entries" {
  // Four cases: a number and a two-byte string.
  let path = ".github/fixtures/spss/reference/pyrs_four_rows.sav"
  let df = @io.read_spss(path)
  assert_eq(df.shape(), (4, 2))
  assert_eq(df.columns(), ["a", "s"])
  assert_eq(df.get_column("a").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.5),
    @types.Scalar::Float(-3.0),
    @types.Scalar::Float(4.0),
  ])
  assert_eq(df.get_column("s").to_scalars(), [
    @types.Scalar::String("aa"),
    @types.Scalar::String("bb"),
    @types.Scalar::String("cc"),
    @types.Scalar::String("dd"),
  ])
  // The bytes already in memory parse to the same frame, and so does the
  // same table written in the other byte order, or with no case count in
  // its header.
  assert_eq(
    @io.parse_spss(spss_bytes("pyrs_four_rows.sav"))
    .get_column("a")
    .to_scalars(),
    df.get_column("a").to_scalars(),
  )
  assert_eq(
    @io.read_spss(".github/fixtures/spss/reference/synthetic_big_endian.sav").shape(),
    (4, 2),
  )
  assert_eq(
    @io.parse_spss(spss_bytes("pyrs_ncases_unknown.sav")).shape(),
    (4, 2),
  )
  // A variable under a date, a datetime or a time format reads as the
  // converted kind; the file counts a date in seconds since 14 October
  // 1582, and a time of day is an instant on the epoch day.
  let formats = @io.read_spss(
    ".github/fixtures/spss/reference/pyrs_formats.sav",
  )
  assert_eq(formats.shape(), (4, 16))
  assert_eq(formats.get_column("adate40").dtype(), @types.DataType::Date)
  assert_eq(formats.get_column("adate40").to_scalars(), [
    @types.Scalar::Date(18322L),
    @types.Scalar::Date(-141428L),
    @types.Scalar::Date(0L),
    @types.Scalar::Null,
  ])
  assert_eq(formats.get_column("datetime40").to_scalars(), [
    @types.Scalar::Timestamp(1583066096789000L),
    @types.Scalar::Timestamp(-12219379200000000L),
    @types.Scalar::Timestamp(-500000L),
    @types.Scalar::Null,
  ])
  assert_eq(formats.get_column("time8").dtype(), @types.DataType::Timestamp)
  assert_eq(formats.get_column("time8").to_scalars(), [
    @types.Scalar::Timestamp(90000000L),
    @types.Scalar::Timestamp(3600500000L),
    @types.Scalar::Timestamp(259201250000L),
    @types.Scalar::Null,
  ])
  // One cell that is not a whole number of the unit leaves its column the
  // stored numbers; a cell before the epoch converts like any other.
  let fractional = @io.read_spss(
    ".github/fixtures/spss/reference/pyrs_fractional.sav",
  )
  for name in ["half_day", "submicro_d", "submicro_t"] {
    assert_eq(fractional.get_column(name).dtype(), @types.DataType::Float)
  }
  assert_eq(fractional.get_column("neg_date").to_scalars(), [
    @types.Scalar::Date(-141429L),
    @types.Scalar::Date(-141428L),
    @types.Scalar::Date(-141427L),
    @types.Scalar::Null,
  ])
  assert_eq(
    fractional.get_column("neg_stamp").to_scalars()[0],
    @types.Scalar::Timestamp(-12219379200500000L),
  )
  // A long name, text past ASCII, strings wider than eight bytes, and the
  // zlib-compressed twin of the same table.
  let plain = @io.read_spss(".github/fixtures/spss/reference/pyrs_plain.sav")
  assert_eq(plain.shape(), (5, 8))
  assert_eq(plain.columns(), [
    "num", "s8", "s12", "s1", "s255", "s300", "a_very_long_column_name_here", "ünïcödé_nâmé",
  ])
  assert_eq(plain.get_column("num").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(-2.5),
    @types.Scalar::Float(3.0e300),
    @types.Scalar::Null,
    @types.Scalar::Float(0.0),
  ])
  assert_eq(plain.get_column("ünïcödé_nâmé").to_scalars(), [
    @types.Scalar::String("é"),
    @types.Scalar::String("日本"),
    @types.Scalar::String(""),
    @types.Scalar::String(""),
    @types.Scalar::String("ü"),
  ])
  // Trailing blanks are cut; leading blanks are text.
  assert_eq(plain.get_column("s8").to_scalars(), [
    @types.Scalar::String("12345678"),
    @types.Scalar::String("a"),
    @types.Scalar::String(""),
    @types.Scalar::String(""),
    @types.Scalar::String("  pad"),
  ])
  match plain.get_column("s255").to_scalars()[0] {
    @types.Scalar::String(cell) => assert_eq(cell.length(), 255)
    other => fail("the cell is no string: \{other}")
  }
  let zsav = @io.read_spss(".github/fixtures/spss/reference/pyrs_zsav.zsav")
  assert_eq(zsav.columns(), plain.columns())
  assert_eq(
    zsav.get_column("num").to_scalars(),
    plain.get_column("num").to_scalars(),
  )
  assert_eq(
    zsav.get_column("s300").to_scalars(),
    plain.get_column("s300").to_scalars(),
  )
  // Three hundred cases through a zlib stream, a date among them.
  let many = @io.read_spss(
    ".github/fixtures/spss/reference/pyrs_many_rows.zsav",
  )
  assert_eq(many.shape(), (300, 4))
  assert_eq(
    many.get_column("stamp").to_scalars()[4],
    @types.Scalar::Date(10961L),
  )
  assert_eq(
    many.get_column("label").to_scalars()[0],
    @types.Scalar::String("row 000"),
  )
  // The largest and smallest doubles and the infinities are numbers.
  let extremes = @io.read_spss(
    ".github/fixtures/spss/reference/pyrs_extremes_rows.sav",
  )
  assert_eq(extremes.shape(), (17, 1))
  assert_eq(extremes.get_column("v").dtype(), @types.DataType::Float)
  assert_eq(
    extremes.get_column("v").to_scalars()[6],
    @types.Scalar::Float(@double.infinity),
  )
  assert_eq(
    extremes.get_column("v").to_scalars()[7],
    @types.Scalar::Float(@double.neg_infinity),
  )
  // A declared missing value, a range and a string's missing spellings read
  // as null; value labels are not applied.
  let missing = @io.read_spss(
    ".github/fixtures/spss/reference/pyrs_missing.sav",
  )
  assert_eq(missing.shape(), (5, 6))
  assert_eq(missing.get_column("m3").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Float(4.0),
    @types.Scalar::Float(5.0),
  ])
  assert_eq(missing.get_column("mrangev").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Null,
    @types.Scalar::Float(9.0),
    @types.Scalar::Float(10.0),
    @types.Scalar::Null,
  ])
  assert_eq(missing.get_column("s3").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::String("a"),
    @types.Scalar::Null,
    @types.Scalar::String("b"),
    @types.Scalar::String(""),
  ])
  let labels = @io.read_spss(".github/fixtures/spss/reference/pyrs_labels.sav")
  assert_eq(labels.get_column("num").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(1.0),
  ])
  // The text decodes in the encoding the file declares.
  let latin = @io.read_spss(
    ".github/fixtures/spss/reference/synthetic_latin1.sav",
  )
  assert_eq(
    latin.get_column("t8").to_scalars()[0],
    @types.Scalar::String("é¥ÿð"),
  )
  let windows = @io.read_spss(
    ".github/fixtures/spss/reference/synthetic_windows1252.sav",
  )
  assert_eq(
    windows.get_column("t8").to_scalars()[0],
    @types.Scalar::String("€€"),
  )
  assert_eq(
    windows.get_column("t8").to_scalars()[1],
    @types.Scalar::String("“”"),
  )
  // Columns and no case read as the columns, empty.
  let empty = @io.read_spss(".github/fixtures/spss/reference/pyrs_norows.sav")
  assert_eq(empty.shape(), (0, 2))
  assert_eq(empty.columns(), ["a", "s"])
  assert_eq(empty.get_column("s").dtype(), @types.DataType::String)
}

///|
/// The error an entry raises; a frame answered instead fails the test.
fn spss_raised(
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
test "the SPSS entries raise the errors a caller meets" {
  // A path that cannot be read is the read's IoError.
  let missing = spss_raised(() => @io.read_spss("_build/no_such_spss.sav"))
  assert_true(missing is @types.DataError::IoError(_))
  // Bytes that open with no system file's signature.
  assert_eq(
    spss_raised(() => @io.parse_spss(b"not a system file, just some bytes")),
    @types.DataError::Unsupported(
      "spss: byte 0: the file signature is not a system file's",
    ),
  )
  // A system file inside an encrypted wrapper.
  assert_eq(
    spss_raised(() => {
      @io.read_spss(
        ".github/fixtures/spss/reference/synthetic_encrypted_wrapper.sav",
      )
    }),
    @types.DataError::Unsupported(
      "spss: byte 0: the file is a system file inside an encrypted wrapper, which this reader does not decrypt",
    ),
  )
  // A file declaring a character encoding this reader does not decode: the
  // windows-1252 file with its encoding record re-labelled.
  let whole = spss_bytes("synthetic_windows1252.sav")
  let edited : Array[Byte] = []
  for byte in whole {
    edited.push(byte)
  }
  let relabelled : Bytes = b"WINDOWS-1253"
  assert_eq(@utf8.decode(whole[408:420]) catch { _ => "" }, "WINDOWS-1252")
  for i in 0..<relabelled.length() {
    edited[408 + i] = relabelled[i]
  }
  assert_eq(
    spss_raised(() => @io.parse_spss(Bytes::from_array(edited))),
    @types.DataError::Unsupported(
      "spss: the file declares the character encoding WINDOWS-1253, which this reader does not decode",
    ),
  )
  // A file cut short inside its header, and a dictionary of no variable.
  let cut = spss_raised(() => @io.parse_spss(whole[0:100].to_owned()))
  assert_true(cut is @types.DataError::ParseError(_))
  let nocols = spss_raised(() => @io.parse_spss(spss_bytes("pyrs_nocols.sav")))
  assert_true(nocols is @types.DataError::ParseError(_))
  assert_eq(
    nocols
    .message()
    .has_suffix("the dictionary holds no variable, so a case has no size"),
    true,
  )
}
