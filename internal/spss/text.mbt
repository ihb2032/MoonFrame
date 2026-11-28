///|
/// The text encodings this reader decodes: UTF-8, Latin-1 (ISO 8859-1),
/// and windows-1252 — which agrees with Latin-1 outside the printable
/// range 0x80 to 0x9F, where the windows code page defines punctuation.
/// One encoding serves the whole file: names, labels and string cells.
priv enum Encoding {
  Utf8
  Latin1
  Windows1252
}

///|
/// The encoding a file declares. `name` is the raw text of its
/// character encoding record when that record is present and spells
/// something; `code` is the character code its machine integer info
/// record carries when that record is present, and −1 when it is not.
/// The record's name wins, a file carrying both agreeing with itself in
/// practice and the name being the finer of the two. The nominal ASCII
/// codes 2 and 3 decode as windows-1252, an ASCII superset, because
/// files carrying them hold eight-bit text in practice. A file that
/// declares nothing decodes as UTF-8. Anything else this reader does
/// not decode is refused by name.
fn encoding_declared(
  name : Bytes?,
  code : Int64,
) -> Encoding raise @types.DataError {
  if name is Some(raw) {
    let cut = cut_blank(raw)
    if cut.length() > 0 {
      match normal_name(cut) {
        "UTF8" => return Utf8
        "ISO88591" | "LATIN1" | "L1" => return Latin1
        "WINDOWS1252" | "CP1252" | "MSANSI" => return Windows1252
        _ =>
          raise nope(
            "the file declares the character encoding \{plain_text(cut, false)}, which this reader does not decode",
          )
      }
    }
  }
  match code {
    -1L | 65001L => Utf8
    28591L => Latin1
    2L | 3L | 1252L => Windows1252
    1L =>
      raise nope(
        "the file declares character code 1, EBCDIC, which this reader does not decode",
      )
    _ =>
      raise nope(
        "the file declares character code \{code}, which this reader does not decode",
      )
  }
}

///|
/// A string cell's bytes as text, in `encoding`: the trailing blanks
/// are cut, so an all-blank cell spells the empty string (its NUL bytes
/// are dropped as it is gathered). `where_` names the cell in a
/// refusal.
fn cell_text(
  raw : Array[Byte],
  encoding : Encoding,
  where_ : String,
) -> String raise @types.DataError {
  let mut cut = raw.length()
  while cut > 0 && raw[cut - 1] == b' ' {
    cut -= 1
  }
  text_of(Bytes::makei(cut, i => raw[i]), encoding, where_)
}

///|
/// `bytes` as text in `encoding`, nothing trimmed. A string whose bytes
/// are not well-formed UTF-8 is refused, naming `where` — except for a
/// multi-byte character the field had no room for at its very end, which
/// is cut, since files written that way are met in practice and the rest
/// of the string is intact.
fn text_of(
  bytes : BytesView,
  encoding : Encoding,
  where_ : String,
) -> String raise @types.DataError {
  match encoding {
    Utf8 =>
      match utf8_try(bytes) {
        Ok(text) => text
        Err(_) =>
          match truncated_tail(bytes) {
            Some(end) =>
              match utf8_try(bytes[:end]) {
                Ok(text) => text
                Err(_) =>
                  raise bad("\{where_}: the text is not well-formed UTF-8")
              }
            None => raise bad("\{where_}: the text is not well-formed UTF-8")
          }
      }
    Latin1 => plain_text(bytes, false)
    Windows1252 => plain_text(bytes, true)
  }
}

///|
/// `bytes` decoded as UTF-8, or a marker that the decoder refused them.
fn utf8_try(bytes : BytesView) -> Result[String, Unit] {
  Ok(@utf8.decode(bytes)) catch {
    _ => Err(())
  }
}

///|
/// Where a truncated multi-byte character starts when `bytes` end
/// inside one, so that everything before that character decodes;
/// `None` when the bytes are well-formed UTF-8, or are malformed
/// anywhere but at such an end.
fn truncated_tail(bytes : BytesView) -> Int32? {
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b = bytes[i].to_int()
    let need = if b < 0x80 {
      0
    } else if b >= 0xC2 && b <= 0xDF {
      1
    } else if b >= 0xE0 && b <= 0xEF {
      2
    } else if b >= 0xF0 && b <= 0xF4 {
      3
    } else {
      return None
    }
    let mut k = 1
    while k <= need && i + k < n {
      let c = bytes[i + k].to_int()
      if c < 0x80 || c > 0xBF {
        return None
      }
      k += 1
    }
    // A sequence of `need` continuation bytes needs `need` bytes after
    // its lead: one that reaches the end is cut.
    if need > 0 && i + need >= n {
      return Some(i)
    }
    i += need + 1
  }
  None
}

///|
/// `bytes` with its trailing blanks and NULs cut.
fn cut_blank(bytes : BytesView) -> BytesView {
  let mut end = bytes.length()
  while end > 0 && (bytes[end - 1] == b' ' || bytes[end - 1] == 0) {
    end -= 1
  }
  bytes[:end]
}

///|
/// `bytes` as a name to match encodings by: upper-cased, with the
/// separators character set names are spelled with dropped.
fn normal_name(bytes : BytesView) -> String {
  let out = StringBuilder()
  for i in 0..<bytes.length() {
    let b = bytes[i].to_int()
    if b >= 97 && b <= 122 {
      out.write_char((b - 32).to_byte().to_char())
    } else if b != 45 && b != 95 && b != 46 && b != 32 {
      out.write_char(bytes[i].to_char())
    }
  }
  out.to_string()
}

///|
/// `bytes` as one character per byte: Latin-1, and windows-1252 once
/// `windows` is set. The five bytes the windows code page leaves
/// unassigned spell the control character of their own number, so that
/// every byte decodes.
fn plain_text(bytes : BytesView, windows : Bool) -> String {
  let out = StringBuilder()
  for i in 0..<bytes.length() {
    let b = bytes[i].to_int()
    if windows && b >= 0x80 && b <= 0x9F {
      out.write_char(windows_char(b))
    } else {
      out.write_char(bytes[i].to_char())
    }
  }
  out.to_string()
}

///|
/// The character a byte of windows-1252's printable range spells.
fn windows_char(b : Int32) -> Char {
  match b {
    0x80 => '\u{20AC}'
    0x82 => '\u{201A}'
    0x83 => '\u{0192}'
    0x84 => '\u{201E}'
    0x85 => '\u{2026}'
    0x86 => '\u{2020}'
    0x87 => '\u{2021}'
    0x88 => '\u{02C6}'
    0x89 => '\u{2030}'
    0x8A => '\u{0160}'
    0x8B => '\u{2039}'
    0x8C => '\u{0152}'
    0x8E => '\u{017D}'
    0x91 => '\u{2018}'
    0x92 => '\u{2019}'
    0x93 => '\u{201C}'
    0x94 => '\u{201D}'
    0x95 => '\u{2022}'
    0x96 => '\u{2013}'
    0x97 => '\u{2014}'
    0x98 => '\u{02DC}'
    0x99 => '\u{2122}'
    0x9A => '\u{0161}'
    0x9B => '\u{203A}'
    0x9C => '\u{0153}'
    0x9E => '\u{017E}'
    0x9F => '\u{0178}'
    _ => b.to_byte().to_char()
  }
}
