// Whitebox tests of the reader's own helpers: the checked reads, the
// signature table, the header's derived sizes, the character-set codes,
// the display-format families and their conversions, and the text cells.

///|
/// The text of the `ParseError` that running `action` raises; no error,
/// or another variant, fails the test.
fn[T] detail(action : () -> T raise @types.DataError) -> String raise {
  let outcome : Result[T, @types.DataError] = Ok(action()) catch { e => Err(e) }
  match outcome {
    Ok(_) => fail("no error was raised")
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(text))) =>
      text
    Err(other) => fail("the reader raised \{other}, not a ParseError")
  }
}

///|
/// A header of the given layout and character set, for the helpers that
/// take one. The character set is spelled by its code: 20 is UTF-8.
fn header_of(wide : Bool, little : Bool, code : Int32) -> Header raise {
  Header::{
    wide,
    little,
    charset: charset_of(code),
    header_length: 1024L,
    page_length: 4096L,
    pages: 1L,
  }
}

///|
/// A signature's kind as a number, so two can be compared.
fn signature_tag(kind : Signature) -> Int32 {
  match kind {
    RowSize => 1
    ColumnSize => 2
    Counts => 3
    ColumnText => 4
    ColumnName => 5
    ColumnAttributes => 6
    ColumnFormat => 7
    ColumnList => 8
    Ignored => 9
    Unknown => 0
  }
}

///|
/// A family as a number, so two can be compared.
fn family_tag(family : Family) -> Int32 {
  match family {
    Number => 0
    Days => 1
    Clock => 2
    Instant => 3
  }
}

///|
/// Positive infinity, and a value that is not a number.
let infinity : Double = 1.0 / 0.0

///|
let not_a_number : Double = 0.0 / 0.0

///|
test "unsigned integers are read in either byte order, at every width" {
  let bytes = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  assert_eq(uint_at(bytes, 0L, 2L, true), 0x0201UL)
  assert_eq(uint_at(bytes, 0L, 2L, false), 0x0102UL)
  assert_eq(uint_at(bytes, 1L, 4L, true), 0x05040302UL)
  assert_eq(uint_at(bytes, 1L, 4L, false), 0x02030405UL)
  assert_eq(uint_at(bytes, 0L, 8L, true), 0x0807060504030201UL)
  assert_eq(uint_at(bytes, 0L, 8L, false), 0x0102030405060708UL)
  assert_eq(byte_at(bytes, 0L), 1)
  assert_eq(byte_at(bytes, 7L), 8)
  assert_eq(byte_at(b"\x00\xff", 0L), 0)
  assert_eq(byte_at(b"\x00\xff", 1L), 255)
}

///|
test "a read past the bytes refuses, naming the byte and the field" {
  let bytes = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  assert_eq(
    detail(() => uint_at(bytes, 6L, 4L, true)),
    "sas7bdat: byte 6: the file ends at byte 8 inside an unsigned integer (bytes 6 to 9)",
  )
  assert_eq(
    detail(() => byte_at(bytes, 8L)),
    "sas7bdat: byte 8: the file ends at byte 8 inside a byte (bytes 8 to 8)",
  )
  assert_eq(
    detail(() => need(bytes, -1L, 1L, "a field")),
    "sas7bdat: byte -1: the file ends at byte 8 inside a field (bytes -1 to -1)",
  )
  assert_eq(
    detail(() => need(bytes, 3L, -1L, "a field")),
    "sas7bdat: byte 3: the file ends at byte 8 inside a field (bytes 3 to 1)",
  )
  // A need the bytes answer raises nothing.
  let answered : Result[_, @types.DataError] = Ok(
    need(bytes, 8L, 0L, "a field"),
  ) catch {
    e => Err(e)
  }
  assert_true(answered is Ok(_))
  assert_eq(byte_at(b"\x02", 0L), 2)
}

///|
test "the header's sizes follow its layout" {
  let wide = header_of(true, true, 20)
  assert_eq(wide.word(), 8L)
  assert_eq(wide.pointer(), 24L)
  assert_eq(wide.lead(), 32L)
  let narrow = header_of(false, false, 29)
  assert_eq(narrow.word(), 4L)
  assert_eq(narrow.pointer(), 12L)
  assert_eq(narrow.lead(), 16L)
}

