// Whitebox tests of the text helpers: every branch of the UTF-8 decoder
// and of the encoder, the name rule, and the padding and digit helpers.

///|
/// The value of one hex digit.
fn nibble(c : Int32) -> Int32 {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 97 && c <= 102 {
    c - 87
  } else {
    abort("not a hex digit")
  }
}

///|
/// The bytes that `hex` spells, two lowercase digits each.
fn hex_bytes(hex : String) -> Bytes {
  let digits = hex.code_units()
  Bytes::makei(digits.length() / 2, i => {
    ((nibble(digits[2 * i].to_int()) << 4) | nibble(digits[2 * i + 1].to_int())).to_byte()
  })
}

///|
/// `decode_utf8` over the bytes that `hex` spells, as a value an
/// assertion can compare.
fn decoded(hex : String) -> Result[String, Int32] {
  let bytes = hex_bytes(hex)
  decode_utf8(bytes, 0, bytes.length())
}

///|
/// Two lowercase hex digits.
fn two_hex(byte : Byte) -> String {
  let digits = "0123456789abcdef".code_units()
  let value = byte.to_int()
  let out = StringBuilder()
  out.write_char(digits[(value >> 4) & 15].to_int().to_byte().to_char())
  out.write_char(digits[value & 15].to_int().to_byte().to_char())
  out.to_string()
}

///|
/// `utf8_bytes` of `text` in hex, or the code unit it refused at.
fn encoded(text : String) -> Result[String, Int32] {
  match utf8_bytes(text) {
    Ok(out) => {
      let digits = StringBuilder()
      for byte in out {
        digits.write_string(two_hex(byte))
      }
      Ok(digits.to_string())
    }
    Err(at) => Err(at)
  }
}

///|
/// A string of the given UTF-16 code units, assembled directly, so that it
/// may hold a lone surrogate half.
fn units_string(units : ReadOnlyArray[Int32]) -> String {
  let b = StringBuilder()
  for unit in units {
    b.write_char(Int32::unsafe_to_char(unit))
  }
  b.to_string()
}

///|
test "the decoder reads every well-formed shape, at each boundary of it" {
  assert_eq(decoded(""), Ok(""))
  assert_eq(decoded("00"), Ok("\u{0}"))
  assert_eq(decoded("7f"), Ok("\u{7f}"))
  assert_eq(decoded("41c2807a"), Ok("A\u{80}z"))
  assert_eq(decoded("c2bf"), Ok("\u{bf}"))
  assert_eq(decoded("dfbf"), Ok("\u{7ff}"))
  assert_eq(decoded("e0a080"), Ok("\u{800}"))
  assert_eq(decoded("e1bfbf"), Ok("\u{1fff}"))
  assert_eq(decoded("e88080"), Ok("\u{8000}"))
  assert_eq(decoded("ed9fbf"), Ok("\u{d7ff}"))
  assert_eq(decoded("efbfbf"), Ok("\u{ffff}"))
  assert_eq(decoded("f0908080"), Ok("\u{10000}"))
  assert_eq(decoded("f09f9880"), Ok("\u{1f600}"))
  assert_eq(decoded("f48fbfbf"), Ok("\u{10ffff}"))
  assert_eq(decoded("61e697a5f09f988062"), Ok("a日\u{1f600}b"))
}

///|
test "the decoder refuses every ill-formed shape, naming where it starts" {
  for
    hex in [
      "80", "bf", "c080", "c180", "c1bf", "c2", "c241", "e08080", "e09fbf", "eda080",
      "edbfbf", "e0a0", "e0a041", "e0a0c0", "f0808080", "f090", "f09080", "f0908041",
      "f09080c0", "f0904180", "f4908080", "f5808080", "fe", "ff",
    ] {
    if decoded(hex) != Err(0) {
      fail("\"\{hex}\" is not refused at byte 0")
    }
  }
  // The byte the refusal names is the one in the bytes, not one counted
  // from the start of the text; the text before it reads.
  let bytes = b"  \xc3\xa9  "
  assert_eq(decode_utf8(bytes, 2, 1), Err(2))
  assert_eq(decode_utf8(bytes, 2, 2), Ok("é"))
  assert_eq(decoded("41c2"), Err(1))
  assert_eq(decoded("41ff42"), Err(1))
  assert_eq(decoded("c3a9e697"), Err(2))
  assert_eq(decoded("41f090"), Err(1))
}

///|
test "the encoder spells every well-formed shape, and refuses a lone surrogate half" {
  assert_eq(encoded(""), Ok(""))
  assert_eq(encoded("a"), Ok("61"))
  assert_eq(encoded("\u{7f}\u{80}\u{7ff}"), Ok("7fc280dfbf"))
  assert_eq(encoded("é"), Ok("c3a9"))
  assert_eq(encoded("日"), Ok("e697a5"))
  // A surrogate pair is one code point of four bytes.
  assert_eq(encoded("\u{1f600}"), Ok("f09f9880"))
  assert_eq(encoded(units_string([0xD83D, 0xDE00])), Ok("f09f9880"))
  assert_eq(encoded("aé日\u{1f600}z"), Ok("61c3a9e697a5f09f98807a"))
  assert_eq(encoded("\u{10ffff}"), Ok("f48fbfbf"))
  // A high half alone, before a plain character and at the end; a low half
  // alone; two high halves.
  assert_eq(encoded(units_string([0xD800, 0x78])), Err(0))
  assert_eq(encoded(units_string([0x61, 0x62, 0xD83D])), Err(2))
  assert_eq(encoded(units_string([0xDC00])), Err(0))
  assert_eq(encoded(units_string([0xD83D, 0xD83D])), Err(0))
  // A low half after a high one at the very end of the text is one point.
  assert_eq(encoded(units_string([0x61, 0xDBFF, 0xDFFF])), Ok("61f48fbfbf"))
  // Every text the decoder reads encodes back to its own bytes.
  for
    hex in [
      "41c2807a", "c2bf", "e0a080", "ed9fbf", "efbfbf", "f0908080", "f48fbfbf", "61e697a5f09f988062",
    ] {
    let text = match decoded(hex) {
      Ok(text) => text
      Err(at) => fail("\{hex} refused at \{at}")
    }
    assert_eq(encoded(text), Ok(hex))
  }
}

///|
test "a variable name is one to eight ASCII letters, digits or underscores, not a digit first" {
  for name in ["a", "_", "_1234567", "abcdefgh", "A1b2C3d4", "Z9", "x_"] {
    if !is_variable_name(name) {
      fail("\"\{name}\" is a name the format holds")
    }
  }
  for
    name in [
      "", "abcdefghi", "1abc", "1", "é", "a b", "a-b", "a.b", "日本", "a\u{0}b",
      "        ",
    ] {
    if is_variable_name(name) {
      fail("\"\{name}\" is not a name the format holds")
    }
  }
}

///|
test "text is padded with blanks on the right, and numbers with zeros on the left" {
  let out : Array[Byte] = []
  push_padded(out, "ab", 4)
  push_padded(out, "", 2)
  push_padded(out, "wxyz", 4)
  assert_eq(out.map(two_hex).join(""), "6162202020207778797a")
  let digits : Array[Byte] = []
  push_digits(digits, 140, 10)
  push_digits(digits, 7, 2)
  push_digits(digits, 0, 1)
  push_digits(digits, 2147483647, 10)
  let spelled = StringBuilder()
  for byte in digits {
    spelled.write_char(byte.to_char())
  }
  assert_eq(spelled.to_string(), "00000001400702147483647")
}
