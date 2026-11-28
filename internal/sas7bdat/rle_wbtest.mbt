// Whitebox tests of the CHAR method's decompressor: every command decodes
// to the bytes it names, commands chain in one stream, and every refusal
// carries its text. The streams are built by hand, one command at a
// time, with an `Array[Byte]` of one row's length to expand into.

///|
/// A byte array of `count` bytes, each `value`.
fn filled(count : Int32, value : Byte) -> Array[Byte] {
  Array::make(count, value)
}

///|
/// The byte array of a literal string.
fn letters(text : String) -> Array[Byte] {
  let units = text.code_units()
  Array::makei(units.length(), i => units[i].to_int().to_byte())
}

///|
/// Whether two byte arrays hold the same bytes.
fn same_bytes(got : Array[Byte], want : Array[Byte]) -> Bool {
  if got.length() != want.length() {
    return false
  }
  let mut same = true
  for i in 0..<got.length() {
    if got[i] != want[i] {
      same = false
    }
  }
  same
}

///|
/// The text the decompressor's `ParseError` carries for a stream.
fn rle_detail(stream : Bytes, out : Array[Byte]) -> String raise {
  let outcome : Result[_, @types.DataError] = Ok(
    rle_decompress(stream, 0L, stream.length().to_int64(), out),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(written) => fail("the stream expanded to \{written} bytes")
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(text))) =>
      text
    Err(other) => fail("the decompressor raised \{other}, not a ParseError")
  }
}

///|
test "every CHAR command expands to the bytes it names" {
  // Command 0 copies 64 to 4159 bytes: a length byte, then the bytes.
  let stream = b"\x00\x00" + Bytes::makei(64, i => (i * 3).to_byte())
  let out = filled(64, 0)
  assert_eq(rle_decompress(stream, 0L, 66L, out), 64L)
  assert_true(same_bytes(out, Array::makei(64, i => (i * 3).to_byte())))
  // The low nibble carries the fifth bit pair of the count.
  let stream = b"\x01\xff" + Bytes::makei(575, _ => b'\x7e')
  let out = filled(575, 0)
  assert_eq(rle_decompress(stream, 0L, 577L, out), 575L)
  assert_true(same_bytes(out, filled(575, b'\x7e')))
  // Command 1 copies 4160 to 8255 bytes.
  let stream = b"\x10\x00" + Bytes::makei(4160, _ => b'\x11')
  let out = filled(4160, 0)
  assert_eq(rle_decompress(stream, 0L, 4162L, out), 4160L)
  assert_true(same_bytes(out, filled(4160, b'\x11')))
  let stream = b"\x1f\xff" + Bytes::makei(8255, _ => b'\x22')
  let out = filled(8255, 0)
  assert_eq(rle_decompress(stream, 0L, 8257L, out), 8255L)
  // Command 2 copies 96 to 111 bytes.
  let stream = b"\x20" + Bytes::makei(96, _ => b'\x33')
  let out = filled(96, 0)
  assert_eq(rle_decompress(stream, 0L, 97L, out), 96L)
  let stream = b"\x2f" + Bytes::makei(111, _ => b'\x33')
  let out = filled(111, 0)
  assert_eq(rle_decompress(stream, 0L, 112L, out), 111L)
}

///|
test "every CHAR fill command expands to the run it names" {
  // Command 4 fills 18 to 4113 bytes with a byte of its own.
  let out = filled(18, 0)
  assert_eq(rle_decompress(b"\x40\x00\xab", 0L, 3L, out), 18L)
  assert_true(same_bytes(out, filled(18, b'\xab')))
  let out = filled(4113, 0)
  assert_eq(rle_decompress(b"\x4f\xff\xcd", 0L, 3L, out), 4113L)
  assert_true(same_bytes(out, filled(4113, b'\xcd')))
  // Commands 5, 6 and 7 fill 17 to 4112 bytes with an at-sign, a blank
  // and a NUL.
  let out = filled(17, b'x')
  assert_eq(rle_decompress(b"\x50\x00", 0L, 2L, out), 17L)
  assert_true(same_bytes(out, filled(17, b'@')))
  let out = filled(4112, 0)
  assert_eq(rle_decompress(b"\x5f\xff", 0L, 2L, out), 4112L)
  assert_true(same_bytes(out, filled(4112, b'@')))
  let out = filled(17, 0)
  assert_eq(rle_decompress(b"\x60\x00", 0L, 2L, out), 17L)
  assert_true(same_bytes(out, filled(17, b' ')))
  let out = filled(4112, 0)
  assert_eq(rle_decompress(b"\x6f\xff", 0L, 2L, out), 4112L)
  assert_true(same_bytes(out, filled(4112, b' ')))
  let out = filled(17, b'x')
  assert_eq(rle_decompress(b"\x70\x00", 0L, 2L, out), 17L)
  assert_true(same_bytes(out, filled(17, 0)))
  // Command 12 fills 3 to 18 bytes with a byte of its own.
  let out = filled(3, 0)
  assert_eq(rle_decompress(b"\xc0\x9d", 0L, 2L, out), 3L)
  assert_true(same_bytes(out, filled(3, b'\x9d')))
  let out = filled(18, 0)
  assert_eq(rle_decompress(b"\xcf\x9d", 0L, 2L, out), 18L)
  assert_true(same_bytes(out, filled(18, b'\x9d')))
  // Commands 13, 14 and 15 fill 2 to 17 bytes.
  let out = filled(17, b'x')
  assert_eq(rle_decompress(b"\xd0", 0L, 1L, out), 2L)
  assert_eq(rle_decompress(b"\xdf", 0L, 1L, out), 17L)
  assert_true(same_bytes(out, filled(17, b'@')))
  assert_eq(rle_decompress(b"\xe0", 0L, 1L, out), 2L)
  assert_eq(rle_decompress(b"\xef", 0L, 1L, out), 17L)
  assert_true(same_bytes(out, filled(17, b' ')))
  assert_eq(rle_decompress(b"\xf0", 0L, 1L, out), 2L)
  assert_eq(rle_decompress(b"\xff", 0L, 1L, out), 17L)
  assert_true(same_bytes(out, filled(17, 0)))
}

