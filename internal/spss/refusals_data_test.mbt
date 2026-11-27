// Blackbox refusals of the zlib data record and of text in its encoding,
// asserted by variant and by text on files built by hand.

///|
/// The zlib error the core raises for `bytes`, which a test spells a
/// refusal with; bytes that inflate fail the test.
fn zlib_error(bytes : BytesView) -> @zlib.ZlibError raise {
  let outcome : Result[Bytes, @zlib.ZlibError] = Ok(@zlib.decompress(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the bytes inflated")
    Err(e) => e
  }
}

///|
test "a zlib header that misplaces itself is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched_wide(z.bytes, z.header_at, z.header_at.to_int64() + 1L),
    parse(
      "byte \{z.header_at}: the zlib header places itself at byte \{z.header_at + 1}",
    ),
  )
}

///|
test "a zlib trailer that does not lie in the file is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched_wide(z.bytes, z.header_at + 8, 10000L),
    parse(
      "byte \{z.header_at}: the zlib header places a trailer of 48 bytes at byte 10000, which does not lie in the file",
    ),
  )
  refuses(
    patched_wide(z.bytes, z.header_at + 16, 47L),
    parse(
      "byte \{z.header_at}: the zlib header places a trailer of 47 bytes at byte \{z.trailer_at}, which does not lie in the file",
    ),
  )
  refuses(
    patched_wide(z.bytes, z.header_at + 8, 100L),
    parse(
      "byte \{z.header_at}: the zlib header places a trailer of 48 bytes at byte 100, which does not lie in the file",
    ),
  )
}

///|
test "a zlib trailer whose bias is not -100 is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched_wide(z.bytes, z.trailer_at, -101L),
    parse("byte \{z.trailer_at}: the zlib trailer's bias is -101, not -100"),
  )
}

///|
test "a zlib trailer whose block count disagrees with its length is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched(z.bytes, z.trailer_at + 20, 2),
    parse(
      "byte \{z.trailer_at + 16}: the zlib trailer of 48 bytes names 2 data blocks, where its length gives 1",
    ),
  )
}

///|
test "a zlib block that misplaces its data in the inflated stream is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched_wide(z.bytes, z.trailer_at + 24, z.header_at.to_int64() + 8L),
    parse(
      "byte \{z.trailer_at + 24}: zlib data block 0 places its data at byte \{z.header_at + 8} of the inflated stream, where \{z.header_at} is expected",
    ),
  )
}

///|
test "a zlib block that misplaces itself in the file is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched_wide(z.bytes, z.trailer_at + 32, z.block_at.to_int64() + 1L),
    parse(
      "byte \{z.trailer_at + 32}: zlib data block 0 lies at byte \{z.block_at + 1} of the file, where \{z.block_at} is expected",
    ),
  )
}

///|
test "a zlib block that claims bytes past its trailer is refused" {
  let z = zsav(1, one_unit_codes())
  let claimed = z.trailer_at - z.block_at + 100
  refuses(
    patched(z.bytes, z.trailer_at + 44, claimed),
    parse(
      "byte \{z.trailer_at + 40}: zlib data block 0 claims \{claimed} bytes at byte \{z.block_at}, which do not lie before the trailer at byte \{z.trailer_at}",
    ),
  )
}

///|
test "a zlib block that claims more data than the trailer's block size is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched(z.bytes, z.trailer_at + 16, 4),
    parse(
      "byte \{z.trailer_at + 40}: zlib data block 0 claims 8 bytes of data, past the trailer's block size of 4",
    ),
  )
}

///|
test "a zlib block that claims more data than zlib can expand it to is refused" {
  let z = zsav(1, one_unit_codes())
  let wide = patched(z.bytes, z.trailer_at + 16, 0x7FFFFFFF)
  let claimed = 100000
  let compressed = z.trailer_at - z.block_at
  refuses(
    patched(wide, z.trailer_at + 40, claimed),
    parse(
      "byte \{z.trailer_at + 40}: zlib data block 0 claims \{claimed} bytes of data from \{compressed} bytes, past what zlib can expand",
    ),
  )
}

///|
test "a zlib block that does not inflate is refused with the zlib error" {
  let z = zsav(1, one_unit_codes())
  let broken = patched_bytes(z.bytes, z.block_at, b"\x00\x00")
  let e = zlib_error(broken[z.block_at:z.trailer_at])
  refuses(
    broken,
    parse("byte \{z.block_at}: zlib data block 0 does not inflate: \{e}"),
  )
}

///|
test "a zlib block that inflates to another length than it declares is refused" {
  let z = zsav(1, one_unit_codes())
  refuses(
    patched(z.bytes, z.trailer_at + 40, 16),
    parse(
      "byte \{z.trailer_at + 40}: zlib data block 0 inflates to 8 bytes, where it declares 16",
    ),
  )
}

///|
test "zlib data blocks that end before the trailer are refused" {
  let z = zsav(1, one_unit_codes())
  let out : Array[Byte] = []
  for i in 0..<z.trailer_at {
    out.push(z.bytes[i])
  }
  out.push(0)
  for i in z.trailer_at..<z.bytes.length() {
    out.push(z.bytes[i])
  }
  let moved = patched_wide(
    Bytes::from_array(out),
    z.header_at + 8,
    z.trailer_at.to_int64() + 1L,
  )
  refuses(
    moved,
    parse(
      "byte \{z.trailer_at + 1}: the zlib data blocks end at byte \{z.trailer_at}, where the trailer starts",
    ),
  )
}

///|
test "a name that is not well-formed UTF-8 is refused at its byte" {
  let f = header(false, 0, 1)
  variable(f, 0, b"\xff\xff\xff\xff\xff\xff\xff\xff", fmt(5, 8, 2))
  terminator(f)
  ignore(f.double(1.0))
  refuses(f.finish(), parse("byte 200: the text is not well-formed UTF-8"))
}

///|
test "a string cell that is not well-formed UTF-8 is refused at its row and column" {
  let f = header(false, 0, 1)
  variable(f, 8, b"S", fmt(1, 8, 0))
  terminator(f)
  ignore(f.raw(b"ab\xffcd\x20\x20\x20"))
  refuses(
    f.finish(),
    parse("row 1, column \"S\": the text is not well-formed UTF-8"),
  )
}

///|
test "a string cell that is cut inside a character after an ill-formed one is refused too" {
  let f = header(false, 0, 1)
  variable(f, 8, b"S", fmt(1, 8, 0))
  terminator(f)
  // U+D800, a surrogate no UTF-8 spells, then the first byte of another
  // character the field has no room for.
  ignore(f.raw(b"\xed\xa0\x80\xc3\x20\x20\x20\x20"))
  refuses(
    f.finish(),
    parse("row 1, column \"S\": the text is not well-formed UTF-8"),
  )
}
