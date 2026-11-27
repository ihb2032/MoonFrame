// Whitebox tests of the writer's byte layout and of the reader's parts in
// isolation. The blackbox suite compares every cell with what the
// reference readers get; these pin what a cell comparison cannot — where
// the writer puts each section and what it spells there, how the
// long-string key is assembled in each byte order and release, what the
// checked reads answer on hand-built bytes, and where each internal rule
// ends.

///|
/// Where `text` begins in `bytes`; absent fails.
fn at(bytes : Bytes, text : Bytes) -> Int32 raise {
  let limit = bytes.length() - text.length()
  let mut i = 0
  while i <= limit {
    let mut same = true
    for k in 0..<text.length() {
      if bytes[i + k] != text[k] {
        same = false
      }
    }
    if same {
      return i
    }
    i += 1
  }
  fail("no such bytes in the file")
}

///|
/// `bytes[at:at + 2]` as a little-endian integer.
fn le16(bytes : Bytes, at : Int32) -> Int32 {
  bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
}

///|
/// `bytes[at:at + 8]` as a little-endian integer.
fn le64(bytes : Bytes, at : Int32) -> UInt64 {
  let mut value = 0UL
  for i = 7; i >= 0; i = i - 1 {
    value = (value << 8) | bytes[at + i].to_uint64()
  }
  value
}

///|
/// `bytes[at:at + n]`.
fn cut(bytes : Bytes, at : Int32, n : Int32) -> Bytes {
  Bytes::makei(n, i => bytes[at + i])
}

///|
/// A cursor over `bytes`, in the byte order `big` names.
fn over(bytes : Bytes, big : Bool) -> Cursor {
  Cursor::{ bytes, pos: 0, big, utf8: false, }
}

///|
/// `value` as `width` bytes, spelled in the file's byte order.
fn spelled(value : UInt64, width : Int32, big : Bool) -> Bytes {
  Bytes::makei(width, i => {
    let shift = if big { width - 1 - i } else { i }
    ((value >> (shift * 8)) & 0xFFUL).to_byte()
  })
}

