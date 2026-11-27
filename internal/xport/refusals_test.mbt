// Blackbox tests of every refusal: one test per distinct message, each
// asserting the variant and the text. The reader's cases are a small valid
// file — one `Int` column, 960 bytes, whose observations start at byte 880 —
// with one part changed; the writer's are columns, or a height, the format
// cannot carry.

///|
/// A small valid file: one `Int` column of two observations. Its records
/// lie at bytes 0 to 879 and its data at 880.
fn small() -> Bytes raise @types.DataError {
  write_xport_bytes([@series.Series::from_ints("n", [1L, 2L])])
}

///|
/// `whole` cut to `length` bytes.
fn cut_to(whole : Bytes, length : Int32) -> Bytes {
  Bytes::makei(length, i => whole[i])
}

///|
/// `whole` with `replacement` laid over it from byte `at`.
fn patched(whole : Bytes, at : Int32, replacement : Bytes) -> Bytes {
  Bytes::makei(whole.length(), i => {
    if i >= at && i < at + replacement.length() {
      replacement[i - at]
    } else {
      whole[i]
    }
  })
}

///|
/// The error the reader raises for `bytes`; a table answered instead fails
/// the test.
fn read_error(bytes : Bytes) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(read_xport_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the bytes read back as a table")
    Err(e) => e
  }
}

///|
/// The text the reader's `ParseError` carries for `bytes`; another variant
/// fails the test.
fn parse_detail(bytes : Bytes) -> String raise {
  match read_error(bytes) {
    @types.DataError::ParseError(@types.ParseErrorDetail::Message(text)) => text
    other => fail("the reader raised \{other}, not a ParseError")
  }
}

///|
/// The text the reader's `Unsupported` carries for `bytes`; another
/// variant fails the test.
fn unsupported_detail(bytes : Bytes) -> String raise {
  match read_error(bytes) {
    @types.DataError::Unsupported(text) => text
    other => fail("the reader raised \{other}, not an Unsupported")
  }
}

///|
/// The error the writer raises for `columns` at `height`; a file answered
/// instead fails the test.
fn write_error(
  columns : Array[@series.Series],
  height : Int32,
) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(
    write_xport_bytes(columns, height~),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the columns were written")
    Err(e) => e
  }
}

///|
/// The text the writer's `InvalidOperation` carries for `columns` at
/// `height`; another variant fails the test.
fn invalid_detail(
  columns : Array[@series.Series],
  height : Int32,
) -> String raise {
  match write_error(columns, height) {
    @types.DataError::InvalidOperation(text) => text
    other => fail("the writer raised \{other}, not an InvalidOperation")
  }
}

///|
/// The text the writer's `Unsupported` carries for `columns`; another
/// variant fails the test.
fn unsupported_write(columns : Array[@series.Series]) -> String raise {
  match write_error(columns, columns[0].len()) {
    @types.DataError::Unsupported(text) => text
    other => fail("the writer raised \{other}, not an Unsupported")
  }
}

///|
/// A string holding one lone UTF-16 surrogate half, which no literal
/// spells: the code unit is assembled directly.
fn lone_surrogate(code_unit : Int32) -> String {
  let b = StringBuilder()
  b.write_char(Int32::unsafe_to_char(code_unit))
  b.to_string()
}

// ── The reader: records the file cuts short ──────────────────────────

///|
test "an empty file and a file shorter than a record are refused, naming byte 0" {
  assert_eq(
    parse_detail(b""),
    "xport: byte 0: the file ends at byte 0 inside the library header record (bytes 0 to 79)",
  )
  assert_eq(
    parse_detail(Bytes::makei(10, _ => b'x')),
    "xport: byte 0: the file ends at byte 10 inside the library header record (bytes 0 to 79)",
  )
}

