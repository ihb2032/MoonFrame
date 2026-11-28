// Blackbox tests of every refusal: one test per distinct message, each
// asserting the variant and the exact text. The reader's cases are the
// 32-bit reference table `w32_pyrs.sas7bdat` — two columns, two rows —
// with bytes changed; its map (`w32_pyrs.map.json`, which the generator
// writes) names where everything lies. A few cases need a compressed
// file and use `rle32_pyrs.sas7bdat`. The decompressors' own refusals are
// exercised on hand-built streams in the whitebox tests.

///|
/// One subheader of the base file: where its pointer lies, where the
/// subheader lies, and how long it is.
struct Placed {
  at : Int32
  sub_at : Int32
  length : Int32
}

///|
/// The base file and the places in it the tests patch.
struct Base {
  bytes : Bytes
  count_at : Int32
  rows_at : Int32
  free : Int32
  free_offset : Int32
  last_pointer : Int32
  row_size : Placed
  column_size : Placed
  text : Placed
  names : Placed
  attributes : Placed
  formats : Array[Placed]
}

///|
/// The base file, with its map read.
fn base() -> Base raise {
  let map = fixture_json(
    ".github/fixtures/sas7bdat/reference/w32_pyrs.map.json",
  )
  let placed = fn(kind : String, nth : Int32) -> Placed raise {
    let mut found = -1
    let pointers = jarray(field(map, "pointers"))
    for pointer in pointers {
      if jstring(field(pointer, "kind")) == kind {
        found += 1
        if found == nth {
          return Placed::{
            at: number(pointer, "at"),
            sub_at: number(pointer, "sub_at"),
            length: number(pointer, "length"),
          }
        }
      }
    }
    fail("the map names no \{kind} subheader number \{nth}")
  }
  let pointers = jarray(field(map, "pointers"))
  let last = pointers[pointers.length() - 1]
  Base::{
    bytes: fixture(".github/fixtures/sas7bdat/reference/w32_pyrs.sas7bdat"),
    count_at: number(map, "count_at"),
    rows_at: number(map, "rows_at"),
    // Behind the two rows and far before the subheaders: free page space.
    free: number(map, "rows_at") + 64,
    free_offset: number(map, "rows_at") + 64 - number(map, "page_at"),
    last_pointer: number(last, "at"),
    row_size: placed("ROWSIZE", 0),
    column_size: placed("COLSIZE", 0),
    text: placed("COLTEXT", 0),
    names: placed("COLNAME", 0),
    attributes: placed("COLATTR", 0),
    formats: [placed("COLFMT", 0), placed("COLFMT", 1)],
  }
}

