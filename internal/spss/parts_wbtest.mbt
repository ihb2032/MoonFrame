// Whitebox tests of the reader's parts in isolation: the unit rules a
// date or time cell must pass, the windows-1252 table, the scan for a
// character cut at a field's end, the name matching of the long-name
// records, the checked reads in either byte order, and the arithmetic
// helpers. The blackbox suite compares every cell with what the
// reference readers get; these pin the ends of rules a reference file
// cannot reach.

///|
test "a date cell is a whole number of days within the library's reach, or no date" {
  assert_eq(whole_days(0.0), Some(-141428L))
  assert_eq(whole_days(86400.0), Some(-141427L))
  assert_eq(whole_days(-86400.0), Some(-141429L))
  assert_eq(whole_days(86400.0 * 159750.0), Some(18322L))
  assert_eq(whole_days(43200.0), None)
  assert_eq(whole_days(1.5), None)
  // 86,400 times 2^64: a whole number of days, too many to hold.
  assert_eq(whole_days(86400.0 * 18446744073709551616.0), None)
  assert_eq(whole_days(0.0 / 0.0), None)
}

///|
test "a datetime or time cell is an exact whole number of microseconds within reach, or no timestamp" {
  assert_eq(whole_micros(0.0), Some(0L))
  assert_eq(whole_micros(0.1), Some(100000L))
  assert_eq(whole_micros(-0.5), Some(-500000L))
  assert_eq(whole_micros(1.5e-9), None)
  assert_eq(whole_micros(1.0e13), None)
  assert_eq(whole_micros(1.0 / 0.0), None)
}

///|
test "every byte of windows-1252's printable range decodes, the unassigned ones as controls" {
  let expected : ReadOnlyArray[Int32] = [
    0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160,
    0x2039, 0x152, 0x8D, 0x17D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022,
    0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178,
  ]
  for k in 0..<32 {
    let one = Bytes::make(1, (0x80 + k).to_byte())
    let windows = plain_text(one, true)
    assert_eq(windows.length(), 1)
    assert_eq(windows.code_unit_at(0).to_int(), expected[k])
    // Outside the printable range the two code pages agree.
    if k == 0 || k == 31 {
      let high = Bytes::make(1, (0xA0).to_byte())
      assert_eq(plain_text(high, true), plain_text(high, false))
    }
  }
  assert_eq(plain_text(b"\xe9\xff", false), "éÿ")
}

///|
test "a character cut at a field's end is told from an ill-formed byte anywhere else" {
  assert_eq(truncated_tail(b"ab\xc3"), Some(2))
  assert_eq(truncated_tail(b"\xe6\x97"), Some(0))
  assert_eq(truncated_tail(b"a\xf0\x9f"), Some(1))
  assert_eq(truncated_tail(b"a\xf0\x9f\x98"), Some(1))
  assert_eq(truncated_tail(b""), None)
  assert_eq(truncated_tail(b"abc"), None)
  assert_eq(truncated_tail(b"a\xc3\xa9"), None)
  assert_eq(truncated_tail(b"a\xff"), None)
  assert_eq(truncated_tail(b"a\x80"), None)
  assert_eq(truncated_tail(b"a\xc3\x41"), None)
  assert_eq(truncated_tail(b"a\xc0\x80"), None)
  assert_eq(utf8_try(b"a\xff"), Err(()))
  assert_eq(utf8_try(b"ab\xc3"), Err(()))
  assert_eq(utf8_try(b"\xc3\xa9"), Ok("é"))
}

///|
test "two names spell the same variable when their bytes differ only in the case of ASCII letters" {
  assert_eq(same_name(b"N", b"n"), true)
  assert_eq(same_name(b"Var1", b"vAR1"), true)
  assert_eq(same_name(b"N", b"M"), false)
  assert_eq(same_name(b"N", b"NN"), false)
  assert_eq(same_name(b"\xc3\xbc", b"\xc3\x9c"), false)
  assert_eq(normal_name(b"Windows-1252"), "WINDOWS1252")
  assert_eq(normal_name(b"iso_8859-1"), "ISO88591")
  assert_eq(normal_name(b" m s . a n s i "), "MSANSI")
}