///|
test "a file cut inside the library's, the member's or the NAMESTR header's records names the record" {
  let whole = small()
  assert_eq(whole.length(), 960)
  assert_eq(
    parse_detail(cut_to(whole, 120)),
    "xport: byte 80: the file ends at byte 120 inside the library's description records (bytes 80 to 239)",
  )
  assert_eq(
    parse_detail(cut_to(whole, 250)),
    "xport: byte 240: the file ends at byte 250 inside the member header record and the descriptor header record (bytes 240 to 399)",
  )
  assert_eq(
    parse_detail(cut_to(whole, 600)),
    "xport: byte 400: the file ends at byte 600 inside the member's description records and the NAMESTR header record (bytes 400 to 639)",
  )
}

// ── The reader: files that are not Version 5 transport files ─────────

///|
test "a library header record of another format is Unsupported, naming what it is" {
  let whole = small()
  assert_eq(
    unsupported_detail(
      patched(whole, 0, b"HEADER RECORD**COMPRESSED**TYPE(SASDATA)"),
    ),
    "xport: byte 0: the library header record marks a CPORT file, which is not a transport file",
  )
  assert_eq(
    unsupported_detail(patched(whole, 20, b"LIBV8   ")),
    "xport: byte 0: the library header record names LIBV8, a later version of the transport format, and this reader reads Version 5 files",
  )
  assert_eq(
    unsupported_detail(patched(whole, 20, b"LIBV9   ")),
    "xport: byte 0: the library header record names LIBV9, a later version of the transport format, and this reader reads Version 5 files",
  )
  assert_eq(
    unsupported_detail(patched(whole, 20, b"LIBRARX ")),
    "xport: byte 0: the library header record is not the transport format's, so the file is not an XPORT file",
  )
}

///|
test "a member or descriptor header record of another version or format is Unsupported" {
  let whole = small()
  assert_eq(
    unsupported_detail(patched(whole, 260, b"MEMBV8  ")),
    "xport: byte 240: the member header record names MEMBV8, a later version of the transport format, and this reader reads Version 5 files",
  )
  assert_eq(
    unsupported_detail(patched(whole, 260, b"MEMBEX  ")),
    "xport: byte 240: the member header record is not the transport format's",
  )
  // The record must also end in two blanks.
  assert_eq(
    unsupported_detail(patched(whole, 318, b" X")),
    "xport: byte 240: the member header record is not the transport format's",
  )
  assert_eq(
    unsupported_detail(patched(whole, 340, b"DSCPTV8 ")),
    "xport: byte 320: the descriptor header record names DSCPTV8, a later version of the transport format, and this reader reads Version 5 files",
  )
  assert_eq(
    unsupported_detail(patched(whole, 340, b"DSCRPTRX")),
    "xport: byte 320: the descriptor header record is not the transport format's",
  )
  assert_eq(
    unsupported_detail(patched(whole, 398, b"XX")),
    "xport: byte 320: the descriptor header record is not the transport format's",
  )
}

// ── The reader: bytes that contradict the layout ─────────────────────

///|
test "the record after the library header record must open as the layout spells" {
  assert_eq(
    parse_detail(patched(small(), 80, b"XSX     ")),
    "xport: byte 80: the record after the library header record does not open with \"SAS     SAS     SASLIB\"",
  )
}

///|
test "a NAMESTR length outside 88 to 140, or one not spelled in digits, is refused" {
  assert_eq(
    parse_detail(patched(small(), 308, b"0000000200")),
    "xport: byte 308: the NAMESTR length is spelled 200, and the layout's is 88 to 140",
  )
  assert_eq(
    parse_detail(patched(small(), 308, b"0000000087")),
    "xport: byte 308: the NAMESTR length is spelled 87, and the layout's is 88 to 140",
  )
  assert_eq(
    parse_detail(patched(small(), 317, b"X")),
    "xport: byte 317: a count is spelled here in digits, and this byte is not one",
  )
}