///|
/// A whole-number field of a JSON object, as an `Int32`.
fn number(value : Json, name : String) -> Int32 raise {
  jlong(field(value, name)).to_int()
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
/// `whole` cut to `length` bytes.
fn cut_to(whole : Bytes, length : Int32) -> Bytes {
  Bytes::makei(length, i => whole[i])
}

///|
/// `whole` from byte `from` to byte `to`.
fn slice(whole : Bytes, from : Int32, to : Int32) -> Bytes {
  Bytes::makei(to - from, i => whole[from + i])
}

///|
/// `whole` with the byte at `at` replaced by `value`.
fn replaced(whole : Bytes, at : Int32, value : Byte) -> Bytes {
  Bytes::makei(whole.length(), i => if i == at { value } else { whole[i] })
}

///|
/// An unsigned integer as little-endian bytes, two or four wide.
fn le(value : Int32, width : Int32) -> Bytes {
  Bytes::makei(width, i => ((value >> (8 * i)) & 0xFF).to_byte())
}

///|
/// `whole` with the four bytes at `at` set to `value`, little-endian.
fn u32_at(whole : Bytes, at : Int32, value : Int32) -> Bytes {
  patched(whole, at, le(value, 4))
}

///|
/// The error the reader raises for `bytes`; a table answered instead fails
/// the test.
fn read_error(bytes : Bytes) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(read_sas7bdat_frame(bytes)) catch {
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
/// The text the reader's `Unsupported` carries for `bytes`; another variant
/// fails the test.
fn unsupported_detail(bytes : Bytes) -> String raise {
  match read_error(bytes) {
    @types.DataError::Unsupported(text) => text
    other => fail("the reader raised \{other}, not an Unsupported")
  }
}

///|
/// The base with the empty last pointer made to name `length` bytes at
/// the free place, marked `compression` and `type`.
fn crafted(
  b : Base,
  content : Bytes,
  compression : Int32,
  kind : Int32,
) -> Bytes {
  let bytes = patched(b.bytes, b.free, content)
  let bytes = u32_at(bytes, b.last_pointer, b.free_offset)
  let bytes = u32_at(bytes, b.last_pointer + 4, content.length())
  patched(bytes, b.last_pointer + 8, le(compression, 1) + le(kind, 1))
}

// ---------------------------------------------------------------- the header

///|
test "a wrong magic byte refuses at that byte" {
  let b = base()
  assert_eq(
    parse_detail(replaced(b.bytes, 15, b'\x61')),
    "sas7bdat: byte 15: the magic is not the one a SAS Version 7/8/9 data set opens with (97 where 96 is due)",
  )
  assert_eq(
    parse_detail(patched(b.bytes, 0, b"\x01")),
    "sas7bdat: byte 0: the magic is not the one a SAS Version 7/8/9 data set opens with (1 where 0 is due)",
  )
}

///|
test "a file shorter than the header's fixed part refuses inside it" {
  let b = base()
  assert_eq(
    parse_detail(cut_to(b.bytes, 287)),
    "sas7bdat: byte 0: the file ends at byte 287 inside the header's fixed part (bytes 0 to 287)",
  )
  assert_eq(
    parse_detail(b""),
    "sas7bdat: byte 0: the file ends at byte 0 inside the header's fixed part (bytes 0 to 287)",
  )
}

///|
test "a byte-order byte that names neither order refuses" {
  let b = base()
  assert_eq(
    parse_detail(replaced(b.bytes, 37, 2)),
    "sas7bdat: byte 37: 2 names neither byte order (0 is big-endian, 1 little-endian)",
  )
}

///|
test "a header length under the fixed part, or past the file, refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, 196, 100)),
    "sas7bdat: byte 196: the header length is 100, under the 288 bytes the header's fixed part takes",
  )
  assert_eq(
    parse_detail(u32_at(b.bytes, 196, 70000)),
    "sas7bdat: byte 196: the header length is 70000 and the file ends at byte 66560",
  )
}

///|
test "a page length under a page's header refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, 200, 8)),
    "sas7bdat: byte 200: the page length is 8, under the 24 bytes a page's header takes",
  )
  assert_eq(
    parse_detail(u32_at(b.bytes, 200, 0)),
    "sas7bdat: byte 200: the page length is 0, under the 24 bytes a page's header takes",
  )
}

///|
test "a file that ends right after its header holds no page" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, 196, 66560)),
    "sas7bdat: byte 66560: the file ends right after its header, so it holds no page",
  )
}

///|
test "bytes after the header that are not a whole number of pages refuse" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, 200, 40000)),
    "sas7bdat: byte 200: the page length is 40000 and 65536 bytes follow the header: 1 whole pages and 25536 bytes over",
  )
}

///|
test "a character set this reader does not decode refuses by name" {
  let b = base()
  assert_eq(
    unsupported_detail(replaced(b.bytes, 70, 138)),
    "sas7bdat: byte 70: the character-set field names shift_jis (code 138), and this reader decodes UTF-8 (code 20) and the single-byte character sets",
  )
  assert_eq(
    unsupported_detail(replaced(b.bytes, 70, 250)),
    "sas7bdat: byte 70: the character-set field names an unassigned code (code 250), and this reader decodes UTF-8 (code 20) and the single-byte character sets",
  )
}

///|
test "a byte the file's code page leaves undefined refuses, in a cell and in a column name, naming the byte" {
  // windows-1252 (code 62) leaves 0x81, 0x8D, 0x8F, 0x90 and 0x9D undefined.
  let b = base()
  let windows = replaced(b.bytes, 70, 62)
  // Column 2 lies at byte 8 of each row.
  assert_eq(
    parse_detail(replaced(windows, b.rows_at + 8, 0x81)),
    "sas7bdat: byte \{b.rows_at + 8}: a text field holds byte 0x81, which the cp1252 character set leaves undefined",
  )
  // The name "a": the column-name subheader's first reference gives its
  // offset in the text block, which opens at the text subheader's size
  // field.
  let reference = b.names.sub_at + 4 + 8
  let offset = b.bytes[reference + 2].to_int() +
    256 * b.bytes[reference + 3].to_int()
  let name = b.text.sub_at + 4 + offset
  assert_eq(b.bytes[name], b'a')
  assert_eq(
    parse_detail(replaced(windows, name, 0x9d)),
    "sas7bdat: byte \{name}: a text field holds byte 0x9D, which the cp1252 character set leaves undefined",
  )
}

