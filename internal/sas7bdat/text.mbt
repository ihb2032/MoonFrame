// Text: the bytes a cell, a column name or a format holds, decoded as
// the header's character-set field says — UTF-8, or one byte to one
// character through the code page the header names.

///|
/// The `length` bytes at `at`, one byte to one character through `page`:
/// a byte under 0x80 is ASCII, and one from 0x80 on is the character the
/// page spells. `origin` is the offset in the file that byte `at` of
/// `bytes` stands for; a byte the page leaves undefined refuses, naming
/// the byte and the page.
fn single_byte_text(
  bytes : Bytes,
  at : Int64,
  length : Int64,
  origin : Int64,
  page : CharsetPage,
) -> String raise @types.DataError {
  need(bytes, at, length, "a text field")
  let units = page.high.code_units()
  let base = at.to_int()
  let out = StringBuilder()
  for i in 0..<length.to_int() {
    let byte = bytes[base + i].to_int()
    if byte < 0x80 {
      out.write_char(bytes[base + i].to_char())
    } else if units[byte - 0x80] == 0xFFFD {
      raise bad(
        origin + i.to_int64(),
        "a text field holds byte \{spelled_byte(byte)}, which the \{page.name} character set leaves undefined",
      )
    } else {
      out.write_substring(page.high, byte - 0x80, 1)
    }
  }
  out.to_string()
}

///|
/// A byte as two uppercase hex digits, with the prefix: 0x81.
fn spelled_byte(byte : Int32) -> String {
  let digits = "0123456789ABCDEF".code_units()
  "0x\{digits[byte >> 4].to_int().to_byte().to_char()}\{digits[byte & 15].to_int().to_byte().to_char()}"
}

///|
/// The `length` bytes at `at`, one byte to one character through Latin-1,
/// which maps every byte: for the one text a refusal quotes whatever the
/// file's character set (a compression name, which the format spells in
/// ASCII), so that the refusal cannot itself be refused.
fn latin1_text(
  bytes : Bytes,
  at : Int64,
  length : Int64,
) -> String raise @types.DataError {
  need(bytes, at, length, "a text field")
  let out = StringBuilder()
  let base = at.to_int()
  for i in 0..<length.to_int() {
    out.write_char(bytes[base + i].to_char())
  }
  out.to_string()
}

///|
/// The `length` bytes at `at` of `bytes`, decoded as the header says.
/// `origin` is the offset in the file that byte `at` of `bytes` stands
/// for; it names the byte when the text cannot be decoded.
fn decode_text(
  bytes : Bytes,
  at : Int64,
  length : Int64,
  origin : Int64,
  header : Header,
) -> String raise @types.DataError {
  if length == 0L {
    return ""
  }
  match header.charset {
    Utf8 => utf8_text(bytes, at, length, origin)
    Single(page) => single_byte_text(bytes, at, length, origin, page)
  }
}

///|
/// The `length` bytes at `at`, as UTF-8: the one sequence that is not
/// well-formed refuses at the byte that starts it.
fn utf8_text(
  bytes : Bytes,
  at : Int64,
  length : Int64,
  origin : Int64,
) -> String raise @types.DataError {
  need(bytes, at, length, "a text field")
  @utf8.decode(
    bytes.clamped_view(start=at.to_int(), end=(at + length).to_int()),
  ) catch {
    @utf8.Malformed(tail) =>
      raise bad(
        origin + length - tail.length().to_int64(),
        "a text field is not well-formed UTF-8; this byte starts a sequence that is not one",
      )
  }
}

///|
/// A character cell: the `width` bytes at `at` of `row`, with the
/// trailing blanks and NULs a fixed-width field is padded with cut, and
/// decoded as the header says. A cell of nothing but padding is the
/// empty string. `origin` is the cell's first byte's offset in the file,
/// for the refusal `decode_text` raises.
fn cell_text(
  row : Array[Byte],
  at : Int32,
  width : Int32,
  origin : Int64,
  header : Header,
) -> String raise @types.DataError {
  let mut length = width
  while length > 0 &&
        (row[at + length - 1] == b' ' || row[at + length - 1] == b'\x00') {
    length -= 1
  }
  if length == 0 {
    return ""
  }
  let cell = Bytes::makei(length, i => row[at + i])
  decode_text(cell, 0L, length.to_int64(), origin, header)
}