///|
test "a declared encoding name wins over the code page, a blank one counts for nothing" {
  assert_eq(encoding_declared(Some(b"UTF-8"), 1252L) is Utf8, true)
  assert_eq(encoding_declared(Some(b"   "), 28591L) is Latin1, true)
  assert_eq(encoding_declared(None, 3L) is Windows1252, true)
  assert_eq(encoding_declared(None, -1L) is Utf8, true)
  assert_eq(cut_blank(b"ab  \x00 ").to_owned(), b"ab")
}

///|
test "the checked reads answer in either byte order, and refuse past the file" {
  let bytes = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18"
  let little = Cursor::{ bytes, pos: 0, big: false, big_float: false, }
  assert_eq(little.u8(), 1)
  assert_eq(little.u32(), 0x05040302L)
  assert_eq(little.i32(), 0x09080706L)
  assert_eq(little.u64(), 0x11100F0E0D0C0B0AUL)
  little.pos = bytes.length()
  let past : Result[Int32, @types.DataError] = Ok(little.u8()) catch {
    e => Err(e)
  }
  assert_eq(past is Err(_), true)
  let big = Cursor::{ bytes, pos: 0, big: true, big_float: true, }
  assert_eq(big.u32(), 0x01020304L)
  assert_eq(big.i32(), 0x05060708L)
  assert_eq(big.u64(), 0x090A0B0C0D0E0F10UL)
  assert_eq(big.i64(), 0x1112131415161718L)
  // The bias spelled little-endian reads as 100 in the little order only,
  // and spelled big-endian in the big order only.
  let little_bias = b"\x00\x00\x00\x00\x00\x00\x59\x40"
  let big_bias = b"\x40\x59\x00\x00\x00\x00\x00\x00"
  for
    (bytes, order, other) in [
      (little_bias, false, 0x5940UL),
      (big_bias, true, 0x5940UL),
    ] {
    let f = Cursor::{ bytes, pos: 0, big: false, big_float: order, }
    assert_eq(f.f64_bits(), BIAS)
    assert_eq(bits_at(bytes, 0, order), BIAS)
    assert_eq(bits_at(bytes, 0, !order), other)
  }
  let out : Array[Byte] = []
  push_bits(out, 0x0102030405060708UL, true)
  push_bits(out, 0x0102030405060708UL, false)
  assert_eq(
    Bytes::from_array(out),
    b"\x01\x02\x03\x04\x05\x06\x07\x08\x08\x07\x06\x05\x04\x03\x02\x01",
  )
}

///|
test "the arithmetic helpers round up, find a byte, and bound a segment's text" {
  assert_eq(up8(1L), 8L)
  assert_eq(up8(8L), 8L)
  assert_eq(up8(255L), 256L)
  assert_eq(up4(1L), 4L)
  assert_eq(up4(4L), 4L)
  assert_eq(up4(5L), 8L)
  assert_eq(locate(b"abc", 98), 1)
  assert_eq(locate(b"abc", 100), -1)
  assert_eq(segment_used(300L, 0), 255)
  assert_eq(segment_used(300L, 1), 45)
  assert_eq(segment_used(505L, 2), 0)
  assert_eq(digits(b""), -1L)
  assert_eq(digits(b"1234567890123456789"), -1L)
  assert_eq(digits(b"12a"), -1L)
  assert_eq(digits(b"00300"), 300L)
  assert_eq(in_ranges(2.0, [1.0, 3.0]), true)
  assert_eq(in_ranges(3.0, [1.0, 3.0]), true)
  assert_eq(in_ranges(3.5, [1.0, 3.0]), false)
  assert_eq(in_ranges(2.0, []), false)
  assert_eq(is_missing("zz", ["zz", "a"]), true)
  assert_eq(is_missing("b", ["zz", "a"]), false)
  assert_eq(is_missing("", []), false)
}
