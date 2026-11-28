// content.xml's bytes as the text the XML reader is handed, and the turn
// from a position that reader names back to a byte of the entry.

///|
/// content.xml decoded: the text the XML reader reads, and what a position
/// it names — a UTF-16 code unit counted from the text's start — is in
/// the entry's bytes.
priv struct Document {
  text : String
  // UTF-16: two bytes a code unit, the byte-order mark kept as the first.
  wide : Bool
  // UTF-8: the bytes of byte-order mark cut off before the text.
  origin : Int32
}

///|
/// content.xml as text. UTF-16 by its byte-order mark, in that byte order,
/// the encoding its declaration names not looked at; otherwise UTF-8,
/// strictly, with a byte-order mark skipped — unless the declaration names
/// another encoding, which refuses by name.
fn decode_content(content : BytesView) -> Document raise @types.DataError {
  if content.length() >= 2 {
    let first = content[0].to_int()
    let second = content[1].to_int()
    if (first == 0xFF && second == 0xFE) || (first == 0xFE && second == 0xFF) {
      let order = if first == 0xFF {
        @utf16.Endian::Little
      } else {
        @utf16.Endian::Big
      }
      let text = @utf16.decode(content, endianness=order) catch {
        @utf16.Malformed(tail) =>
          raise bad(
            "ods: content.xml byte \{content.length() - tail.length()} is not valid UTF-16: an odd number of bytes or a lone surrogate",
          )
      }
      return Document::{ text, wide: true, origin: 0, }
    }
  }
  let marked = content.length() >= 3 &&
    content[0] == b'\xEF' &&
    content[1] == b'\xBB' &&
    content[2] == b'\xBF'
  let body = if marked { content[3:] } else { content }
  let origin = if marked { 3 } else { 0 }
  let declared = declared_encoding(body)
  match declared {
    Some(name) =>
      if !is_utf8(name) {
        raise nope(
          "ods: content.xml declares the \{name} encoding, which this reader does not decode",
        )
      }
    None => ()
  }
  let text = @utf8.decode(body) catch {
    @utf8.Malformed(tail) =>
      raise bad(
        "ods: content.xml byte \{body.length() - tail.length() + origin} is not valid UTF-8",
      )
  }
  Document::{ text, wide: false, origin, }
}

///|
/// The byte of the entry a position of the text names. With UTF-16 it is
/// two bytes a code unit; with UTF-8 it is the bytes the characters before
/// the position take, the skipped mark included — never more than the
/// entry holds, since those bytes are the entry's own. A position before
/// the text's start names its first byte.
fn Document::byte(self : Document, units : Int32) -> Int32 {
  if units <= 0 {
    return if self.wide { 0 } else { self.origin }
  }
  if self.wide {
    // The entry holds at most 2^31 - 1 bytes, so at most 2^30 code units.
    return (units.to_int64() * 2L).to_int()
  }
  let mut byte = self.origin.to_int64()
  let mut seen = 0
  for c in self.text {
    if seen >= units {
      break
    }
    let code = c.to_int()
    seen += if code > 0xFFFF { 2 } else { 1 }
    byte += (if code < 0x80 {
      1
    } else if code < 0x800 {
      2
    } else if code < 0x10000 {
      3
    } else {
      4
    }).to_int64()
  }
  byte.to_int()
}

///|
/// The encoding a document's declaration names, lower-cased, or nothing:
/// no declaration, a declaration naming no encoding, or a name the
/// declaration leaves unclosed. The bytes are read one to a character,
/// since a declaration names its encoding in ASCII.
fn declared_encoding(bytes : BytesView) -> String? {
  if bytes.length() < 6 ||
    bytes[0] != b'<' ||
    bytes[1] != b'?' ||
    bytes[2] != b'x' ||
    bytes[3] != b'm' ||
    bytes[4] != b'l' ||
    !is_xml_space(bytes[5]) {
    return None
  }
  let end = match find_word(bytes, 5, "?>") {
    Some(end) => end
    None => return None
  }
  // The name is looked for inside the declaration alone, as a word.
  let at = match find_word(bytes, 6, "encoding") {
    Some(at) => at
    None => return None
  }
  if at + 8 > end || !is_xml_space(bytes[at - 1]) {
    return None
  }
  let mut i = at + 8
  while i < end && is_xml_space(bytes[i]) {
    i += 1
  }
  if i >= end || bytes[i] != b'=' {
    return None
  }
  i += 1
  while i < end && is_xml_space(bytes[i]) {
    i += 1
  }
  if i >= end {
    return None
  }
  let quote = bytes[i]
  if quote != b'"' && quote != b'\'' {
    return None
  }
  i += 1
  let start = i
  while i < end && bytes[i] != quote {
    i += 1
  }
  if i >= end {
    return None
  }
  Some(latin1(bytes[start:i]).to_lower())
}

///|
/// Where an ASCII word is first spelled in a byte view from `from` on, or
/// nowhere.
fn find_word(bytes : BytesView, from : Int32, word : String) -> Int32? {
  let units = word.code_units()
  let length = units.length()
  if bytes.length() < length {
    return None
  }
  let last = bytes.length() - length
  let mut at = from
  while at <= last {
    let mut same = true
    for k in 0..<length {
      if bytes[at + k].to_int() != units[k].to_int() {
        same = false
        break
      }
    }
    if same {
      return Some(at)
    }
    at += 1
  }
  None
}

///|
/// Whether a byte is one of XML's whitespace characters.
fn is_xml_space(byte : Byte) -> Bool {
  let code = byte.to_int()
  code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D
}

///|
/// Whether an encoding's name, lower-cased, is UTF-8's.
fn is_utf8(name : String) -> Bool {
  name == "utf-8" || name == "utf8"
}

///|
/// A byte view one byte to one character — the whole of US-ASCII and of
/// ISO-8859-1.
fn latin1(bytes : BytesView) -> String {
  let out = StringBuilder()
  for b in bytes {
    out.write_char(b.to_char())
  }
  out.to_string()
}