///|
/// The table whose layout the tests below pin: nine columns, every
/// storage the writer spells, two rows — one of values, one of missing
/// cells.
fn pinned() -> Bytes raise @types.DataError {
  let vacant = @series.Series::from_i64_options(
    "vacant",
    @types.DataType::Null,
    [None, None],
  )
  let columns : Array[@series.Series] = [
    @series.Series::from_scalars(
      "flag",
      [@types.Scalar::Bool(true), @types.Scalar::Null],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_scalars(
      "num",
      [@types.Scalar::Int(1L), @types.Scalar::Null],
      dtype=@types.DataType::Int,
    ),
    @series.Series::from_scalars(
      "wide",
      [@types.Scalar::Int(1099511627776L), @types.Scalar::Null],
      dtype=@types.DataType::Int,
    ),
    @series.Series::from_scalars(
      "ratio",
      [@types.Scalar::Float(1.5), @types.Scalar::Null],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "label",
      [@types.Scalar::String("héllo"), @types.Scalar::String("")],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "notes",
      [
        @types.Scalar::String(String::make(2200, 'x')),
        @types.Scalar::String(""),
      ],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "day",
      [@types.Scalar::Date(0L), @types.Scalar::Null],
      dtype=@types.DataType::Date,
    ),
    @series.Series::from_scalars(
      "stamp",
      [@types.Scalar::Timestamp(1000L), @types.Scalar::Null],
      dtype=@types.DataType::Timestamp,
    ),
    vacant,
  ]
  write_stata_bytes(columns, height=2)
}

///|
test "the header names release 118, the little-endian byte order, and the counts" {
  let bytes = pinned()
  assert_eq(cut(bytes, 0, 31), b"<stata_dta><header><release>118")
  let order = at(bytes, b"</release><byteorder>")
  assert_eq(order, 31)
  assert_eq(cut(bytes, order + 21, 3), b"LSF")
  let k = at(bytes, b"</byteorder><K>") + 15
  assert_eq(k, 70)
  assert_eq(le16(bytes, k), 9)
  let n = at(bytes, b"</K><N>") + 7
  assert_eq(n, 79)
  assert_eq(le64(bytes, n), 2UL)
  // An empty label: a two-byte length of zero.
  let label = at(bytes, b"</N><label>") + 11
  assert_eq(label, 98)
  assert_eq(le16(bytes, label), 0)
  // The timestamp: a one-byte length, the control byte the format's own
  // files open it with, and `dd Mon yyyy hh:mm`.
  let stamp = at(bytes, b"</label><timestamp>") + 19
  assert_eq(stamp, 119)
  assert_eq(bytes[stamp].to_int(), 18)
  assert_eq(bytes[stamp + 1].to_int(), 0x11)
  assert_eq(cut(bytes, stamp + 2, 17), b"01 Jan 1970 00:00")
  assert_eq(at(bytes, b"</timestamp></header>"), 138)
}

///|
test "the map places every section where the section begins" {
  let bytes = pinned()
  let map = at(bytes, b"<map>")
  assert_eq(map, 159)
  let entries_at = map + 5
  let places : Array[Int32] = [
    0,
    map,
    at(bytes, b"<variable_types>"),
    at(bytes, b"<varnames>"),
    at(bytes, b"<sortlist>"),
    at(bytes, b"<formats>"),
    at(bytes, b"<value_label_names>"),
    at(bytes, b"<variable_labels>"),
    at(bytes, b"<characteristics>"),
    at(bytes, b"<data>"),
    at(bytes, b"<strls>"),
    at(bytes, b"<value_labels>"),
    at(bytes, b"</stata_dta>"),
    bytes.length(),
  ]
  for i, place in places {
    assert_eq(le64(bytes, entries_at + 8 * i), place.to_uint64())
  }
  // The sections in the map's order, each opening where the previous
  // section's closing tag ends: one position after another, nothing
  // between.
  let closing : ReadOnlyArray[Bytes] = [
    b"</map>", b"</variable_types>", b"</varnames>", b"</sortlist>", b"</formats>",
    b"</value_label_names>", b"</variable_labels>", b"</characteristics>", b"</data>",
    b"</strls>", b"</value_labels>",
  ]
  for i, tag in closing {
    assert_eq(places[i + 2], at(bytes, tag) + tag.length())
  }
  // Fourteen entries of eight bytes fill the map; the file ends where its
  // closing tag does.
  assert_eq(at(bytes, b"</map>"), entries_at + 112)
  assert_eq(places[13], at(bytes, b"</stata_dta>") + 12)
}

///|
test "the descriptors spell each column's type code, name, and format" {
  let bytes = pinned()
  // A byte for the flag, a long for the number and the date, a double for
  // the wide number, the ratio, the stamp and the vacant column, a
  // six-byte string for the label, and the long-string code.
  let codes : ReadOnlyArray[Int32] = [
    65530, 65528, 65526, 65526, 6, 32768, 65528, 65526, 65526,
  ]
  let types = at(bytes, b"<variable_types>") + 16
  for i, code in codes {
    assert_eq(le16(bytes, types + 2 * i), code)
  }
  assert_eq(at(bytes, b"</variable_types>"), types + 18)
  // Every name in a 129-byte slot, NUL-padded.
  let names : ReadOnlyArray[String] = [
    "flag", "num", "wide", "ratio", "label", "notes", "day", "stamp", "vacant",
  ]
  let names_at = at(bytes, b"<varnames>") + 10
  for i, name in names {
    let slot = cut(bytes, names_at + 129 * i, 129)
    assert_eq(cut(slot, 0, name.length()), @utf8.encode(name))
    for k in name.length()..<129 {
      assert_eq(slot[k].to_int(), 0)
    }
  }
  assert_eq(at(bytes, b"</varnames>"), names_at + 129 * 9)
  // An empty sort list: one two-byte slot per variable, and the closing
  // zero slot.
  let sorts = at(bytes, b"<sortlist>") + 10
  assert_eq(at(bytes, b"</sortlist>"), sorts + 20)
  for k in 0..<20 {
    assert_eq(bytes[sorts + k].to_int(), 0)
  }
  // Every format in a 57-byte slot.
  let formats : ReadOnlyArray[String] = [
    "%8.0g", "%12.0g", "%10.0g", "%10.0g", "%6s", "%9s", "%td", "%tc", "%10.0g",
  ]
  let formats_at = at(bytes, b"<formats>") + 9
  for i, format in formats {
    let slot = cut(bytes, formats_at + 57 * i, 57)
    assert_eq(cut(slot, 0, format.length()), @utf8.encode(format))
    for k in format.length()..<57 {
      assert_eq(slot[k].to_int(), 0)
    }
  }
  assert_eq(at(bytes, b"</formats>"), formats_at + 57 * 9)
  // Every value-label name and every variable label left blank: a
  // 129-byte and a 321-byte slot per variable, all zeros.
  let label_names = at(bytes, b"<value_label_names>")
  let label_names_from = label_names + b"<value_label_names>".length()
  assert_eq(at(bytes, b"</value_label_names>"), label_names_from + 129 * 9)
  for k in label_names_from..<at(bytes, b"</value_label_names>") {
    assert_eq(bytes[k].to_int(), 0)
  }
  let labels = at(bytes, b"<variable_labels>")
  let labels_from = labels + b"<variable_labels>".length()
  assert_eq(at(bytes, b"</variable_labels>"), labels_from + 321 * 9)
  for k in labels_from..<at(bytes, b"</variable_labels>") {
    assert_eq(bytes[k].to_int(), 0)
  }
  // No characteristic, no value label: each section is its two tags.
  let no_characteristics = b"<characteristics></characteristics>"
  assert_eq(
    cut(bytes, at(bytes, b"<characteristics>"), no_characteristics.length()),
    no_characteristics,
  )
  let no_labels = b"<value_labels></value_labels>"
  assert_eq(
    cut(bytes, at(bytes, b"<value_labels>"), no_labels.length()),
    no_labels,
  )
}

///|
test "the data block spells each cell in its storage, missing codes included" {
  let bytes = pinned()
  let data = at(bytes, b"<data>") + 6
  // A row is 55 bytes: 1 + 4 + 8 + 8 + 6 + 8 + 4 + 8 + 8; two rows.
  assert_eq(at(bytes, b"</data>"), data + 110)
  // Row 1: every value.
  let row = cut(bytes, data, 55)
  assert_eq(cut(row, 0, 1), b"\x01")
  assert_eq(cut(row, 1, 4), b"\x01\x00\x00\x00")
  assert_eq(le64(row, 5), 1099511627776.0.reinterpret_as_uint64())
  assert_eq(le64(row, 13), 1.5.reinterpret_as_uint64())
  assert_eq(cut(row, 21, 6), @utf8.encode("héllo"))
  // The long string's key: variable 6, row 1 — two bytes then six.
  assert_eq(le64(row, 27), 6UL | (1UL << 16))
  // Day 0 since 1970-01-01 is day 3653 since 1960-01-01.
  assert_eq(cut(row, 35, 4), b"\x45\x0E\x00\x00")
  // 1000 microseconds are one millisecond since 1970-01-01, which is
  // 315,619,200,001 milliseconds since 1960-01-01.
  assert_eq(le64(row, 39).reinterpret_as_double(), 315_619_200_001.0)
  assert_eq(le64(row, 47), 0x7FE0000000000000UL)
  // Row 2: every cell missing — the byte's 101, the long's 2147483621,
  // the double's 2^1023, and the empty strings.
  let row = cut(bytes, data + 55, 55)
  assert_eq(cut(row, 0, 1), b"\x65")
  assert_eq(cut(row, 1, 4), b"\xE5\xFF\xFF\x7F")
  assert_eq(le64(row, 5), 0x7FE0000000000000UL)
  assert_eq(le64(row, 13), 0x7FE0000000000000UL)
  assert_eq(cut(row, 21, 14), Bytes::makei(14, _ => (0).to_byte()))
  assert_eq(cut(row, 35, 4), b"\xE5\xFF\xFF\x7F")
  assert_eq(le64(row, 39), 0x7FE0000000000000UL)
  assert_eq(le64(row, 47), 0x7FE0000000000000UL)
}

///|
test "the long-string records are keyed by the first row a text appears in" {
  let bytes = pinned()
  let strls = at(bytes, b"<strls>") + 7
  assert_eq(cut(bytes, strls, 3), b"GSO")
  // Four bytes of variable, eight of row: the pair (6, 1).
  assert_eq(cut(bytes, strls + 3, 4), b"\x06\x00\x00\x00")
  assert_eq(cut(bytes, strls + 7, 8), b"\x01\x00\x00\x00\x00\x00\x00\x00")
  // Kind 130; a length counting the terminator; the text; the NUL.
  assert_eq(bytes[strls + 15].to_int(), 130)
  assert_eq(cut(bytes, strls + 16, 4), b"\x99\x08\x00\x00")
  assert_eq(cut(bytes, strls + 20, 2200), @utf8.encode(String::make(2200, 'x')))
  assert_eq(bytes[strls + 2220].to_int(), 0)
  // One record: the empty string keeps none.
  assert_eq(at(bytes, b"</strls>"), strls + 2221)
}

///|
test "a table of no column carries its height and nothing else" {
  let bytes = write_stata_bytes([], height=3)
  assert_eq(le16(bytes, at(bytes, b"</byteorder><K>") + 15), 0)
  assert_eq(le64(bytes, at(bytes, b"</K><N>") + 7), 3UL)
  // The sort list is its closing zero slot alone; the data block is empty.
  assert_eq(cut(bytes, at(bytes, b"<sortlist>"), 12), b"<sortlist>\x00\x00")
  assert_eq(cut(bytes, at(bytes, b"<data>"), 13), b"<data></data>")
  assert_eq(cut(bytes, at(bytes, b"<strls>"), 15), b"<strls></strls>")
  assert_eq(
    at(bytes, b"<variable_types>"),
    at(bytes, b"</variable_types>") - 16,
  )
}

///|
test "the long-string key follows the file's byte order in each release" {
  let v = 0x0CUL
  let o = 0x05UL
  // Release 118: two bytes of the variable's number, then six of the
  // row's — each in the file's order.
  assert_eq(strl_key(over(b"", false), v, o, 2), 0x0CUL | (0x05UL << 16))
  assert_eq(strl_key(over(b"", true), v, o, 2), (0x0CUL << 48) | 0x05UL)
  // Release 119: three and five.
  assert_eq(strl_key(over(b"", false), v, o, 3), 0x0CUL | (0x05UL << 24))
  assert_eq(strl_key(over(b"", true), v, o, 3), (0x0CUL << 40) | 0x05UL)
  // The pair's high bytes are not kept.
  assert_eq(
    strl_key(over(b"", false), 0x1000CUL, 0x1000000000005UL, 2),
    0x0CUL | (0x05UL << 16),
  )
}

///|
test "the long-string table reads a record in each release and byte order" {
  let text = b"hi\x00"
  for big in [false, true] {
    for release in [117, 118, 119] {
      // A record's header spells the pair (12, 5): four bytes of variable
      // and four of row in 117, four and eight after it; then a kind byte
      // and a four-byte length — all in the file's byte order.
      let row_width = if release == 117 { 4 } else { 8 }
      let header_width = 3 + 4 + row_width + 5
      let section : Array[Byte] = []
      for b in b"<strls>GSO" {
        section.push(b)
      }
      for b in spelled(12UL, 4, big) {
        section.push(b)
      }
      for b in spelled(5UL, row_width, big) {
        section.push(b)
      }
      section.push((130).to_byte())
      for b in spelled(3UL, 4, big) {
        section.push(b)
      }
      for b in text {
        section.push(b)
      }
      for b in b"</strls>" {
        section.push(b)
      }
      let bytes = Bytes::from_array(section)
      let r = over(bytes, big)
      r.pos = 7
      let table = read_strl_table(r, release)
      assert_eq(r.pos, bytes.length())
      assert_eq(table.length(), 1)
      // The key is the eight bytes a cell holds: in 117 the pair's eight
      // bytes as they are, after it the pair's low bytes — each in the
      // file's order.
      let key = if release == 117 {
        if big {
          (12UL << 32) | 5UL
        } else {
          12UL | (5UL << 32)
        }
      } else if release == 118 {
        if big {
          (12UL << 48) | 5UL
        } else {
          12UL | (5UL << 16)
        }
      } else if big {
        (12UL << 40) | 5UL
      } else {
        12UL | (5UL << 24)
      }
      let entry = table.get(key).unwrap()
      assert_eq(entry.kind, 130)
      assert_eq(entry.length, 3)
      assert_eq(entry.start, 7 + header_width)
      // The cell's reading of the key agrees, where a cell keeps the
      // pair's low bytes.
      if release != 117 {
        assert_eq(
          strl_key(
            over(b"", big),
            12UL,
            5UL,
            if release == 118 {
              2
            } else {
              3
            },
          ),
          key,
        )
      }
    }
  }
}

///|
test "the checked reads answer in both byte orders and refuse outside the file" {
  // 1, -2, 3, -4 as two-byte integers; 5 and -6 as four-byte.
  let le = b"\x01\x00\xFE\xFF\x03\x00\xFC\xFF\x05\x00\x00\x00\xFA\xFF\xFF\xFF"
  let be = b"\x00\x01\xFF\xFE\x00\x03\xFF\xFC\x00\x00\x00\x05\xFF\xFF\xFF\xFA"
  let r = over(le, false)
  assert_eq(r.u16(), 1)
  assert_eq(r.i16(), -2L)
  assert_eq(r.u16(), 3)
  assert_eq(r.i16(), -4L)
  assert_eq(r.u32(), 5L)
  assert_eq(r.i32(), -6L)
  let r = over(be, true)
  assert_eq(r.u16(), 1)
  assert_eq(r.i16(), -2L)
  assert_eq(r.u16(), 3)
  assert_eq(r.i16(), -4L)
  assert_eq(r.u32(), 5L)
  assert_eq(r.i32(), -6L)
  // A one-byte integer's sign.
  assert_eq(over(b"\xFF", false).i8(), -1L)
  assert_eq(over(b"\x7F", false).i8(), 127L)
  assert_eq(over(b"\x80", false).i8(), -128L)
  // Eight bytes, and the minimum's own bits.
  assert_eq(over(b"\x01\x00\x00\x00\x00\x00\x00\x00", false).u64(), 1UL)
  assert_eq(
    over(b"\x00\x00\x00\x00\x00\x00\x00\x80", false)
    .u64()
    .reinterpret_as_int64(),
    -9223372036854775808L,
  )
  // Big-endian, the first byte is the most significant: 2^63 itself,
  // then 128 with its byte last.
  assert_eq(
    over(b"\x80\x00\x00\x00\x00\x00\x00\x00", true).u64(),
    0x8000000000000000UL,
  )
  assert_eq(over(b"\x00\x00\x00\x00\x00\x00\x00\x80", true).u64(), 128UL)
  // A floating cell is widened; one outside the valid range is missing:
  // `.` and `.a` are, and so are the infinities and a plain NaN.
  let r = over(
    b"\x00\x00\xC0\x3F\x00\x08\x00\x7F\x00\x00\x80\x7F\x00\x00\x80\xFF", false,
  )
  assert_eq(r.f32_cell(), Some(1.5))
  assert_eq(r.f32_cell(), None)
  assert_eq(r.f32_cell(), None)
  assert_eq(r.f32_cell(), None)
  // The largest valid double is one step below `.`.
  assert_eq(
    over(spelled(0x7FDFFFFFFFFFFFFFUL, 8, false), false).f64_cell(),
    Some(1.7976931348623157e308 / 2.0),
  )
  for
    bits in [
      0x7FE0000000000000UL, 0x7FE01A0000000000UL, 0x7FF0000000000000UL, 0xFFF0000000000000UL,
      0x7FF8000000000000UL,
    ] {
    assert_eq(over(spelled(bits, 8, false), false).f64_cell(), None)
  }
  // A read past the end refuses, naming where it was.
  let outcome : Result[Int32, @types.DataError] = Ok(over(b"\x01", false).u16()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(value) => fail("two bytes were read from one: \{value}")
    Err(e) =>
      assert_eq(
        e,
        bad("the file ends at byte 1 before the 2 bytes needed at offset 0"),
      )
  }
}

///|
test "a text reads in the release's encoding, cut at its first NUL" {
  // Latin-1: one character per byte, and a NUL ends the text wherever
  // it comes.
  assert_eq(decode_text(b"Zo\x00\xEBn", 0, 5, false), "Zo")
  assert_eq(decode_text(b"Zo\xEB\x00n", 0, 5, false), "Zoë")
  assert_eq(decode_text(b"Zo\xEB", 0, 3, false), "Zoë")
  assert_eq(decode_text(b"plain", 0, 5, false), "plain")
  // UTF-8.
  assert_eq(decode_text(@utf8.encode("日本語"), 0, 9, true), "日本語")
  assert_eq(decode_text(b"\x00\x00", 0, 2, true), "")
  // Bytes that are not UTF-8 in a UTF-8 release read as Latin-1.
  assert_eq(decode_text(b"Zo\xEB", 0, 3, true), "Zoë")
  // A slice that starts past the first byte.
  assert_eq(decode_text(b"xxZo\xEB", 2, 3, false), "Zoë")
}

///|
test "the date family is named by the format's opening letters" {
  assert_true(date_kind("%td") is Day)
  assert_true(date_kind("%tdDDmonCCYY") is Day)
  assert_true(date_kind("%tc") is Clock)
  assert_true(date_kind("%tcHH:MM:SS") is Clock)
  assert_true(date_kind("%tC") is Clock)
  for
    format in [
      "%d", "%tm", "%tq", "%tw", "%th", "%ty", "%9.0g", "", "%t", " %td",
    ] {
    assert_true(date_kind(format) is Plain)
  }
}

///|
test "a floating cell moves onto the library's epoch only as a whole count" {
  let limit = 9007199254740992.0
  assert_eq(shifted_double(0.0, Day), Some(-3653L))
  assert_eq(shifted_double(3653.0, Day), Some(0L))
  assert_eq(shifted_double(-3653.0, Day), Some(-7306L))
  assert_eq(shifted_double(315_619_200_000.0, Clock), Some(0L))
  assert_eq(shifted_double(-1.0, Clock), Some(-315_619_200_001_000L))
  assert_eq(shifted_double(limit, Day), Some(9007199254737339L))
  assert_eq(shifted_double(-limit, Day), Some(-9007199254744645L))
  assert_eq(shifted_double(1.5, Day), None)
  assert_eq(shifted_double(0.5, Clock), None)
  // Beyond 2^53 a double skips whole numbers: no count can be trusted.
  assert_eq(shifted_double(9007199254740994.0, Day), None)
  assert_eq(shifted_double(-9007199254740994.0, Day), None)
  assert_eq(shifted_double(0.0 / 0.0, Day), None)
  assert_eq(shifted_double(1.0 / 0.0, Day), None)
  assert_eq(shifted_double(-1.0 / 0.0, Day), None)
  // An integer cell's count: the value itself, or its shift.
  assert_eq(shifted_int(7L, Plain), 7L)
  assert_eq(shifted_int(7L, Day), 7L - 3653L)
  assert_eq(shifted_int(7L, Clock), (7L - 315_619_200_000L) * 1000L)
}

///|
test "a missing value is whatever lies outside the storage's valid range" {
  for
    (value, missing) in [
      (101L, true),
      (127L, true),
      (100L, false),
      (-127L, false),
      (-128L, true),
      (0L, false),
    ] {
    assert_eq(byte_missing(value), missing)
  }
  assert_eq(int_missing(32740L), false)
  assert_eq(int_missing(32741L), true)
  assert_eq(int_missing(-32767L), false)
  assert_eq(int_missing(-32768L), true)
  assert_eq(long_missing(2147483620L), false)
  assert_eq(long_missing(2147483621L), true)
  assert_eq(long_missing(2147483647L), true)
  assert_eq(long_missing(-2147483647L), false)
  assert_eq(long_missing(-2147483648L), true)
}

///|
test "the type codes end where the storages do" {
  assert_true(binary_storage(1) is Str(1))
  assert_true(binary_storage(244) is Str(244))
  assert_true(binary_storage(251) is Byte)
  assert_true(binary_storage(255) is Double)
  assert_true(tagged_storage(1) is Str(1))
  assert_true(tagged_storage(245) is Str(245))
  assert_true(tagged_storage(2045) is Str(2045))
  assert_true(tagged_storage(32768) is StrL)
  assert_true(tagged_storage(65526) is Double)
  assert_true(tagged_storage(65530) is Byte)
  for code in [0, 245, 250, 256, 32767, 32769, 65525, 65531, 65535] {
    let outcome : Result[Storage, @types.DataError] = Ok(binary_storage(code)) catch {
      e => Err(e)
    }
    match outcome {
      Ok(_) => fail("the binary code \{code} read as a storage")
      Err(e) =>
        assert_eq(
          e,
          @types.DataError::Unsupported(
            "the variable type code \{code} names no storage this reader reads",
          ),
        )
    }
  }
  for code in [0, 2046, 32767, 32769, 65525, 65531, 65535] {
    let outcome : Result[Storage, @types.DataError] = Ok(tagged_storage(code)) catch {
      e => Err(e)
    }
    match outcome {
      Ok(_) => fail("the tagged code \{code} read as a storage")
      Err(e) =>
        assert_eq(
          e,
          @types.DataError::Unsupported(
            "the variable type code \{code} names no storage this reader reads",
          ),
        )
    }
  }
}

///|
test "the release and the byte order are read from their fields" {
  for (text, release) in [("117", 117), ("118", 118), ("119", 119)] {
    assert_eq(tagged_release(over(@utf8.encode(text), false)), release)
  }
  for text in ["116", "120", "918", "11x", "abc", "000"] {
    let outcome : Result[Int32, @types.DataError] = Ok(
      tagged_release(over(@utf8.encode(text), false)),
    ) catch {
      e => Err(e)
    }
    match outcome {
      Ok(release) => fail("\{text} read as release \{release}")
      Err(e) =>
        assert_eq(
          e,
          @types.DataError::Unsupported(
            "the file declares release \{text}; this reader reads releases 113 to 119",
          ),
        )
    }
  }
  assert_eq(byte_order(over(b"LSF", false)), false)
  assert_eq(byte_order(over(b"MSF", false)), true)
  let outcome : Result[Bool, @types.DataError] = Ok(
    byte_order(over(b"XYZ", false)),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("XYZ read as a byte order")
    Err(e) =>
      assert_eq(
        e,
        bad("the byte order field at offset 0 reads neither LSF nor MSF"),
      )
  }
}

///|
test "a count the file cannot hold refuses before anything is sized by it" {
  let r = over(b"\x00\x00\x00\x00", false)
  assert_eq(r.items(2L, 2), 2)
  for (count, each) in [(3L, 2), (1L, 5), (-1L, 1), (2147483648L, 0)] {
    let outcome : Result[Int32, @types.DataError] = Ok(r.items(count, each)) catch {
      e => Err(e)
    }
    match outcome {
      Ok(n) => fail("\{count} entries of \{each} bytes read as \{n}")
      Err(e) =>
        assert_eq(
          e,
          bad(
            "the header declares \{count} entries of \{each} bytes at offset 0, and only 4 bytes remain",
          ),
        )
    }
  }
  // A map entry past the file refuses; one at the file's end is a place.
  assert_eq(r.place(4UL), 4)
  let outcome : Result[Int32, @types.DataError] = Ok(r.place(5UL)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("offset 5 placed inside a file of 4 bytes")
    Err(e) =>
      assert_eq(
        e,
        bad("the map places a section at offset 5, past the file's 4 bytes"),
      )
  }
}

///|
test "the data block is checked against what the file holds" {
  let r = over(Bytes::makei(10, _ => (0).to_byte()), false)
  r.pos = 4
  // Two bytes a row, three rows: exactly what remains.
  assert_eq(data_room(r, [Byte, Byte], 3L), 6)
  // One row too many.
  let outcome : Result[Int32, @types.DataError] = Ok(
    data_room(r, [Byte, Byte], 4L),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(n) => fail("\{n} bytes of data read where 6 remain for 8 needed")
    Err(e) =>
      assert_eq(
        e,
        bad(
          "the data block at offset 4 declares 4 observations of 2 bytes, and only 6 bytes remain",
        ),
      )
  }
  // A row wider than the file holds is refused however few the rows.
  let outcome : Result[Int32, @types.DataError] = Ok(
    data_room(r, [Double, Double], 1L),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(n) => fail("\{n} bytes of data read for a 16-byte row")
    Err(e) =>
      assert_eq(
        e,
        bad(
          "the data block at offset 4 declares 1 observations of 16 bytes, and only 6 bytes remain",
        ),
      )
  }
  // No variable: no data, whatever the count. No row: no data.
  assert_eq(data_room(r, [], 5L), 0)
  assert_eq(data_room(r, [Double, Double], 0L), 0)
  // The offsets of the cells inside a row, and the row's width.
  let variables = zip_variables(["a", "b", "c"], [Byte, Double, Str(3)], [
    "", "", "",
  ])
  assert_eq(variables[0].offset, 0)
  assert_eq(variables[1].offset, 1)
  assert_eq(variables[2].offset, 9)
  assert_eq(row_width(variables), 12)
}

///|
test "an integer moves under the double storage only when the double holds it exactly" {
  for
    v in [
      0L, 1L, -1L, 9007199254740992L, -9007199254740992L, 4611686018427387904L, -9223372036854775808L,
      3458764513820540928L,
    ] {
    if !double_holds(v) {
      fail("\{v} was not held exactly by the double storage")
    }
  }
  for
    v in [
      9007199254740993L, 9007199254740995L, 9223372036854775807L, -9007199254740993L,
      -9223372036854775807L, 4611686018427387903L,
    ] {
    if double_holds(v) {
      fail("\{v} was held exactly by the double storage")
    }
  }
}

///|
test "a code unit is spelled in four hex digits" {
  assert_eq(hex4(0x2D), "002D")
  assert_eq(hex4(0xE9), "00E9")
  assert_eq(hex4(0xD800), "D800")
  assert_eq(hex4(0x20AC), "20AC")
}

///|
test "a long-string record of no length reads as the empty string" {
  // Key zero is the empty string without a record.
  assert_eq(
    strl_text(over(b"\x00\x00\x00\x00\x00\x00\x00\x00", false), "n", 0, Map([])),
    "",
  )
  // A record of length zero under another key reads the same way.
  let table : Map[UInt64, StrLEntry] = Map([])
  table[7UL] = StrLEntry::{ kind: 130, start: 8, length: 0, }
  assert_eq(
    strl_text(over(b"\x07\x00\x00\x00\x00\x00\x00\x00", false), "n", 0, table),
    "",
  )
}

///|
test "the byte emitters spell little-endian and pad with zeros" {
  let out : Array[Byte] = []
  push_le(out, 0x0102030405060708UL, 8)
  push_le(out, 0xAABBCCUL, 3)
  push_le(out, 0x100UL, 1)
  push_zeros(out, 2)
  push_bytes(out, b"hi")
  push_text(out, "é")
  assert_eq(
    Bytes::from_array(out.copy()),
    b"\x08\x07\x06\x05\x04\x03\x02\x01\xCC\xBB\xAA\x00\x00\x00hi\xC3\xA9",
  )
  // A map entry is patched into bytes already appended.
  patch_le64(out, 0, 0x0102)
  assert_eq(out[0].to_int(), 2)
  assert_eq(out[1].to_int(), 1)
  assert_eq(out[2].to_int(), 0)
  assert_eq(out[7].to_int(), 0)
  // The missing codes, and a value's bits.
  assert_eq(double_missing().reinterpret_as_uint64(), 0x7FE0000000000000UL)
  assert_eq(LONG_MISSING, 2147483621L)
  assert_eq(BYTE_MISSING, 101L)
}
