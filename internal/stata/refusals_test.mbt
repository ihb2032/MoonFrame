// Blackbox refusals: every message the writer raises for a caller's
// table and every message the reader raises for what it refuses by name,
// asserted by variant and by text; and, through the public entry point,
// the reader's located refusals for a file whose bytes contradict its
// layout — each crafted from a valid file or built by hand.

///|
/// A one-cell-per-entry `Int` column.
fn ints(name : String, cells : Array[Int64]) -> @series.Series {
  @series.Series::from_ints(name, cells)
}

///|
/// A `Float` column.
fn floats(name : String, cells : Array[Double]) -> @series.Series {
  @series.Series::from_floats(name, cells)
}

///|
/// A column of one dtype from its scalar cells.
fn scalars(
  name : String,
  cells : Array[@types.Scalar],
  dtype : @types.DataType,
) -> @series.Series raise @types.DataError {
  @series.Series::from_scalars(name, cells, dtype~)
}

///|
/// A string holding one lone UTF-16 surrogate half, which no literal
/// spells: the code unit is assembled directly.
fn lone_surrogate(code_unit : Int32) -> String {
  let b = StringBuilder()
  b.write_char(Int32::unsafe_to_char(code_unit))
  b.to_string()
}

///|
/// The error the reader raises for `bytes`; a table answered instead
/// fails the test.
fn read_error(bytes : Bytes) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(read_stata_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the bytes read as a dataset")
    Err(e) => e
  }
}

///|
/// The error the writer raises for a table; bytes answered instead fail
/// the test.
fn write_error(
  columns : Array[@series.Series],
  height : Int32,
) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(
    write_stata_bytes(columns, height~),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the table was written")
    Err(e) => e
  }
}

///|
/// An `InvalidOperation` with its text.
fn refused(text : String) -> @types.DataError {
  @types.DataError::InvalidOperation(text)
}

///|
/// Where `needle` begins in `haystack` at or after `from`; absent fails.
fn locate(haystack : Bytes, needle : Bytes, from : Int32) -> Int32 raise {
  let limit = haystack.length() - needle.length()
  let mut at = from
  while at <= limit {
    let mut same = true
    for i in 0..<needle.length() {
      if haystack[at + i] != needle[i] {
        same = false
      }
    }
    if same {
      return at
    }
    at += 1
  }
  fail("no such bytes in the file")
}

///|
/// `whole` with the byte at `at` replaced.
fn patched(whole : Bytes, at : Int32, value : Int32) -> Bytes {
  Bytes::makei(whole.length(), i => {
    if i == at {
      value.to_byte()
    } else {
      whole[i]
    }
  })
}

///|
/// `whole` with a little-endian integer of `width` bytes written at
/// `at`.
fn patched_le(
  whole : Bytes,
  at : Int32,
  value : UInt64,
  width : Int32,
) -> Bytes {
  Bytes::makei(whole.length(), i => {
    let offset = i - at
    if offset >= 0 && offset < width {
      ((value >> (offset * 8)) & 0xFFUL).to_byte()
    } else {
      whole[i]
    }
  })
}