// ---------------------------------------------------------------- the pages

///|
test "subheader pointers that do not fit in their page refuse" {
  let b = base()
  assert_eq(
    parse_detail(patched(b.bytes, b.count_at, le(6000, 2))),
    "sas7bdat: byte 1044: 6000 subheader pointers of 12 bytes do not fit in a 65536-byte page",
  )
}

///|
test "a subheader outside its page refuses at its pointer" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.at, 65530)),
    "sas7bdat: byte 1048: a subheader at byte 65530 of 480 bytes does not fit in a 65536-byte page",
  )
}

///|
test "a subheader inside the page's pointers refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.at, 40)),
    "sas7bdat: byte 1048: a subheader at byte 40 lies inside the page's 10 subheader pointers",
  )
}

///|
test "a subheader shorter than its signature refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.at + 4, 2)),
    "sas7bdat: byte 1048: a subheader of 2 bytes is shorter than its signature",
  )
}

///|
test "a pointer's compression byte naming another storage refuses by name" {
  let b = base()
  assert_eq(
    unsupported_detail(replaced(b.bytes, b.row_size.at + 8, 2)),
    "sas7bdat: byte 1056: a subheader's compression byte is 2, which names a storage this reader does not read",
  )
}

///|
test "a row-size subheader too short for its fields refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.at + 4, 20)),
    "sas7bdat: byte 1048: a row-size subheader of 20 bytes",
  )
}

///|
test "a second row-size subheader must say what the first said" {
  let b = base()
  let copy = slice(
    b.bytes,
    b.row_size.sub_at,
    b.row_size.sub_at + b.row_size.length,
  )
  let bytes = patched(b.bytes, b.free, copy)
  let bytes = u32_at(bytes, b.free + 24, 3)
  let bytes = u32_at(bytes, b.last_pointer, b.free_offset)
  let bytes = u32_at(bytes, b.last_pointer + 4, b.row_size.length)
  let bytes = patched(bytes, b.last_pointer + 8, b"\x00\x00")
  assert_eq(
    parse_detail(bytes),
    "sas7bdat: byte 1232: a second row-size subheader says something other than the first",
  )
}

///|
test "a column-count subheader too short for its field refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.column_size.at + 4, 4)),
    "sas7bdat: byte 1060: a column-count subheader of 4 bytes",
  )
}

///|
test "a second column-count subheader must say what the first said" {
  let b = base()
  let copy = slice(b.bytes, b.column_size.sub_at, b.column_size.sub_at + 12)
  let bytes = patched(b.bytes, b.free, copy)
  let bytes = u32_at(bytes, b.free + 4, 5)
  let bytes = u32_at(bytes, b.last_pointer, b.free_offset)
  let bytes = u32_at(bytes, b.last_pointer + 4, 12)
  let bytes = patched(bytes, b.last_pointer + 8, b"\x00\x00")
  assert_eq(
    parse_detail(bytes),
    "sas7bdat: byte 1232: a second column-count subheader says something other than the first",
  )
}

///|
test "a text block whose size contradicts its subheader refuses" {
  let b = base()
  assert_eq(
    parse_detail(patched(b.bytes, b.text.sub_at + 4, le(40, 2))),
    "sas7bdat: byte 65712: a text block of 40 bytes in a subheader of 56 bytes",
  )
}

///|
test "a signature that is no subheader's, on a pointer that marks no row, refuses" {
  let b = base()
  assert_eq(
    parse_detail(crafted(b, b"\xde\xad\xbe\xef", 0, 0)),
    "sas7bdat: byte 1232: the signature deadbeef is not a subheader's, and the pointer does not mark a row",
  )
}

// ---------------------------------------------------------------- the columns