///|
test "the NAMESTR header record must open as the layout spells, and its count must be digits" {
  assert_eq(
    parse_detail(patched(small(), 572, b"X")),
    "xport: byte 560: the NAMESTR header record does not open with \"HEADER RECORD*******NAMESTR HEADER RECORD!!!!!!!\"",
  )
  assert_eq(
    parse_detail(patched(small(), 612, b"X")),
    "xport: byte 612: a count is spelled here in digits, and this byte is not one",
  )
}

///|
test "a count of NAMESTRs the file cannot hold is refused before one is read" {
  assert_eq(
    parse_detail(patched(small(), 608, b"0000000099")),
    "xport: byte 640: the file ends at byte 960 inside 99 NAMESTRs of 140 bytes and the observation header record (bytes 640 to 14639)",
  )
  // The largest count the ten digits spell cannot overflow into a small
  // area, either: 9999999999 namestrs of 140 bytes fill 1399999999920
  // bytes once rounded up to records, plus the 80-byte header record.
  assert_eq(
    parse_detail(patched(small(), 608, b"9999999999")),
    "xport: byte 640: the file ends at byte 960 inside 9999999999 NAMESTRs of 140 bytes and the observation header record (bytes 640 to 1400000000639)",
  )
}

///|
test "the observation header record must follow the NAMESTRs" {
  assert_eq(
    parse_detail(patched(small(), 800, b"X")),
    "xport: byte 800: the observation header record does not follow the NAMESTRs",
  )
}

///|
test "a NAMESTR naming a variable type that is neither numeric nor character is Unsupported" {
  assert_eq(
    unsupported_detail(patched(small(), 640, b"\x00\x03")),
    "xport: byte 640: a NAMESTR names variable type 3, which is neither numeric (1) nor character (2)",
  )
  assert_eq(
    unsupported_detail(patched(small(), 640, b"\xff\xff")),
    "xport: byte 640: a NAMESTR names variable type -1, which is neither numeric (1) nor character (2)",
  )
}

///|
test "a numeric variable must be 2 to 8 bytes wide" {
  assert_eq(
    parse_detail(patched(small(), 644, b"\x00\x09")),
    "xport: byte 644: the numeric variable \"n\" is 9 bytes wide, and a numeric variable is 2 to 8 bytes",
  )
  assert_eq(
    parse_detail(patched(small(), 644, b"\x00\x01")),
    "xport: byte 644: the numeric variable \"n\" is 1 bytes wide, and a numeric variable is 2 to 8 bytes",
  )
}

///|
test "a variable's name must be well-formed UTF-8" {
  assert_eq(
    parse_detail(patched(small(), 648, b"\xe9")),
    "xport: byte 648: a variable's name holds bytes that are not well-formed UTF-8",
  )
}

///|
test "a character variable must be at least 1 byte wide" {
  let text = write_xport_bytes([@series.Series::from_strings("s", ["a", "b"])])
  assert_eq(
    parse_detail(patched(text, 644, b"\x00\x00")),
    "xport: byte 644: the character variable \"s\" is 0 bytes wide, and a character variable is at least 1 byte",
  )
  assert_eq(
    parse_detail(patched(text, 644, b"\xff\xff")),
    "xport: byte 644: the character variable \"s\" is -1 bytes wide, and a character variable is at least 1 byte",
  )
}

///|
test "character data must be well-formed UTF-8, naming the cell's byte" {
  let text = write_xport_bytes([@series.Series::from_strings("s", ["a", "b"])])
  assert_eq(
    parse_detail(patched(text, 880, b"\xe9")),
    "xport: byte 880: the character variable \"s\" holds bytes that are not well-formed UTF-8",
  )
  assert_eq(
    parse_detail(patched(text, 881, b"\xff")),
    "xport: byte 881: the character variable \"s\" holds bytes that are not well-formed UTF-8",
  )
  // A multi-byte character cut short is refused at the byte it starts at.
  let wide = write_xport_bytes([@series.Series::from_strings("s", ["é", "b"])])
  assert_eq(
    parse_detail(patched(wide, 881, b"x")),
    "xport: byte 880: the character variable \"s\" holds bytes that are not well-formed UTF-8",
  )
  assert_eq(
    parse_detail(patched(wide, 881, b"\xff")),
    "xport: byte 880: the character variable \"s\" holds bytes that are not well-formed UTF-8",
  )
}

