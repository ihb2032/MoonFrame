// The header's fixed part: the magic, the two alignment bytes that say
// how wide the file's fields are, the byte order, the character set its
// text is in, and the two lengths — of the header and of a page — that
// place every page in the file.

///|
/// The 32 bytes every SAS Version 7/8/9 data set opens with, as hex digits.
const MAGIC : String = "000000000000000000000000c2ea8160b31411cfbd92080009c7318c181f1011"

///|
/// The value of the hex digit at `index` of `text`, which spells bytes:
/// lowercase digits.
fn hex_digit(text : String, index : Int32) -> Int32 {
  let c = text.code_units()[index].to_int()
  if c >= 48 && c <= 57 {
    c - 48
  } else {
    c - 87
  }
}

///|
/// The byte a SAS Version 7/8/9 data set opens with at `i`, for an `i`
/// under 32.
fn magic_byte(i : Int32) -> Int32 {
  hex_digit(MAGIC, 2 * i) * 16 + hex_digit(MAGIC, 2 * i + 1)
}

///|
/// Whether `bytes` opens with the 32 bytes a SAS Version 7/8/9 data set
/// opens with — what tells a data set from another file before either is
/// read. A file shorter than the signature does not.
pub fn opens_data_set(bytes : Bytes) -> Bool {
  if bytes.length() < 32 {
    return false
  }
  for i in 0..<32 {
    if bytes[i].to_int() != magic_byte(i) {
      return false
    }
  }
  true
}

///|
/// What the file's header says about itself: the word size its pages
/// are laid out in, its byte order, the character set its text is in,
/// where its pages start, how long each is, and how many the file holds.
priv struct Header {
  wide : Bool
  little : Bool
  charset : Charset
  header_length : Int64
  page_length : Int64
  pages : Int64
}

///|
/// The character set the header's field at byte 70 names, as this reader
/// decodes it: UTF-8, or a single-byte code page.
priv enum Charset {
  Utf8
  Single(CharsetPage)
}

///|
/// A single-byte code page, as the generated table holds it: the header's
/// code, the name the reference reader's table gives it, and the 128
/// characters bytes 0x80 to 0xFF spell, in order. A byte under 0x80 is
/// ASCII in every page the table holds.
priv struct CharsetPage {
  code : Int32
  name : String
  high : String
}

///|
/// The code page the header names by `code`, if the table holds one.
fn charset_page(code : Int32) -> CharsetPage? {
  for page in charset_pages {
    if page.code == code {
      return Some(page)
    }
  }
  None
}

///|
/// The character set of `code`. Raises `Unsupported`, naming it, when the
/// code names one this reader does not decode — a code page whose
/// characters take several bytes, or no code the format assigns.
fn charset_of(code : Int32) -> Charset raise @types.DataError {
  if code == 20 {
    return Utf8
  }
  if charset_page(code) is Some(page) {
    return Single(page)
  }
  raise refused(
    70L,
    "the character-set field names \{charset_name(code)} (code \{code}), and this reader decodes UTF-8 (code 20) and the single-byte character sets",
  )
}

///|
/// The bytes of one offset or count inside a page, and of one subheader
/// signature: 8 in a 64-bit file, else 4.
fn Header::word(self : Header) -> Int64 {
  if self.wide {
    8L
  } else {
    4L
  }
}

///|
/// The bytes of one subheader pointer on a page: 24 in a 64-bit file,
/// else 12 — the offset, the length, a compression byte, a type byte and
/// padding to a multiple of four.
fn Header::pointer(self : Header) -> Int64 {
  if self.wide {
    24L
  } else {
    12L
  }
}

///|
/// Where a page's type field lies inside the page: byte 32 in a 64-bit
/// file, else byte 16. The block count follows two bytes on, the count of
/// subheader pointers two bytes on again, and the pointers themselves
/// eight bytes on from the type field.
fn Header::lead(self : Header) -> Int64 {
  if self.wide {
    32L
  } else {
    16L
  }
}

///|
/// The character set the header's field names by `code`, for the refusal:
/// the name the reference reader's table gives it, or "an unassigned code"
/// where the table names none. Only a code this reader refuses comes here.
fn charset_name(code : Int32) -> String {
  for (named, name) in charsets_not_decoded {
    if named == code {
      return name
    }
  }
  "an unassigned code"
}

///|
/// Read the header: the magic, the alignment, the byte order, the
/// character set, and the header and page lengths — with the pages
/// counted from the bytes the file holds.
///
/// The alignment byte at 32 says `3` in a 64-bit file and anything else
/// in a 32-bit one; the one at 35 says `3` where four bytes of padding
/// follow the header's fixed part, and the lengths lie after them.
///
/// Raises `ParseError` when the magic is not the data set's, when byte
/// 37 names neither byte order, when the header or a page is shorter
/// than its own fixed part, when the header runs past the end of the
/// file, when no page follows the header, and when the bytes after the
/// header are not a whole number of pages. Raises `Unsupported`, naming
/// the character set, when the header's field at byte 70 names one this
/// reader does not decode.
fn read_header(bytes : Bytes) -> Header raise @types.DataError {
  need(bytes, 0L, 288L, "the header's fixed part")
  for i in 0..<32 {
    let due = magic_byte(i)
    let got = byte_at(bytes, i.to_int64())
    if got != due {
      raise bad(
        i.to_int64(),
        "the magic is not the one a SAS Version 7/8/9 data set opens with (\{got} where \{due} is due)",
      )
    }
  }
  let wide = byte_at(bytes, 32L) == 0x33
  let pad : Int64 = if byte_at(bytes, 35L) == 0x33 { 4L } else { 0L }
  let order = byte_at(bytes, 37L)
  if order != 0 && order != 1 {
    raise bad(
      37L,
      "\{order} names neither byte order (0 is big-endian, 1 little-endian)",
    )
  }
  let little = order == 1
  let code = byte_at(bytes, 70L).to_int()
  let header_length = uint_at(bytes, 196L + pad, 4L, little)
  if header_length < 288UL {
    raise bad(
      196L + pad,
      "the header length is \{header_length}, under the 288 bytes the header's fixed part takes",
    )
  }
  let file_length = bytes.length().to_int64()
  if header_length > file_length.reinterpret_as_uint64() {
    raise bad(
      196L + pad,
      "the header length is \{header_length} and the file ends at byte \{file_length}",
    )
  }
  let page_length = uint_at(bytes, 200L + pad, 4L, little)
  let lead : Int64 = if wide { 32L } else { 16L }
  if page_length < (lead + 8L).reinterpret_as_uint64() {
    raise bad(
      200L + pad,
      "the page length is \{page_length}, under the \{lead + 8L} bytes a page's header takes",
    )
  }
  let rest = file_length - header_length.reinterpret_as_int64()
  if rest == 0L {
    raise bad(
      file_length, "the file ends right after its header, so it holds no page",
    )
  }
  let pages = rest / page_length.reinterpret_as_int64()
  if rest % page_length.reinterpret_as_int64() != 0L {
    raise bad(
      200L + pad,
      "the page length is \{page_length} and \{rest} bytes follow the header: \{pages} whole pages and \{rest % page_length.reinterpret_as_int64()} bytes over",
    )
  }
  // The layout is whole before the character set is judged, so that a
  // file which is both reports what is wrong with its bytes.
  Header::{
    wide,
    little,
    charset: charset_of(code),
    header_length: header_length.reinterpret_as_int64(),
    page_length: page_length.reinterpret_as_int64(),
    pages,
  }
}