///|
test "every CHAR short copy command copies the bytes it names" {
  // Commands 8 to 11 copy 1 to 64 bytes straight out of the stream.
  let counts : ReadOnlyArray[(Int32, Int32)] = [
    (0x80, 1),
    (0x8f, 16),
    (0x90, 17),
    (0x9f, 32),
    (0xa0, 33),
    (0xaf, 48),
    (0xb0, 49),
    (0xbf, 64),
  ]
  for (control, count) in counts {
    let payload = Array::makei(count, i => (i + 1).to_byte())
    let stream = Bytes::makei(count + 1, i => {
      if i == 0 {
        control.to_byte()
      } else {
        payload[i - 1]
      }
    })
    let out = filled(count, 0)
    assert_eq(
      rle_decompress(stream, 0L, (count + 1).to_int64(), out),
      count.to_int64(),
    )
    assert_true(same_bytes(out, payload))
  }
}

///|
test "CHAR commands chain in one stream, and an empty stream expands to nothing" {
  // A copy of three, two blanks, three of one byte, two NULs.
  let out = filled(10, b'x')
  let written = rle_decompress(b"\x82abc\xe0\xc0z\xf0", 0L, 8L, out)
  assert_eq(written, 10L)
  assert_true(same_bytes(out, letters("abc  zzz") + filled(2, 0)))
  assert_eq(rle_decompress(b"", 0L, 0L, filled(4, 0)), 0L)
  // The stream may sit anywhere in the bytes: only `at` and `length`
  // are read.
  let stream = b"??\x83wxyz!!"
  let out = filled(4, 0)
  assert_eq(rle_decompress(stream, 2L, 5L, out), 4L)
  assert_true(same_bytes(out, letters("wxyz")))
}

///|
test "a CHAR control byte that names no command refuses" {
  assert_eq(
    rle_detail(b"\x30", filled(4, 0)),
    "sas7bdat: byte 0: a compressed row carries the control byte 48, which names no command",
  )
  assert_eq(
    rle_detail(b"\x80a\x3f", filled(8, 0)),
    "sas7bdat: byte 2: a compressed row carries the control byte 63, which names no command",
  )
}

///|
test "a CHAR stream that ends inside a command's operands refuses" {
  assert_eq(
    rle_detail(b"\x00", filled(100, 0)),
    "sas7bdat: byte 0: a compressed row ends inside a command's operands",
  )
  assert_eq(
    rle_detail(b"\x40\x05", filled(100, 0)),
    "sas7bdat: byte 0: a compressed row ends inside a command's operands",
  )
  assert_eq(
    rle_detail(b"\x80a\x50", filled(100, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a command's operands",
  )
}

///|
test "a CHAR copy command that runs past its stream refuses" {
  assert_eq(
    rle_detail(b"\x80", filled(4, 0)),
    "sas7bdat: byte 0: a compressed row ends inside a copy command",
  )
  assert_eq(
    rle_detail(b"\x83ab", filled(4, 0)),
    "sas7bdat: byte 0: a compressed row ends inside a copy command",
  )
}

///|
test "a CHAR row that expands past the row refuses, copying or filling" {
  let stream = b"\x90" + Bytes::makei(17, _ => b'\x01')
  assert_eq(
    rle_detail(stream, filled(4, 0)),
    "sas7bdat: byte 0: a compressed row expands past the 4 bytes of a row",
  )
  assert_eq(
    rle_detail(b"\xe5", filled(4, 0)),
    "sas7bdat: byte 0: a compressed row expands past the 4 bytes of a row",
  )
  assert_eq(
    rle_detail(b"\x82abc\xd1", filled(4, 0)),
    "sas7bdat: byte 4: a compressed row expands past the 4 bytes of a row",
  )
}