///|
test "observations must end on a record boundary" {
  assert_eq(
    parse_detail(cut_to(small(), 959)),
    "xport: byte 959: the observations end at byte 959, 79 bytes past the last 80-byte record boundary",
  )
  // A byte past the file's last record is trailing garbage, not padding.
  let whole = small()
  let longer = Bytes::makei(whole.length() + 1, i => {
    if i < whole.length() {
      whole[i]
    } else {
      b'x'
    }
  })
  assert_eq(
    parse_detail(longer),
    "xport: byte 961: the observations end at byte 961, 1 bytes past the last 80-byte record boundary",
  )
}

///|
test "a file with no variable holds nothing but padding after its header" {
  let none = write_xport_bytes([])
  assert_eq(none.length(), 720)
  // The valid file, then a record of padding with one byte that is not a
  // blank.
  let garbage = Bytes::makei(800, i => {
    if i < 720 {
      none[i]
    } else if i == 720 {
      b'X'
    } else {
      b' '
    }
  })
  assert_eq(
    parse_detail(garbage),
    "xport: byte 720: the file holds no variable, and a byte that is not a blank lies past its observation header record",
  )
}

///|
test "a byte that is not a blank in a partial observation is refused" {
  // Three `Int` columns make a row 24 bytes wide. Their three NAMESTRs
  // fill 480 bytes of records, so the observations start at byte 1200,
  // and one row leaves 56 bytes of the last record as padding.
  let one = write_xport_bytes([
    @series.Series::from_ints("a", [1L]),
    @series.Series::from_ints("b", [2L]),
    @series.Series::from_ints("c", [3L]),
  ])
  assert_eq(one.length(), 1280)
  assert_eq(
    parse_detail(patched(one, 1272, b"X")),
    "xport: byte 1272: a byte that is not a blank lies 0 bytes into the partial observation after the last whole one",
  )
  assert_eq(
    parse_detail(patched(one, 1273, b"X")),
    "xport: byte 1273: a byte that is not a blank lies 1 bytes into the partial observation after the last whole one",
  )
}

// ── The writer: lengths and the height ───────────────────────────────

///|
test "columns of different lengths, or a height that disagrees, raise LengthMismatch" {
  let one = @series.Series::from_ints("a", [1L])
  let two = @series.Series::from_ints("b", [1L, 2L])
  assert_eq(write_error([one, two], 1), @types.DataError::LengthMismatch(1, 2))
  assert_eq(write_error([two, one], 2), @types.DataError::LengthMismatch(2, 1))
  assert_eq(write_error([one], 3), @types.DataError::LengthMismatch(1, 3))
}

///|
test "a negative height, or a positive one for a table with no variable, is InvalidOperation" {
  assert_eq(
    invalid_detail([], -1),
    "xport: the writer was handed a height of -1, and a file declares no negative observation count",
  )
  assert_eq(
    invalid_detail([@series.Series::from_ints("a", [])], -5),
    "xport: the writer was handed a height of -5, and a file declares no negative observation count",
  )
  assert_eq(
    invalid_detail([], 3),
    "xport: a table with no variable has no place in a transport file for its 3 observations",
  )
}

// ── The writer: names ────────────────────────────────────────────────

///|
test "a name the format does not hold is InvalidOperation, naming the column" {
  let rule = "is not a name the transport format holds, which is one to eight ASCII letters, digits or underscores opening on a letter or an underscore"
  for name in ["abcdefghi", "", "1abc", "é", "a b", "a-b", "a.b", "ab\n"] {
    let columns = [
      @series.Series::rename(@series.Series::from_ints("x", [1L]), name),
    ]
    assert_eq(
      invalid_detail(columns, 1),
      "xport: cannot write column 1: \"\{name}\" \{rule}",
    )
  }
  // A name at the limit is held.
  let longest = [
    @series.Series::rename(@series.Series::from_ints("x", [1L]), "_1234567"),
  ]
  let (columns, _) = read_xport_frame(write_xport_bytes(longest))
  assert_eq(columns[0].0, "_1234567")
}

