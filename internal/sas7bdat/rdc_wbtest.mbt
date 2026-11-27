// Whitebox tests of the BINARY method's decompressor: a literal, a short
// and a long run, a short and a long copy, a copy that reaches into the
// bytes it is itself writing, a stream that ends between commands — and
// every refusal with its text. The control words are built by hand, most
// significant bit first; `filled`, `letters` and `same_bytes` are the
// CHAR decompressor's test file's.

///|
/// The text the decompressor's `ParseError` carries for a stream.
fn rdc_detail(stream : Bytes, out : Array[Byte]) -> String raise {
  let outcome : Result[_, @types.DataError] = Ok(
    rdc_decompress(stream, 0L, stream.length().to_int64(), out),
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
test "a control word of zeros copies its sixteen literals" {
  let out = filled(16, 0)
  assert_eq(rdc_decompress(b"\x00\x00abcdefghijklmnop", 0L, 18L, out), 16L)
  assert_true(same_bytes(out, letters("abcdefghijklmnop")))
  // Fewer literals than bits: the stream ends with its bytes.
  let out = filled(16, 0)
  assert_eq(rdc_decompress(b"\x00\x00abc", 0L, 5L, out), 3L)
  // A lone byte behind a spent control word is no control word.
  assert_eq(rdc_decompress(b"\x00\x00abcdefghijklmnop\x01", 0L, 19L, out), 16L)
  // A control word that is the stream's last two bytes: its first bit is
  // a literal's, no byte is left for it, and the row ends there.
  assert_eq(
    rdc_decompress(b"\x00\x00abcdefghijklmnop\x00\x00", 0L, 20L, out),
    16L,
  )
  // Bytes that follow a literal's bit are literals, whatever they are.
  assert_eq(rdc_decompress(b"\x00\x00ab\x00\x00", 0L, 6L, out), 4L)
  assert_eq(rdc_decompress(b"", 0L, 0L, filled(4, 0)), 0L)
  // The stream may sit anywhere in the bytes: only `at` and `length`
  // are read.
  assert_eq(rdc_decompress(b"??\x00\x00ab!!", 2L, 4L, out), 2L)
}

///|
test "a short run fills the count its marker names, with the next byte" {
  // The first bit a command: a run of 3 + 2 bytes of 'y'.
  let out = filled(5, 0)
  assert_eq(rdc_decompress(b"\x80\x00\x02y", 0L, 4L, out), 5L)
  assert_true(same_bytes(out, letters("yyyyy")))
  let out = filled(18, 0)
  assert_eq(rdc_decompress(b"\x80\x00\x0fy", 0L, 4L, out), 18L)
  assert_true(same_bytes(out, filled(18, b'y')))
}

///|
test "a long run fills the count its three bytes name" {
  // 19 + 1 + 16 = 36 bytes of 'z'.
  let out = filled(36, 0)
  assert_eq(rdc_decompress(b"\x80\x00\x11\x01z", 0L, 5L, out), 36L)
  assert_true(same_bytes(out, filled(36, b'z')))
  // 19 + 15 + 255 * 16 = 4114 bytes.
  let out = filled(4114, 0)
  assert_eq(rdc_decompress(b"\x80\x00\x1f\xff.", 0L, 5L, out), 4114L)
  assert_true(same_bytes(out, filled(4114, b'.')))
}

///|
test "a short copy repeats the bytes it reaches back to" {
  // Six literals, then a copy of four bytes from three back.
  let out = filled(10, 0)
  assert_eq(rdc_decompress(b"\x02\x00abcabc\x43\x00", 0L, 10L, out), 10L)
  assert_true(same_bytes(out, letters("abcabcabca")))
}

///|
test "a long copy repeats the bytes it reaches back to, into its own output" {
  // Eight literals, then a copy of seventeen bytes from eight back: the
  // copy reaches into what it has just written.
  let out = filled(25, 0)
  assert_eq(rdc_decompress(b"\x00\x80abcdefgh%\x00\x01", 0L, 13L, out), 25L)
  assert_true(same_bytes(out, letters("abcdefghabcdefghabcdefgha")))
  // Twenty literals — a word of zeros, then a word whose fourth bit is
  // the command's — and a long copy from twenty bytes back: the offset's
  // high byte carries sixteen of them.
  let out = filled(36, 0)
  let stream = b"\x00\x00" +
    b"0123456789abcdef" +
    b"\x08\x00" +
    b"ghij" +
    b"\x21\x01\x00"
  assert_eq(rdc_decompress(stream, 0L, 27L, out), 36L)
  assert_true(same_bytes(out, letters("0123456789abcdefghij0123456789abcdef")))
}

///|
test "a BINARY row that expands past the row refuses, as a literal, a run or a copy" {
  assert_eq(
    rdc_detail(b"\x00\x00abc", filled(2, 0)),
    "sas7bdat: byte 4: a compressed row expands past the 2 bytes of a row",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x0fA", filled(4, 0)),
    "sas7bdat: byte 2: a compressed row expands past the 4 bytes of a row",
  )
  // Four literals, then a copy of three bytes from four back into a row
  // of four.
  assert_eq(
    rdc_detail(b"\x08\x00abcd\x31\x00", filled(4, 0)),
    "sas7bdat: byte 6: a compressed row expands past the 4 bytes of a row",
  )
}

///|
test "a BINARY stream that ends inside a command refuses, naming the command" {
  assert_eq(
    rdc_detail(b"\x80\x00", filled(4, 0)),
    "sas7bdat: byte 2: a compressed row ends before the byte a command is spelled in",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x00", filled(4, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a run command",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x10", filled(40, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a long run command",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x10\x01", filled(40, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a long run command",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x20", filled(40, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a long copy command",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x20\x00", filled(40, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a long copy command",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x30", filled(40, 0)),
    "sas7bdat: byte 2: a compressed row ends inside a copy command",
  )
}

///|
test "a BINARY copy that reaches further back than the row has bytes refuses" {
  // A literal, then a copy from three back.
  assert_eq(
    rdc_detail(b"\x40\x00a\x30\x00", filled(8, 0)),
    "sas7bdat: byte 3: a copy command reaches 3 bytes back into a row of 1 bytes so far",
  )
  assert_eq(
    rdc_detail(b"\x80\x00\x50\x00", filled(8, 0)),
    "sas7bdat: byte 2: a copy command reaches 3 bytes back into a row of 0 bytes so far",
  )
}