///|
/// A binary header of release 113 for `nvar` variables and `nobs`
/// observations, its descriptor blocks left out, followed by `tail`.
fn binary_header(nvar : Int32, nobs : Int32, tail : Bytes) -> Bytes {
  let out : Array[Byte] = [113, 2, 1, 0, nvar.to_byte(), 0, 0, 0, 0, 0]
  out[6] = (nobs & 0xFF).to_byte()
  out[7] = ((nobs >> 8) & 0xFF).to_byte()
  out[8] = ((nobs >> 16) & 0xFF).to_byte()
  out[9] = ((nobs >> 24) & 0xFF).to_byte()
  for _ in 0..<99 {
    out.push((0).to_byte())
  }
  for b in tail {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A valid three-row file with a long-string column, for the files the
/// long-string refusals are crafted from.
fn strl_file() -> Bytes raise @types.DataError {
  let notes = scalars(
    "notes",
    [
      @types.Scalar::String(String::make(2200, 'x')),
      @types.Scalar::String("a"),
      @types.Scalar::String("a"),
    ],
    @types.DataType::String,
  )
  let brief = @series.Series::from_strings("brief", ["x", "y", "z"])
  write_stata_bytes([notes, brief], height=3)
}

// ── the writer: the table it is handed ──────────────────────────────

///|
test "the writer refuses columns of different lengths" {
  let columns : Array[@series.Series] = [
    ints("num", [1L, 2L, 3L]),
    @series.Series::from_strings("label", ["a", "b"]),
  ]
  assert_eq(write_error(columns, 3), @types.DataError::LengthMismatch(3, 2))
}

///|
test "the writer refuses a height that disagrees with the columns" {
  assert_eq(
    write_error([ints("num", [1L, 2L, 3L])], 5),
    @types.DataError::LengthMismatch(3, 5),
  )
}

///|
test "the writer refuses a negative height" {
  assert_eq(
    write_error([], -1),
    refused(
      "the stata writer was handed a height of -1, and a dataset declares no negative observation count",
    ),
  )
}

///|
test "the writer refuses more columns than the release carries" {
  let columns = Array::makei(32768, i => ints("c\{i}", []))
  assert_eq(
    write_error(columns, 0),
    refused(
      "the stata writer was handed 32768 columns, and release 118 carries at most 32,767",
    ),
  )
}

// ── the writer: names ───────────────────────────────────────────────

///|
/// The error of writing one one-row `Int` column under `name`.
fn name_error(name : String) -> @types.DataError raise {
  write_error([ints(name, [1L])], 1)
}

///|
test "the writer refuses an empty name" {
  assert_eq(
    name_error(""),
    refused(
      "the column name \"\" is empty; a Stata variable name has one to 32 characters",
    ),
  )
}

///|
test "the writer refuses a character outside the name's alphabet, naming the code unit" {
  assert_eq(
    name_error("bad-name"),
    refused(
      "the column name \"bad-name\" holds U+002D, outside the letters, digits and underscore a Stata variable name allows",
    ),
  )
  assert_eq(
    name_error("café"),
    refused(
      "the column name \"café\" holds U+00E9, outside the letters, digits and underscore a Stata variable name allows",
    ),
  )
  assert_eq(
    name_error("x y"),
    refused(
      "the column name \"x y\" holds U+0020, outside the letters, digits and underscore a Stata variable name allows",
    ),
  )
}

///|
test "the writer refuses a name longer than 32 characters" {
  let long = "abcdefghijklmnopqrstuvwxyz1234567"
  assert_eq(long.length(), 33)
  assert_eq(
    name_error(long),
    refused(
      "the column name \"abcdefghijklmnopqrstuvwxyz1234567\" is 33 characters long; a Stata variable name has at most 32",
    ),
  )
}

///|
test "the writer refuses a name that opens with a digit" {
  assert_eq(
    name_error("1x"),
    refused(
      "the column name \"1x\" opens with the digit 1; a Stata variable name opens with a letter or the underscore",
    ),
  )
}

///|
test "the writer refuses a reserved word" {
  assert_eq(
    name_error("byte"),
    refused(
      "the column name \"byte\" is a word the Stata language reserves, which no variable name spells",
    ),
  )
  // The list is spelled, not derived: its case is its own.
  assert_eq(
    name_error("strL"),
    refused(
      "the column name \"strL\" is a word the Stata language reserves, which no variable name spells",
    ),
  )
  assert_eq(
    name_error("NULL"),
    refused(
      "the column name \"NULL\" is a word the Stata language reserves, which no variable name spells",
    ),
  )
  assert_eq(
    name_error("with"),
    refused(
      "the column name \"with\" is a word the Stata language reserves, which no variable name spells",
    ),
  )
}

///|
test "the writer refuses a name an earlier column already holds" {
  let columns : Array[@series.Series] = [ints("num", [1L]), ints("num", [2L])]
  assert_eq(
    write_error(columns, 1),
    refused(
      "the column name \"num\" is already column 1's; a dataset's variable names are distinct",
    ),
  )
}

// ── the writer: cells ───────────────────────────────────────────────

///|
test "the writer refuses an Int cell the double storage cannot hold exactly" {
  let wide = ints("wide", [1L, 9223372036854775807L])
  assert_eq(
    write_error([wide], 2),
    refused(
      "cannot write column \"wide\": the Int cell at row 2 (9223372036854775807) is too large for the format's double storage to hold exactly",
    ),
  )
}

///|
test "the writer refuses an infinite Float cell" {
  assert_eq(
    write_error([floats("ratio", [1.0, 1.0 / 0.0])], 2),
    refused(
      "cannot write column \"ratio\": the Float cell at row 2 is infinite, and the format has no infinity",
    ),
  )
  assert_eq(
    write_error([floats("ratio", [-1.0 / 0.0])], 1),
    refused(
      "cannot write column \"ratio\": the Float cell at row 1 is infinite, and the format has no infinity",
    ),
  )
}

///|
test "the writer refuses a finite Float cell past the double storage's valid range" {
  assert_eq(
    write_error([floats("ratio", [1.7976931348623157e308])], 1),
    refused(
      "cannot write column \"ratio\": the Float cell at row 1 lies past the double storage's valid range, whose top the missing codes occupy",
    ),
  )
}

///|
test "the writer refuses a Date cell past the long storage's valid range" {
  let day = scalars(
    "day",
    [@types.Scalar::Date(0L), @types.Scalar::Date(2147483621L)],
    @types.DataType::Date,
  )
  assert_eq(
    write_error([day], 2),
    refused(
      "cannot write column \"day\": the Date cell at row 2 (day 2147483621 since 1970-01-01) leaves the long storage's valid range",
    ),
  )
}

///|
test "the writer refuses a Timestamp cell that is not whole milliseconds" {
  let stamp = scalars(
    "stamp",
    [@types.Scalar::Timestamp(0L), @types.Scalar::Timestamp(1001L)],
    @types.DataType::Timestamp,
  )
  assert_eq(
    write_error([stamp], 2),
    refused(
      "cannot write column \"stamp\": the Timestamp cell at row 2 (1001 microseconds since 1970-01-01) is not a whole number of milliseconds",
    ),
  )
}

///|
test "the writer refuses a Timestamp cell too far from the epoch to hold exactly" {
  // Whole milliseconds past 2^53, at a count the double rounds.
  let far = 9007199254741001000L
  let stamp = scalars(
    "stamp",
    [@types.Scalar::Timestamp(0L), @types.Scalar::Timestamp(far)],
    @types.DataType::Timestamp,
  )
  assert_eq(
    write_error([stamp], 2),
    refused(
      "cannot write column \"stamp\": the Timestamp cell at row 2 (9007199254741001000 microseconds since 1970-01-01) is too far from the epoch for the double storage to hold its milliseconds exactly",
    ),
  )
}

///|
test "the writer refuses a string cell holding an unpaired surrogate" {
  let label = scalars(
    "label",
    [
      @types.Scalar::String("plain"),
      @types.Scalar::String(lone_surrogate(0xD800)),
    ],
    @types.DataType::String,
  )
  assert_eq(
    write_error([label], 2),
    refused(
      "cannot write column \"label\": the String cell at row 2 holds an unpaired UTF-16 surrogate, which has no UTF-8 spelling",
    ),
  )
  // A low half with no high half before it is unpaired the same way.
  let low = scalars(
    "label",
    [
      @types.Scalar::String("plain"),
      @types.Scalar::String("😀"),
      @types.Scalar::String(lone_surrogate(0xDC00)),
    ],
    @types.DataType::String,
  )
  assert_eq(
    write_error([low], 3),
    refused(
      "cannot write column \"label\": the String cell at row 3 holds an unpaired UTF-16 surrogate, which has no UTF-8 spelling",
    ),
  )
}

///|
test "the writer refuses a Duration, Decimal, List or Struct column by name" {
  let columns : Array[@series.Series] = [
    scalars("d", [], @types.DataType::Duration),
    scalars("x", [], @types.DataType::Decimal),
    scalars("l", [], @types.DataType::List(@types.DataType::Int)),
    scalars(
      "s",
      [],
      @types.DataType::Struct(
        @types.Schema::Schema([@types.Field::Field("a", @types.DataType::Int)]),
      ),
    ),
  ]
  assert_eq(
    write_error([columns[0]], 0),
    @types.DataError::Unsupported(
      "stata cannot carry column \"d\" of dtype Duration",
    ),
  )
  assert_eq(
    write_error([columns[1]], 0),
    @types.DataError::Unsupported(
      "stata cannot carry column \"x\" of dtype Decimal",
    ),
  )
  assert_eq(
    write_error([columns[2]], 0),
    @types.DataError::Unsupported(
      "stata cannot carry column \"l\" of dtype List(Int)",
    ),
  )
  assert_eq(
    write_error([columns[3]], 0),
    @types.DataError::Unsupported(
      "stata cannot carry column \"s\" of dtype Struct(a: Int)",
    ),
  )
}

// ── the reader: refusals by name ────────────────────────────────────

///|
test "the reader refuses a release it does not read, naming the release" {
  assert_eq(
    read_error(b"\x00"),
    @types.DataError::Unsupported(
      "the file declares release 0; this reader reads releases 113 to 119",
    ),
  )
  assert_eq(
    read_error(b"\x80"),
    @types.DataError::Unsupported(
      "the file declares release 128; this reader reads releases 113 to 119",
    ),
  )
  assert_eq(
    read_error(b"\x75"),
    @types.DataError::Unsupported(
      "the file declares release 117; this reader reads releases 113 to 119",
    ),
  )
  // The release field of a tagged file: past the range, and not a
  // number at all.
  let whole = strl_file()
  let release_at = locate(whole, b"<release>", 0) + 9
  assert_eq(
    read_error(
      Bytes::makei(whole.length(), i => {
        if i == release_at {
          b"9"[0]
        } else {
          whole[i]
        }
      }),
    ),
    @types.DataError::Unsupported(
      "the file declares release 918; this reader reads releases 113 to 119",
    ),
  )
  assert_eq(
    read_error(
      Bytes::makei(whole.length(), i => {
        if i == release_at + 2 {
          b"x"[0]
        } else {
          whole[i]
        }
      }),
    ),
    @types.DataError::Unsupported(
      "the file declares release 11x; this reader reads releases 113 to 119",
    ),
  )
}

///|
test "the reader refuses a type code it does not read, naming the code" {
  // The header is checked to hold a variable's descriptor bytes before
  // any of them is read: 162 for one, the first its type byte, here 0.
  let code = Bytes::makei(162, _ => (0).to_byte())
  assert_eq(
    read_error(binary_header(1, 0, code)),
    @types.DataError::Unsupported(
      "the variable type code 0 names no storage this reader reads",
    ),
  )
  // The first variable's type code sits right after the section's tag.
  let whole = strl_file()
  let types_at = locate(whole, b"<variable_types>", 0) + 16
  assert_eq(
    read_error(patched(whole, types_at + 1, 0x9C)),
    @types.DataError::Unsupported(
      "the variable type code 39936 names no storage this reader reads",
    ),
  )
}

///|
test "the reader refuses a binary long string, naming the row and column" {
  let whole = strl_file()
  // The first record's kind byte: `GSO`, four bytes of variable, eight of
  // observation.
  let kind_at = locate(whole, b"GSO", 0) + 15
  assert_eq(
    read_error(patched(whole, kind_at, 129)),
    @types.DataError::Unsupported(
      "row 1, column \"notes\": a binary strL, which reads as no string",
    ),
  )
}

///|
test "the reader refuses a long string of a kind it does not know, naming row, column and kind" {
  let whole = strl_file()
  let kind_at = locate(whole, b"GSO", 0) + 15
  assert_eq(
    read_error(patched(whole, kind_at, 131)),
    @types.DataError::Unsupported(
      "row 1, column \"notes\": a strL of kind 131, which reads as no string",
    ),
  )
}

// ── the reader: a file that contradicts its layout ──────────────────

///|
test "a file that ends before its first byte refuses, naming the offset" {
  assert_eq(
    read_error(b""),
    problem(
      "stata: the file ends at byte 0 before the 1 bytes needed at offset 0",
    ),
  )
  assert_eq(
    read_error(b"<stata_dta><header>"),
    problem(
      "stata: the file ends at byte 19 before the 28 bytes needed at offset 0",
    ),
  )
}

///|
test "a negative length refuses, naming the offset" {
  // A zero-variable header still carries its two-byte sort list; then
  // one expansion field of type 1 whose four-byte length is -1.
  let tail : Array[Byte] = [0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF]
  assert_eq(
    read_error(binary_header(0, 0, Bytes::from_array(tail))),
    problem("stata: a length of -1 bytes at offset 116 is negative"),
  )
}

///|
test "a wrong tag refuses, naming the tag and the offset" {
  let whole = strl_file()
  let at = locate(whole, b"</byteorder><K>", 0)
  assert_eq(
    read_error(patched(whole, at + 12, 'L'.to_int())),
    problem("stata: expected the tag </byteorder><K> at offset \{at}"),
  )
}

///|
test "a byte order that is neither LSF nor MSF refuses, naming the offset" {
  let whole = strl_file()
  let at = locate(whole, b"<byteorder>", 0) + 11
  assert_eq(
    read_error(
      Bytes::makei(whole.length(), i => if i == at { b"X"[0] } else { whole[i] }),
    ),
    problem(
      "stata: the byte order field at offset \{at} reads neither LSF nor MSF",
    ),
  )
}

///|
test "a map entry past the file refuses, naming the offset" {
  let whole = strl_file()
  let entries_at = locate(whole, b"<map>", 0) + 5
  // The tenth entry places the long-string section.
  let far = whole.length().to_uint64() + 5UL
  assert_eq(
    read_error(patched_le(whole, entries_at + 8 * 10, far, 8)),
    problem(
      "stata: the map places a section at offset \{far}, past the file's \{whole.length()} bytes",
    ),
  )
}

///|
test "a variable count the file cannot hold refuses, naming the counts" {
  let whole = strl_file()
  let at = locate(whole, b"</byteorder><K>", 0) + 15
  let out = patched_le(whole, at, 60000UL, 2)
  let pos = locate(whole, b"</map>", 0)
  assert_eq(
    read_error(out),
    problem(
      "stata: the header declares 60000 entries of 188 bytes at offset \{pos}, and only \{whole.length() - pos} bytes remain",
    ),
  )
}

///|
test "an observation count past a frame's height refuses, naming the count" {
  let whole = strl_file()
  let at = locate(whole, b"</K><N>", 0) + 7
  assert_eq(
    read_error(patched_le(whole, at, 2147483648UL, 8)),
    problem(
      "stata: the file declares 2147483648 observations, past a frame's own height",
    ),
  )
}

///|
test "a data block larger than the file refuses, naming the counts" {
  let whole = strl_file()
  let at = locate(whole, b"</K><N>", 0) + 7
  let out = patched_le(whole, at, 400UL, 8)
  let data_at = locate(whole, b"<data>", 0) + 6
  assert_eq(
    read_error(out),
    problem(
      "stata: the data block at offset \{data_at} declares 400 observations of 9 bytes, and only \{whole.length() - data_at} bytes remain",
    ),
  )
}

///|
test "a tagged file whose observation count underruns its data refuses at the data's closing tag" {
  // Three rows are in the file and the header says two: the tag that
  // closes the data block is not where two rows would end it.
  let whole = strl_file()
  let at = locate(whole, b"</K><N>", 0) + 7
  let out = patched_le(whole, at, 2UL, 8)
  let data_at = locate(whole, b"<data>", 0) + 6
  assert_eq(
    read_error(out),
    problem("stata: expected the tag </data> at offset \{data_at + 18}"),
  )
}

///|
test "a long-string key with no record refuses, naming the row and column" {
  let whole = strl_file()
  // The first cell of the first column names the record of variable 1
  // and row 1, key 65537; a byte put into its lowest position names a
  // record the table does not hold.
  let at = locate(whole, b"<data>", 0) + 6
  assert_eq(
    read_error(patched(whole, at, 0x7F)),
    problem(
      "stata: row 1, column \"notes\": the long-string key 65663 names no record in the table",
    ),
  )
}

///|
test "a long-string record without its terminator refuses, naming the offset" {
  let whole = strl_file()
  let record = locate(whole, b"GSO", 0)
  // `GSO`, four bytes of variable and eight of observation, a kind byte,
  // then the four-byte length; the text begins after it and ends in the
  // terminator the length counts.
  let length = whole[record + 16].to_int() |
    (whole[record + 17].to_int() << 8) |
    (whole[record + 18].to_int() << 16)
  let last = record + 20 + length - 1
  assert_eq(whole[last].to_int(), 0)
  assert_eq(
    read_error(patched(whole, last, 'x'.to_int())),
    problem(
      "stata: offset \{last}: a long-string record's text does not end in NUL",
    ),
  )
}