///|
test "two columns whose names differ only in case are one variable to the format" {
  let lower = @series.Series::from_ints("ab", [1L])
  let upper = @series.Series::from_ints("AB", [2L])
  let mixed = @series.Series::from_ints("aB", [3L])
  assert_eq(
    invalid_detail([lower, upper], 1),
    "xport: cannot write column 2: its name \"AB\" and column 1's name \"ab\" differ only in case, and the transport format holds them as one variable",
  )
  // The first column that repeats an earlier name is the one refused.
  assert_eq(
    invalid_detail([lower, mixed, upper], 1),
    "xport: cannot write column 2: its name \"aB\" and column 1's name \"ab\" differ only in case, and the transport format holds them as one variable",
  )
}

// ── The writer: cells the format cannot carry ────────────────────────

///|
test "an Int cell past 2^53 is InvalidOperation, naming the column and the row" {
  let columns = [@series.Series::from_ints("num", [1L, 9007199254740993L])]
  assert_eq(
    invalid_detail(columns, 2),
    "xport: cannot write column \"num\": the cell at row 2 holds 9007199254740993, which is past the 2^53 a numeric cell holds exactly",
  )
  let below = [@series.Series::from_ints("num", [-9007199254740993L])]
  assert_eq(
    invalid_detail(below, 1),
    "xport: cannot write column \"num\": the cell at row 1 holds -9007199254740993, which is past the 2^53 a numeric cell holds exactly",
  )
}

///|
test "an infinite Float cell, or one outside the magnitudes a cell holds, is InvalidOperation" {
  let infinite = [@series.Series::from_floats("ratio", [1.5, @double.infinity])]
  assert_eq(
    invalid_detail(infinite, 2),
    "xport: cannot write column \"ratio\": the cell at row 2 holds \{@double.infinity}, and a numeric cell spells no infinity",
  )
  let negative = [@series.Series::from_floats("ratio", [-@double.infinity])]
  assert_eq(
    invalid_detail(negative, 1),
    "xport: cannot write column \"ratio\": the cell at row 1 holds \{-@double.infinity}, and a numeric cell spells no infinity",
  )
  let small_value = [@series.Series::from_floats("ratio", [1.0, 1.0e-310])]
  assert_eq(
    invalid_detail(small_value, 2),
    "xport: cannot write column \"ratio\": the cell at row 2 holds \{1.0e-310}, and a numeric cell holds magnitudes from 16^-65 up to 16^63",
  )
  let large = [@series.Series::from_floats("ratio", [1.0e300])]
  assert_eq(
    invalid_detail(large, 1),
    "xport: cannot write column \"ratio\": the cell at row 1 holds \{1.0e300}, and a numeric cell holds magnitudes from 16^-65 up to 16^63",
  )
}

///|
test "a String cell over 200 bytes in UTF-8, or holding an unpaired surrogate, is InvalidOperation" {
  let wide = repeated("é", 101)
  let columns = [
    @series.Series::from_string_options("label", [Some("a"), Some(wide)]),
  ]
  assert_eq(
    invalid_detail(columns, 2),
    "xport: cannot write column \"label\": the String cell at row 2 is 202 bytes in UTF-8, and a character variable of the Version 5 transport format holds at most 200",
  )
  let at_limit = [
    @series.Series::from_string_options("label", [Some(repeated("é", 100))]),
  ]
  let (read, _) = read_xport_frame(write_xport_bytes(at_limit))
  assert_eq(
    read[0].1.to_scalars()[0],
    @types.Scalar::String(repeated("é", 100)),
  )
  let torn = [
    @series.Series::from_string_options("label", [
      Some("a"),
      Some(lone_surrogate(0xD800)),
    ]),
  ]
  assert_eq(
    invalid_detail(torn, 2),
    "xport: cannot write column \"label\": the String cell at row 2 holds an unpaired surrogate, which has no UTF-8 spelling",
  )
}