///|
test "a column-name subheader whose length its entries cannot fill refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.names.at + 4, 40)),
    "sas7bdat: byte 65672: a column-name subheader of 40 bytes",
  )
}

///|
test "a column-attribute subheader whose length its entries cannot fill refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.attributes.at + 4, 45)),
    "sas7bdat: byte 65628: a column-attribute subheader of 45 bytes",
  )
}

///|
test "a format subheader too short for its reference refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.formats[0].at + 4, 40)),
    "sas7bdat: byte 65534: a format subheader of 40 bytes",
  )
}

///|
test "a name that names a text block the file does not hold refuses" {
  let b = base()
  assert_eq(
    parse_detail(patched(b.bytes, b.names.sub_at + 12, le(1, 2))),
    "sas7bdat: byte 65684: the name of column 1 names text block 1, and the file holds 1",
  )
}

///|
test "a name or a format that names bytes past its text block refuses" {
  let b = base()
  assert_eq(
    parse_detail(patched(b.bytes, b.names.sub_at + 16, le(60, 2))),
    "sas7bdat: byte 65684: the name of column 1 names bytes 36 to 96 of a text block of 52 bytes",
  )
  let bytes = patched(b.bytes, b.formats[1].sub_at + 36, le(50, 2))
  let bytes = patched(bytes, b.formats[1].sub_at + 38, le(4, 2))
  assert_eq(
    parse_detail(bytes),
    "sas7bdat: byte 65516: the format of column 2 names bytes 50 to 54 of a text block of 52 bytes",
  )
}

// ---------------------------------------------------------------- resolving

///|
test "a file with no row-size subheader anywhere refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.at + 4, 0)),
    "sas7bdat: byte 1024: the pages hold no row-size subheader",
  )
}

///|
test "a file with no column-count subheader anywhere refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.column_size.at + 4, 0)),
    "sas7bdat: byte 1024: the pages hold no column-count subheader",
  )
}

///|
test "a row length of zero, or longer than a page, refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.sub_at + 20, 0)),
    "sas7bdat: byte 66100: the row length is 0",
  )
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.sub_at + 20, 70000)),
    "sas7bdat: byte 66100: the row length 70000 exceeds the page length 65536",
  )
}

///|
test "columns declared without a row length to hold them refuse" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.column_size.sub_at + 4, 0)),
    "sas7bdat: byte 66072: the file declares no column, but rows of 16 bytes",
  )
}

///|
test "fewer names than columns, or fewer attributes, refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.column_size.sub_at + 4, 5)),
    "sas7bdat: byte 66072: the file declares 5 columns but names 2",
  )
  // The attribute subheader cut to the length of one entry.
  let bytes = u32_at(b.bytes, b.attributes.at + 4, 32)
  assert_eq(
    parse_detail(bytes),
    "sas7bdat: byte 66072: the file declares 2 columns but describes 1",
  )
}

///|
test "a column spanning past the row refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.attributes.sub_at + 12, 12)),
    "sas7bdat: byte 65640: column 1 spans bytes 12 to 20 of a 16-byte row",
  )
}

///|
test "a column type that is neither numeric nor character refuses by name" {
  let b = base()
  assert_eq(
    unsupported_detail(replaced(b.bytes, b.attributes.sub_at + 12 + 10, 3)),
    "sas7bdat: byte 65650: column 1 is of type 3, which is neither numeric (1) nor character (2)",
  )
}

///|
test "a column that declares no bytes refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.attributes.sub_at + 16, 0)),
    "sas7bdat: byte 65644: column 1 declares no bytes",
  )
}

///|
test "a numeric column wider than eight bytes refuses" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.attributes.sub_at + 16, 12)),
    "sas7bdat: byte 65644: column 1 is numeric and declares 12 bytes, more than the 8 a number takes",
  )
}

///|
test "a row stored as a subheader that is not one row long refuses" {
  let b = base()
  assert_eq(
    parse_detail(crafted(b, b"\xde\xad\xbe\xef\x00\x00\x00\x00\x00\x00", 0, 1)),
    "sas7bdat: byte 1232: a row stored as a subheader of 10 bytes, and rows are 16 bytes",
  )
}

