// Whitebox round-trips for the snappy raw codec — the literal-only
// compressor's stream through the real decompressor, and the
// decompressor's own back-reference spellings decoded from hand-built
// bytes.

///|
test "snappy literal round-trip across sizes" {
  for len in [0, 1, 5, 6, 7, 60, 100, 1000] {
    let input = Bytes::makei(len, i => (i * 31 % 251).to_byte())
    match snappy_decompress(snappy_compress_literal(input)) {
      Some(out) => assert_eq(out, input)
      None => fail("literal stream refused at length \{len}")
    }
  }
}

///|
test "snappy decodes back references from hand-built bytes" {
  // "abc" then a copy2 of length 4 at offset 3 → "abcabca" (7 bytes:
  // the literal plus four copied). Preamble: length 7. Literal "abc":
  // bytes a b c. Copy2: tag 0x02|(4-1)<<2 = 0x0E, offset LE 0x0003.
  let stream = b"\x07\x08abc\x0E\x03\x00"
  match snappy_decompress(stream) {
    Some(out) => {
      // The bytes, compared as bytes — the string rendering is not the
      // question here.
      assert_eq(out.length(), 7)
      assert_eq(out[0], 'a'.to_int().to_byte())
      assert_eq(out[3], 'a'.to_int().to_byte())
      assert_eq(out[6], 'a'.to_int().to_byte())
    }
    None => fail("copy2 stream refused")
  }
  // A copy1 of length 4 at offset 1 over one literal "x": "xxxxx"
  // (length 5). Copy1 tag: 0x01 | (4-4)<<2 | offset_high<<5, offset
  // 0x01 → tag 0x01, next byte 0x01.
  let rep = b"\x05\x00x\x01\x01"
  match snappy_decompress(rep) {
    Some(out) => {
      // Compared as bytes — the string rendering of raw bytes is not
      // the question here.
      assert_eq(out.length(), 5)
      for i in 0..<5 {
        assert_eq(out[i], 'x'.to_int().to_byte())
      }
    }
    None => fail("copy1 stream refused")
  }
  // An offset behind the start refuses.
  assert_true(snappy_decompress(b"\x04\x08ab\x0E\x09\x00") is None)
}

///|
test "snappy refuses the cut copy spellings" {
  // One literal byte rides tag 0x00 (length (0>>2)+1 = 1), so every
  // copy below starts from `written = 1` and the offsets are decoded
  // against a stream the caller can cut exactly where each arm reads.
  // A copy4 (low bits 11) whose offset bytes end early: tag (4-1)<<2|3
  // = 0x13, then only one offset byte.
  assert_true(snappy_decompress(b"\x05\x00a\x13\x01") is None)
  // A fully spelled copy4 whose offset is zero: behind the start.
  assert_true(snappy_decompress(b"\x05\x00a\x13\x00\x00\x00\x00") is None)
  // A wide literal header (60-plus extra bytes) whose extra-byte run
  // itself is cut.
  assert_true(snappy_decompress(b"\x08\xF0") is None)
  // A copy1 whose offset byte is missing.
  assert_true(snappy_decompress(b"\x06\x00a\x21") is None)
  // A copy2 whose low offset byte is missing.
  assert_true(snappy_decompress(b"\x06\x00a\x0E") is None)
  // A copy2 whose high offset byte is missing.
  assert_true(snappy_decompress(b"\x06\x00a\x0E\x03") is None)
  // A copy2 whose offset sits behind the start (255 past one byte).
  assert_true(snappy_decompress(b"\x06\x00a\x0E\xFF\x00") is None)
}