///|
test "a hex digit has its value" {
  assert_eq(hex_digit("0123456789", 0), 0)
  assert_eq(hex_digit("0123456789", 9), 9)
  assert_eq(hex_digit("abcdef", 0), 10)
  assert_eq(hex_digit("abcdef", 5), 15)
}

///|

///|
test "the codes the reference reader's table names are all accounted for" {
  // Every one is either decoded or named in the refusal; none is both.
  let table : Array[Int32] = []
  for (code, _name) in charsets_not_decoded {
    table.push(code)
  }
  for page in charset_pages {
    table.push(page.code)
  }
  table.push(20)
  assert_eq(table.length(), 65)
  let sorted = table.copy()
  sorted.sort()
  let mut seen = -1
  for code in sorted {
    assert_true(code > seen)
    seen = code
  }
}

///|
test "every signature spelling names its subheader, in either byte order" {
  // 64-bit files: the row-size and column-count signatures in either
  // half or followed by FF FF FB FE; the others with their telling byte
  // last (little-endian file) or first (big-endian one).
  let wide : ReadOnlyArray[(UInt64, Signature)] = [
    (0xF7F7F7F700000000UL, Signature::RowSize),
    (0x00000000F7F7F7F7UL, Signature::RowSize),
    (0xFEFBFFFFF7F7F7F7UL, Signature::RowSize),
    (0xF6F6F6F600000000UL, Signature::ColumnSize),
    (0x00000000F6F6F6F6UL, Signature::ColumnSize),
    (0xFEFBFFFFF6F6F6F6UL, Signature::ColumnSize),
    (0xFFFFFFFFFFFFFC00UL, Signature::Counts),
    (0x00FCFFFFFFFFFFFFUL, Signature::Counts),
    (0xFFFFFFFFFFFFFFFDUL, Signature::ColumnText),
    (0xFDFFFFFFFFFFFFFFUL, Signature::ColumnText),
    (0xFFFFFFFFFFFFFFFFUL, Signature::ColumnName),
    (0xFFFFFFFFFFFFFFFCUL, Signature::ColumnAttributes),
    (0xFCFFFFFFFFFFFFFFUL, Signature::ColumnAttributes),
    (0xFFFFFFFFFFFFFBFEUL, Signature::ColumnFormat),
    (0xFEFBFFFFFFFFFFFFUL, Signature::ColumnFormat),
    (0xFFFFFFFFFFFFFFFEUL, Signature::ColumnList),
    (0xFEFFFFFFFFFFFFFFUL, Signature::ColumnList),
    (0xFFFFFFFFFFFFFFF8UL, Signature::Ignored),
    (0xFFFFFFFFFFFFFFF9UL, Signature::Ignored),
    (0xFFFFFFFFFFFFFFFAUL, Signature::Ignored),
    (0xF8FFFFFFFFFFFFFFUL, Signature::Ignored),
    (0xFAFFFFFFFFFFFFFFUL, Signature::Ignored),
    (0xDEADBEEF00000000UL, Signature::Unknown),
  ]
  for (spelling, kind) in wide {
    assert_eq(
      signature_tag(signature_kind(spelling, true)),
      signature_tag(kind),
    )
  }
  let narrow : ReadOnlyArray[(UInt64, Signature)] = [
    (0xF7F7F7F7UL, Signature::RowSize),
    (0xF6F6F6F6UL, Signature::ColumnSize),
    (0xFFFFFC00UL, Signature::Counts),
    (0x00FCFFFFUL, Signature::Counts),
    (0xFFFFFFFDUL, Signature::ColumnText),
    (0xFDFFFFFFUL, Signature::ColumnText),
    (0xFFFFFFFFUL, Signature::ColumnName),
    (0xFFFFFFFCUL, Signature::ColumnAttributes),
    (0xFCFFFFFFUL, Signature::ColumnAttributes),
    (0xFFFFFBFEUL, Signature::ColumnFormat),
    (0xFEFBFFFFUL, Signature::ColumnFormat),
    (0xFFFFFFFEUL, Signature::ColumnList),
    (0xFEFFFFFFUL, Signature::ColumnList),
    (0xFFFFFFF8UL, Signature::Ignored),
    (0xFFFFFFF9UL, Signature::Ignored),
    (0xFFFFFFFAUL, Signature::Ignored),
    (0xF8FFFFFFUL, Signature::Ignored),
    (0xFAFFFFFFUL, Signature::Ignored),
    (0xDEADBEEFUL, Signature::Unknown),
  ]
  for (spelling, kind) in narrow {
    assert_eq(
      signature_tag(signature_kind(spelling, false)),
      signature_tag(kind),
    )
  }
}

