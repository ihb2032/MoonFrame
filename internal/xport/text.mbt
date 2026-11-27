// Character data and names as text: the transport file records no
// encoding, and its character variables are read and written as UTF-8.

///|
/// The UTF-8 text in `length` bytes from byte `at`: the string those
/// bytes spell. `Err(at)` names the byte a malformed sequence starts at.
/// `at + length` lies inside the bytes.
fn decode_utf8(
  bytes : Bytes,
  at : Int32,
  length : Int32,
) -> Result[String, Int32] {
  Ok(@utf8.decode(bytes[at:at + length])) catch {
    @utf8.Malformed(tail) => Err(at + length - tail.length())
  }
}

///|
/// The UTF-8 bytes of `text`. A lone UTF-16 surrogate half has no UTF-8
/// spelling, so it is `Err`: the index of the first such code unit.
fn utf8_bytes(text : String) -> Result[Bytes, Int32] {
  match @text.find_unpaired_surrogate(text) {
    Some(at) => Err(at)
    None => Ok(@utf8.encode(text))
  }
}

///|
/// Whether `text` spells a name a variable of the transport format can
/// carry: one to eight characters, each an ASCII letter, a digit or an
/// underscore, and not a digit first.
fn is_variable_name(text : String) -> Bool {
  let units = text.code_units()
  let count = units.length()
  if count < 1 || count > 8 {
    return false
  }
  for i in 0..<count {
    let unit = units[i].to_int()
    let letter = (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A)
    let digit = unit >= 0x30 && unit <= 0x39
    if !(letter || digit || unit == 0x5F) {
      return false
    }
    if i == 0 && digit {
      return false
    }
  }
  true
}

///|
/// Append the ASCII spelling of `text`, padded on the right with blanks
/// to `width` bytes, to `out`. `text` is shorter than `width` and ASCII.
fn push_padded(out : Array[Byte], text : String, width : Int32) -> Unit {
  let units = text.code_units()
  for i in 0..<width {
    out.push(
      if i < units.length() {
        units[i].to_int().to_byte()
      } else {
        b' '
      },
    )
  }
}

///|
/// Append the decimal spelling of `value`, which is zero or more, in
/// `width` digits padded with zeros on the left, to `out`.
fn push_digits(out : Array[Byte], value : Int32, width : Int32) -> Unit {
  let mut left = value
  // The digits as they come off, least significant first.
  let reversed : Array[Byte] = []
  for _ in 0..<width {
    reversed.push((b'0'.to_int() + left % 10).to_byte())
    left = left / 10
  }
  for i in 0..<width {
    out.push(reversed[width - 1 - i])
  }
}