///|
test "rows a page cannot hold refuse" {
  let b = base()
  assert_eq(
    parse_detail(u32_at(b.bytes, b.row_size.sub_at + 60, 5000)),
    "sas7bdat: byte 1168: 5000 rows of 16 bytes do not fit in the page, which holds 65392 bytes from here",
  )
}

///|
test "a row count the pages cannot hold refuses" {
  let b = base()
  let bytes = u32_at(b.bytes, b.row_size.sub_at + 60, 1)
  assert_eq(
    parse_detail(bytes),
    "sas7bdat: byte 66104: the file declares 2 rows and its pages hold 1",
  )
}

///|
test "a row marked compressed in a file that names no compression refuses" {
  let b = base()
  assert_eq(
    parse_detail(
      crafted(
        b, b"\x8f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        4, 1,
      ),
    ),
    "sas7bdat: byte 1232: a row is marked compressed, and the file's text names no row compression",
  )
}

///|
test "a compression name this reader does not decode refuses by name" {
  // The 32-bit reference table written with row compression, its name
  // changed.
  let bytes = fixture(".github/fixtures/sas7bdat/reference/rle32_pyrs.sas7bdat")
  let mut at = -1
  let end = bytes.length() - 7
  for i in 0..<end {
    if bytes[i] == b'S' &&
      bytes[i + 1] == b'A' &&
      bytes[i + 2] == b'S' &&
      bytes[i + 3] == b'Y' &&
      bytes[i + 4] == b'Z' &&
      bytes[i + 5] == b'C' &&
      bytes[i + 6] == b'R' {
      at = i
      break
    }
  }
  if at < 0 {
    fail("the compressed table names no compression")
  }
  let literal = Bytes::makei(8, i => if i == 7 { b'9' } else { bytes[at + i] })
  assert_eq(
    unsupported_detail(patched(bytes, at, literal)),
    "sas7bdat: byte \{at}: the file names its row compression SASYZCR9, which this reader does not decode (it decodes SASYZCRL and SASYZCR2)",
  )
}

///|
test "a compressed row that does not expand to one row refuses" {
  let b = base()
  // The CHAR method's name written into the text block, then a row that
  // expands to six bytes: a copy command for six, and the bytes.
  let bytes = patched(b.bytes, b.text.sub_at + 16, b"SASYZCRL")
  let stream = Bytes::makei(7, i => if i == 0 { b'\x85' } else { b'\x00' })
  assert_eq(
    parse_detail(crafted({ ..b, bytes, }, stream, 4, 1)),
    "sas7bdat: byte 1232: a compressed row expands to 6 bytes, and rows are 16 bytes",
  )
  // One that expands past the row: a copy command for seventeen.
  let stream = Bytes::makei(18, i => if i == 0 { b'\x90' } else { b'\x00' })
  assert_eq(
    parse_detail(crafted({ ..b, bytes, }, stream, 4, 1)),
    "sas7bdat: byte 1232: a compressed row expands past the 16 bytes of a row",
  )
  // The BINARY method's name, and a row that expands to fifteen: a
  // control word of zeros, then fifteen literals and no more.
  let bytes = patched(b.bytes, b.text.sub_at + 16, b"SASYZCR2")
  let stream = Bytes::makei(17, _ => b'\x00')
  assert_eq(
    parse_detail(crafted({ ..b, bytes, }, stream, 4, 1)),
    "sas7bdat: byte 1232: a compressed row expands to 15 bytes, and rows are 16 bytes",
  )
}

///|
test "a text cell, or a name, that is not well-formed UTF-8 refuses at the byte" {
  let b = base()
  // Column 2 lies at byte 8 of each row: "x" and seven blanks.
  assert_eq(
    parse_detail(replaced(b.bytes, b.rows_at + 8, b'\xff')),
    "sas7bdat: byte 1176: a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
  )
  // After the "x": a two-byte sequence whose continuation is not one; the
  // byte named is the one the sequence starts with.
  let bytes = patched(b.bytes, b.rows_at + 9, b"\xc3\xff")
  assert_eq(
    parse_detail(bytes),
    "sas7bdat: byte 1177: a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
  )
  // A name: "a" lies at the text block's byte 36.
  assert_eq(
    parse_detail(replaced(b.bytes, b.text.sub_at + 4 + 36, b'\xff')),
    "sas7bdat: byte 65748: a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
  )
}