///|
test "the four bytes at an offset are shown as they lie" {
  assert_eq(hex_at(b"\xde\xad\xbe\xef", 0L), "deadbeef")
  assert_eq(hex_at(b"??\x01\x20\xf0\x0f", 2L), "0120f00f")
}

///|
test "every display format names its family, and nothing else does" {
  for format in date_formats {
    assert_eq(family_tag(family_of(format)), 1)
  }
  for format in time_formats {
    assert_eq(family_tag(family_of(format)), 2)
  }
  for format in datetime_formats {
    assert_eq(family_tag(family_of(format)), 3)
  }
  let others : ReadOnlyArray[String] = [
    "", "$", "$CHAR", "BEST", "COMMA", "F", "F8.2", "date", "Date", "DATETIMEX",
    "DATE9", "WEEK", "WEEKU", "WEEKW", "MMSSX", "DTDATEX", "E8601D",
  ]
  for format in others {
    assert_eq(family_tag(family_of(format)), 0)
  }
  assert_eq(named(["a", "b"], "b"), true)
  assert_eq(named(["a"], "b"), false)
}

///|
test "a day count moves to the Unix epoch, with the calendar's two days put back" {
  assert_eq(gregorian_day(0L), -3653L)
  assert_eq(gregorian_day(-1L), -3654L)
  assert_eq(gregorian_day(3653L), 0L)
  assert_eq(gregorian_day(745152L), 741499L)
  assert_eq(gregorian_day(745153L), 741500L)
  assert_eq(gregorian_day(745154L), 741502L)
  assert_eq(gregorian_day(2206122L), 2202470L)
  assert_eq(gregorian_day(2206123L), 2202472L)
}

///|
test "a whole number of days converts; a fraction, an infinity or a count too large does not" {
  assert_eq(to_day(1.0), Ok(-3652L))
  assert_eq(to_day(0.0), Ok(-3653L))
  assert_eq(to_day(-0.0), Ok(-3653L))
  assert_eq(to_day(9007199254740992.0), Ok(9007199254740992L + 2L - 3653L))
  assert_eq(to_day(1.5), Err(()))
  assert_eq(to_day(-0.5), Err(()))
  assert_eq(to_day(infinity), Err(()))
  assert_eq(to_day(-infinity), Err(()))
  assert_eq(to_day(1.0e300), Err(()))
  assert_eq(to_day(-9000000000000000000.0), Ok(-9000000000000003653L))
  assert_eq(to_day(-9000000001000000000.0), Err(()))
}

///|
test "a second count converts to whole microseconds only when nothing is rounded away" {
  assert_eq(whole_micros(0.0), Ok(0L))
  assert_eq(whole_micros(12345.678), Ok(12345678000L))
  assert_eq(whole_micros(0.5), Ok(500000L))
  assert_eq(whole_micros(-2.5), Ok(-2500000L))
  assert_eq(whole_micros(1.0e-9), Err(()))
  assert_eq(whole_micros(0.1), Ok(100000L))
  assert_eq(whole_micros(infinity), Err(()))
  assert_eq(whole_micros(-infinity), Err(()))
  assert_eq(whole_micros(1.0e13), Err(()))
  assert_eq(whole_micros(-9000000000000000000.0), Err(()))
}