///|
test "a Date or Timestamp too far from the epoch, or past what a double holds exactly, is InvalidOperation" {
  let far_day = [
    @series.Series::from_date_options("day", [Some(9100000000000000000L)]),
  ]
  assert_eq(
    invalid_detail(far_day, 1),
    "xport: cannot write column \"day\": the cell at row 1 holds 9100000000000000000 days, too far from the epoch for a file to count",
  )
  let days = 9007199254740993L - 3653L
  let wide_day = [@series.Series::from_date_options("day", [Some(days)])]
  assert_eq(
    invalid_detail(wide_day, 1),
    "xport: cannot write column \"day\": the cell at row 1 holds \{days} days, which is past the 2^53 a numeric cell holds exactly",
  )
  let far_stamp = [
    @series.Series::from_timestamp_options("stamp", [Some(9100000000000000000L)]),
  ]
  assert_eq(
    invalid_detail(far_stamp, 1),
    "xport: cannot write column \"stamp\": the cell at row 1 holds 9100000000000000000 microseconds, too far from the epoch for a file to count",
  )
}

///|
test "a Timestamp whose microseconds are not a multiple of 15625 is InvalidOperation" {
  let columns = [@series.Series::from_timestamp_options("stamp", [Some(1L)])]
  assert_eq(
    invalid_detail(columns, 1),
    "xport: cannot write column \"stamp\": the cell at row 1 holds 1 microseconds, and only a multiple of 15625 is a number of seconds a double spells exactly",
  )
  // A millisecond is not a multiple of 15625 microseconds; a sixty-fourth
  // of a second is.
  let millisecond = [
    @series.Series::from_timestamp_options("stamp", [Some(789000L)]),
  ]
  assert_eq(
    invalid_detail(millisecond, 1),
    "xport: cannot write column \"stamp\": the cell at row 1 holds 789000 microseconds, and only a multiple of 15625 is a number of seconds a double spells exactly",
  )
  let sixty_fourth = [
    @series.Series::from_timestamp_options("stamp", [
      Some(781250L),
      Some(-15625L),
    ]),
  ]
  let (read, _) = read_xport_frame(write_xport_bytes(sixty_fourth))
  assert_eq(spelled(read[0].1.to_scalars()[0]), "Timestamp 781250")
}

///|
test "a column of dtype Duration, Decimal, List or Struct is Unsupported, naming the column and the dtype" {
  let duration = [@series.Series::from_duration_options("x", [Some(1L), None])]
  assert_eq(
    unsupported_write(duration),
    "xport: cannot write column \"x\": the transport format does not carry a column of dtype Duration",
  )
  let decimal = [
    @series.Series::from_scalars("x", [
      @types.Scalar::Decimal(@types.Dec128::of_int64(1L)),
    ]),
  ]
  assert_eq(
    unsupported_write(decimal),
    "xport: cannot write column \"x\": the transport format does not carry a column of dtype Decimal",
  )
  let list = [
    @series.Series::from_scalars("x", [
      @types.Scalar::List(@types.ListValue::ListValue([@types.Scalar::Int(1L)])),
    ]),
  ]
  assert_eq(
    unsupported_write(list),
    "xport: cannot write column \"x\": the transport format does not carry a column of dtype \{list[0].dtype().to_string()}",
  )
  let structure = [
    @series.Series::from_scalars("x", [
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          @types.FieldValue::FieldValue("a", @types.Scalar::Int(1L)),
        ]),
      ),
    ]),
  ]
  assert_eq(
    unsupported_write(structure),
    "xport: cannot write column \"x\": the transport format does not carry a column of dtype \{structure[0].dtype().to_string()}",
  )
}