///|
test "a datetime moves to the Unix epoch, with the calendar's two days put back" {
  let epoch = -315619200000000L
  assert_eq(to_instant(0.0), Ok(epoch))
  assert_eq(to_instant(1.0), Ok(epoch + 1000000L))
  let day = 86400000000L
  let first = 745154.0 * 86400.0
  assert_eq(
    to_instant(first - 1.0),
    Ok(first.to_int64() * 1000000L - 1000000L + epoch),
  )
  assert_eq(to_instant(first), Ok(first.to_int64() * 1000000L + day + epoch))
  let second = 2206123.0 * 86400.0
  assert_eq(
    to_instant(second),
    Ok(second.to_int64() * 1000000L + 2L * day + epoch),
  )
  assert_eq(to_instant(0.5), Ok(epoch + 500000L))
  assert_eq(to_instant(0.1), Ok(epoch + 100000L))
  assert_eq(to_instant(not_a_number), Err(()))
}

///|
test "a column converts cell by cell, and one cell that does not leaves it numbers" {
  let days = column_values([Some(1.0), None, Some(0.0)], to_day)
  match days {
    Ok(counts) => {
      assert_eq(counts.length(), 3)
      match counts[0] {
        Some(day) => assert_eq(day, -3652L)
        None => fail("the first cell converted to nothing")
      }
      match counts[1] {
        None => ()
        Some(_) => fail("the missing cell converted to a day")
      }
      match counts[2] {
        Some(day) => assert_eq(day, -3653L)
        None => fail("the third cell converted to nothing")
      }
    }
    Err(_) => fail("every present cell is a whole number of days")
  }
  assert_eq(column_values([Some(1.0), Some(1.5)], to_day), Err(()))
  assert_eq(column_values([None, None], to_day), Ok([None, None]))
}

///|
test "bytes spell an ASCII text where it lies" {
  let bytes = b"..SASYZCR2.."
  assert_eq(spells(bytes, 2L, "SASYZCR"), true)
  assert_eq(spells(bytes, 2L, "SASYZCR2"), true)
  assert_eq(spells(bytes, 2L, "SASYZCRL"), false)
  assert_eq(spells(bytes, 3L, "SASYZCR"), false)
  assert_eq(spells(bytes, 0L, ".."), true)
}

///|
test "a text cell loses the padding, keeps what is inside, and decodes as the header says" {
  let utf8 = header_of(false, true, 20)
  let latin = header_of(false, true, 29)
  let padded = letters("ab") + [b' ', b' ', b'\x00', b' ']
  assert_eq(cell_text(padded, 0, padded.length(), 0L, utf8), "ab")
  assert_eq(cell_text([b' ', b' ', b'\x00'], 0, 3, 0L, utf8), "")
  assert_eq(cell_text([b'x', b'\x00', b'\x00'], 0, 3, 0L, latin), "x")
  assert_eq(cell_text([b' ', b'a', b' '], 0, 3, 0L, latin), " a")
  let two = [b'\xc3', b'\xa9', b' ']
  assert_eq(cell_text(two, 0, 3, 0L, utf8), "é")
  assert_eq(cell_text(two, 0, 3, 0L, latin), "Ã©")
  let encoded = @utf8.encode("日本語")
  let wide = Array::makei(encoded.length(), i => encoded[i]) + [b' ']
  assert_eq(cell_text(wide, 0, wide.length(), 0L, utf8), "日本語")
  assert_eq(cell_text([b'\xe9'], 0, 1, 0L, latin), "é")
  assert_eq(cell_text([b'\x80'], 0, 1, 0L, latin), "\u{80}")
  assert_eq(cell_text([], 0, 0, 0L, latin), "")
  assert_eq(
    detail(() => cell_text([b'\xff'], 0, 1, 700L, utf8)),
    "sas7bdat: byte 700: a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
  )
  assert_eq(
    detail(() => cell_text([b'a', b'\xe6', b'\x97'], 0, 3, 700L, utf8)),
    "sas7bdat: byte 701: a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
  )
}

///|
test "a text field is decoded as a whole, and an empty one is empty" {
  let utf8 = header_of(true, false, 20)
  let latin = header_of(true, false, 29)
  let windows = header_of(true, false, 62)
  assert_eq(decode_text(b"abc", 0L, 0L, 0L, utf8), "")
  assert_eq(decode_text(b"abc", 0L, 2L, 0L, utf8), "ab")
  assert_eq(decode_text(b"abc", 1L, 2L, 0L, latin), "bc")
  assert_eq(decode_text(b"\xc3\xa9", 0L, 2L, 0L, utf8), "é")
  assert_eq(decode_text(b"\xc3\xa9", 0L, 2L, 0L, latin), "Ã©")
  // Through a code page: the euro sign, and a y-diaeresis where Latin-1
  // would read a division sign.
  assert_eq(decode_text(b"\x80\xff", 0L, 2L, 0L, windows), "€ÿ")
  assert_eq(decode_text(b"\x80\xff", 0L, 2L, 0L, latin), "\u{80}ÿ")
  assert_eq(
    detail(() => decode_text(b"\xc3", 0L, 1L, 41L, utf8)),
    "sas7bdat: byte 41: a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
  )
  assert_eq(
    detail(() => decode_text(b"a", 5L, 1L, 0L, latin)),
    "sas7bdat: byte 5: the file ends at byte 1 inside a text field (bytes 5 to 5)",
  )
}

///|
test "a numeric cell's bytes spell the number's leading bytes, in either byte order" {
  // 8.0 is 40 20 00 00 00 00 00 00 most significant first.
  let be = [
    b'\x40', b'\x20', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ]
  let le = [
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x20', b'\x40',
  ]
  assert_eq(numeric_bits(be, 0, 8, false), 0x4020000000000000UL)
  assert_eq(numeric_bits(le, 0, 8, true), 0x4020000000000000UL)
  // Three bytes: the big-endian cell holds the spelling's first three,
  // the little-endian one its last three, least significant first.
  assert_eq(numeric_bits(be, 0, 3, false), 0x4020000000000000UL)
  assert_eq(
    numeric_bits([b'\x00', b'\x20', b'\x40'], 0, 3, true),
    0x4020000000000000UL,
  )
  assert_eq(numeric_bits(be, 0, 2, false), 0x4020000000000000UL)
  assert_eq(numeric_bits([b'\x20', b'\x40'], 0, 2, true), 0x4020000000000000UL)
  // One byte: the sign and exponent alone; a missing value's first byte.
  assert_eq(numeric_bits([b'\x7f'], 0, 1, false), 0x7F00000000000000UL)
  assert_eq(numeric_bits([b'\x7f'], 0, 1, true), 0x7F00000000000000UL)
  assert_eq(numeric_bits([b'\xff'], 0, 1, true), 0xFF00000000000000UL)
  // A cell behind another in the row: eight bytes; then seven, the
  // little-endian cell dropping its least significant byte, the zero.
  let row = [b'\x00', b'\x41'] + le
  assert_eq(numeric_bits(row, 2, 8, true), 0x4020000000000000UL)
  let seven = [b'\x00', b'\x41', 0, 0, 0, 0, 0, b'\x20', b'\x40']
  assert_eq(numeric_bits(seven, 2, 7, true), 0x4020000000000000UL)
  // -0.0 and a number whose every byte is set.
  assert_eq(
    numeric_bits([b'\x80', 0, 0, 0, 0, 0, 0, 0], 0, 8, false).reinterpret_as_double(),
    -0.0,
  )
  assert_eq(
    numeric_bits(
      [b'\x01', b'\x23', b'\x45', b'\x67', b'\x89', b'\xab', b'\xcd', b'\xef'],
      0,
      8,
      false,
    ),
    0x0123456789ABCDEFUL,
  )
}

///|
test "a file is told a data set by the 32 bytes it opens with, and by nothing shorter" {
  let signature = Bytes::makei(32, i => magic_byte(i).to_byte())
  assert_true(opens_data_set(signature))
  assert_false(opens_data_set(b""))
  assert_false(opens_data_set(signature[0:31].to_owned()))
  // A byte changed inside the signature — at its first, its middle and
  // its last — says another file.
  for at in [0, 17, 31] {
    let changed = Bytes::makei(32, i => {
      if i == at {
        (magic_byte(i) ^ 0x01).to_byte()
      } else {
        magic_byte(i).to_byte()
      }
    })
    assert_false(opens_data_set(changed))
  }
}
