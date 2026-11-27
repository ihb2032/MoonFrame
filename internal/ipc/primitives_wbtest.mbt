// Whitebox tests of the primitives the codec is built from, each called
// on its own: the bounds-checked metadata reader over bytes built by hand,
// the body reader's own bounds, and the conversions a cell goes through —
// a 32-bit float widened, a decimal's sixteen bytes read as digits. Most of
// these refusals are ones the decoder's own bounding keeps a payload from
// reaching; a primitive that checks its own bound is tested against that
// bound directly, so the check is known to hold should a caller's bound
// ever be loosened.

// ── the metadata reader ───────────────────────────────────────────────

///|
/// Int16s as little-endian bytes, side by side.
fn int16s(values : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in values {
    push_le(out, v.to_int64().reinterpret_as_uint64(), 2)
  }
  Bytes::from_array(out)
}

///|
test "a scalar read refuses a position that does not hold its value" {
  let four = zeros(4)
  let byte = "malformed Arrow IPC: a message ends inside a byte field"
  let short = "malformed Arrow IPC: a message ends inside a 16-bit field"
  let word = "malformed Arrow IPC: a message ends inside a 32-bit field"
  let wide = "malformed Arrow IPC: a message ends inside a 64-bit field"
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_u8(four, 4)) }),
    byte,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_u8(four, -1)) }),
    byte,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_u16(four, 3)) }),
    short,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(fb_u16(four, -2))
    }),
    short,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_u32(four, 1)) }),
    word,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_i32(four, 2)) }),
    word,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_i64(four, 0)) }),
    wide,
  )
  // A scalar read in range, in both widths of the sign.
  assert_eq(fb_u8(four, 3), 0)
  assert_eq(fb_u16(four, 0), 0)
  let high = joined([zeros(3), Bytes::from_array([b'\x80'])])
  assert_eq(fb_i32(high, 0), -2147483648)
  assert_eq(fb_i16(int16s([0x8000]), 0), -32768)
  // An offset or a length is unsigned 32 bits that must fit a signed one.
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(fb_u32(high, 0)) }),
    "malformed Arrow IPC: an offset or length past 2^31",
  )
}

///|
test "an offset that leaves the message refuses, at the root and below it" {
  let leaves = "malformed Arrow IPC: an offset leaves the message"
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(fb_indirect(int32s([8]), 0))
    }),
    leaves,
  )
  // An offset may name the last byte: it is inside, and what it points to
  // refuses on its own.
  assert_eq(fb_indirect(int32s([3]), 0), 3)
  // A root that overlaps its own offset, one that leaves the message, and
  // one the message truncates.
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(fb_root(int32s([2])))
    }),
    "malformed Arrow IPC: the root table overlaps the root offset",
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(fb_root(int32s([100])))
    }),
    leaves,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(fb_root(zeros(2)))
    }),
    "malformed Arrow IPC: a message ends inside a 32-bit field",
  )
}

///|
/// A buffer of one table, its vtable right before it: `entries` are the
/// vtable's field offsets, `body` the table's own bytes after its soffset,
/// which names the distance back to the vtable.
fn one_table(entries : Array[Int32], body : Bytes) -> Bytes {
  let vtable : Array[Int32] = [4 + 2 * entries.length(), 4]
  for entry in entries {
    vtable.push(entry)
  }
  joined([
    int32s([4 + 2 * vtable.length()]),
    int16s(vtable),
    int32s([2 * vtable.length()]),
    body,
  ])
}

///|
test "a table's vtable, a field, a string, or a struct leaving the message refuses" {
  // A vtable that reaches before the message starts, and one past its end.
  let before = fb_root(joined([int32s([4]), int32s([100]), zeros(4)]))
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(before.i16(0)) }),
    "malformed Arrow IPC: a table's vtable leaves the message",
  )
  let after = fb_root(joined([int32s([5]), zeros(1), int32s([-10])]))
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(after.i16(0)) }),
    "malformed Arrow IPC: a table's vtable leaves the message",
  )
  // A field whose offset does not land inside the message.
  let far = fb_root(one_table([100], zeros(4)))
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(far.i64(0)) }),
    "malformed Arrow IPC: a field offset leaves the message",
  )
  // A string past the message's end, and one that is not UTF-8.
  let long = fb_root(
    one_table([4], joined([int32s([4]), int32s([100]), b"ab\x00\x00"])),
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(long.text(0)) }),
    "malformed Arrow IPC: a string leaves the message",
  )
  let raw = fb_root(
    one_table([4], joined([int32s([4]), int32s([2]), b"\xFF\xFE"])),
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(raw.text(0)) }),
    "malformed Arrow IPC: a string is not UTF-8",
  )
  // The same table with a string that fits reads it; a field the vtable
  // ends before, and one it marks absent, are absent.
  let text = fb_root(one_table([4], joined([int32s([4]), int32s([3]), b"abc"])))
  assert_eq(text.text(0), Some("abc"))
  assert_true(text.i64(1) is None)
  assert_true(text.table(1) is None)
  assert_true(text.boolean(1) is None)
  // A field the vtable marks absent is absent whatever its id.
  let absent = fb_root(
    one_table([0, 4], joined([int32s([4]), int32s([3]), b"abc"])),
  )
  assert_true(absent.text(0) is None)
  assert_eq(absent.text(1), Some("abc"))
  // A struct vector whose elements run past the message.
  let counted = fb_root(
    one_table([4], joined([int32s([4]), int32s([2]), zeros(4)])),
  )
  let vector = counted.vector(0).unwrap()
  assert_eq(vector.struct_at(0, 4), 22)
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(vector.struct_at(1, 16))
    }),
    "malformed Arrow IPC: a struct vector leaves the message",
  )
  assert_true(counted.vector(1) is None)
  assert_true(counted.tables(1) is None)
  // A vector of tables read whole.
  let nested = fb_root(
    one_table([4], joined([int32s([4]), int32s([1]), int32s([4]), zeros(4)])),
  )
  assert_eq(nested.tables(0).unwrap().length(), 1)
  assert_eq(nested.tables(0).unwrap()[0].pos, 26)
}

// ── the body reader ───────────────────────────────────────────────────

///|
test "a body read refuses a position that does not hold its value" {
  let four = Buf::{ bytes: b"\x01\x02\x03\x04", base: 0, len: 4, }
  assert_eq(four.uint(0, 4, false), 0x04030201UL)
  assert_eq(four.uint(0, 4, true), 0x01020304UL)
  assert_eq(four.uint(3, 1, false), 4UL)
  let inside = "malformed Arrow IPC: a buffer ends inside a value"
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(four.uint(1, 4, false))
    }),
    inside,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(four.uint(-1, 2, false))
    }),
    inside,
  )
  // A signed integer is sign-extended, an unsigned one wider than `Int64`
  // comes back negative.
  let signed = Buf::{ bytes: b"\xFF\xFF\x00\x00", base: 0, len: 4, }
  assert_eq(signed.int(0, 2, true, false), -1L)
  assert_eq(signed.int(0, 2, false, false), 65535L)
  assert_eq(signed.int(1, 2, true, false), 0L)
  let huge = Buf::{ bytes: Bytes::makei(8, _ => b'\xFF'), base: 0, len: 8, }
  assert_eq(huge.int(0, 8, false, false), -1L)
  assert_eq(huge.uint(0, 8, false), 0xFFFFFFFFFFFFFFFFUL)
  // A base other than zero is where the buffer starts in its bytes.
  let shifted = Buf::{ bytes: b"\xFF\x02\x01\x00", base: 1, len: 2, }
  assert_eq(shifted.uint(0, 2, false), 0x0102UL)
  // A bitmap is read bit by bit, the least significant bit first.
  assert_eq(four.bit(0), true)
  assert_eq(four.bit(1), false)
  assert_eq(four.bit(8), false)
  assert_eq(four.bit(9), true)
  assert_eq(four.bit(26), true)
  assert_eq(four.bit(31), false)
  let bitmap = "malformed Arrow IPC: a bitmap ends before its node's last cell"
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(four.bit(32)) }),
    bitmap,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError { ignore(four.bit(-8)) }),
    bitmap,
  )
  // A need is refused past the buffer, and when it is negative.
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      four.needs(5L, "a need past the buffer")
    }),
    "malformed Arrow IPC: a need past the buffer",
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      four.needs(-1L, "a negative need")
    }),
    "malformed Arrow IPC: a negative need",
  )
  assert_eq(bitmap_bytes(0), 0L)
  assert_eq(bitmap_bytes(1), 1L)
  assert_eq(bitmap_bytes(8), 1L)
  assert_eq(bitmap_bytes(9), 2L)
}

// ── the builder ───────────────────────────────────────────────────────

///|
test "a string written before anything else keeps the buffer's alignment" {
  // The count, the bytes, and their closing zero: the count lands on a
  // four-byte boundary, which is the alignment the string asked for.
  let fb = Fb::new()
  let name = fb.string("abc")
  let meta = fb.finish(name)
  assert_eq(fb.align, 4)
  assert_eq(meta.length(), 16)
  assert_eq(fb_indirect(meta, 0), 4)
  assert_eq(fb_u32(meta, 4), 3)
  assert_eq([meta[8], meta[9], meta[10]], [b'\x61', b'\x62', b'\x63'])
  assert_eq([meta[11], meta[12], meta[13], meta[14], meta[15]], [
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  // A string whose bytes would put its count off the boundary is padded
  // ahead of its closing zero, and the count still lands on it.
  let padded = Fb::new()
  let four = padded.string("abcd")
  let bytes = padded.finish(four)
  assert_eq(bytes.length(), 16)
  assert_eq(fb_indirect(bytes, 0), 4)
  assert_eq(fb_u32(bytes, 4), 4)
  assert_eq([bytes[8], bytes[9], bytes[10], bytes[11]], [
    b'\x61', b'\x62', b'\x63', b'\x64',
  ])
  assert_eq([bytes[12], bytes[13], bytes[14], bytes[15]], [
    b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  // An empty string is a count and its closing zero.
  let none = Fb::new()
  let empty = none.string("")
  let just = none.finish(empty)
  assert_eq(fb_indirect(just, 0), 4)
  assert_eq(fb_u32(just, 4), 0)
  assert_eq(just[8], b'\x00')
}

///|
test "a bitmap holds its bits from the least significant up" {
  assert_eq(bitmap_of(0, _ => true).length(), 0)
  assert_eq(bitmap_of(3, i => i != 1), Bytes::from_array([b'\x05']))
  assert_eq(bitmap_of(8, i => i < 7), Bytes::from_array([b'\x7F']))
  assert_eq(bitmap_of(9, i => i != 8), Bytes::from_array([b'\xFF', b'\x00']))
  assert_eq(bitmap_of(10, _ => true), Bytes::from_array([b'\xFF', b'\x03']))
}

///|
/// A decimal read from its text, as a test spells the value it expects.
fn dec(text : String) -> @types.Dec128 {
  @types.Dec128::parse_opt(text).unwrap()
}

///|
/// A decimal cell's sixteen bytes from its low and high halves.
fn decimal_cell_bytes(low : UInt64, high : UInt64) -> Bytes {
  let out : Array[Byte] = []
  push_i64(out, low.reinterpret_as_int64())
  push_i64(out, high.reinterpret_as_int64())
  Bytes::from_array(out)
}

///|
/// The decimal a cell of those halves carries at `scale`, little-endian.
fn decimal_cell(
  low : UInt64,
  high : UInt64,
  scale : Int32,
) -> @types.Dec128 raise @types.DataError {
  decimal128_of(
    Buf::{ bytes: decimal_cell_bytes(low, high), base: 0, len: 16, },
    0,
    scale,
    false,
    "d",
  )
}

///|
test "the digits of a 128-bit magnitude, from known answers" {
  // Zero and single groups, group boundaries with zeros inside them, the
  // 64-bit boundary, and the full range — each computed independently.
  let vectors : Array[(UInt64, UInt64, String)] = [
    (0UL, 0UL, "0"),
    (1UL, 0UL, "1"),
    (9UL, 0UL, "9"),
    (10UL, 0UL, "10"),
    (1000000000UL, 0UL, "1000000000"),
    (999999999UL, 0UL, "999999999"),
    (1000000000000000000UL, 0UL, "1000000000000000000"),
    (7766279631452241923UL, 5UL, "100000000000000000003"),
    (11515845246265065477UL, 54210108UL, "1000000000000000000000000005"),
    (0UL, 1UL, "18446744073709551616"),
    (18446744073709551615UL, 0UL, "18446744073709551615"),
    (0UL, 9223372036854775808UL, "170141183460469231731687303715884105728"),
    (
      18446744073709551615UL, 18446744073709551615UL, "340282366920938463463374607431768211455",
    ),
    (1000000001000000005UL, 0UL, "1000000001000000005"),
    (2UL, 0UL, "2"),
    (29UL, 0UL, "29"),
    (94725UL, 0UL, "94725"),
    (848216309UL, 0UL, "848216309"),
    (5366785030UL, 0UL, "5366785030"),
    (12785744811141770UL, 0UL, "12785744811141770"),
    (195070458741871741UL, 0UL, "195070458741871741"),
    (5829192488867990681UL, 0UL, "5829192488867990681"),
    (11830333013102127372UL, 3UL, "67170565234230782220"),
    (10792497163792597729UL, 386719UL, "7133717213938047883985633"),
    (216462063585731878UL, 30487721UL, "562399186894122308289439014"),
    (1878998161671677480UL, 263765021UL, "4865605839862623591566501416"),
    (17124212521765670942UL, 39611118738UL, "730696169850331085707881451550"),
    (
      15102411663772747613UL, 112604686022837UL, "2077189824563708311743441379002205",
    ),
    (
      12031138322190532967UL, 2322901591249445UL, "42849971162191198827307822349386087",
    ),
    (
      14554483388271252819UL, 3914517068955776065UL, "72210094543194846352845650472726123859",
    ),
    (
      12312739301371248917UL, 6692605942763486917UL, "123456789012345678901234567890123456789",
    ),
    (
      8453679182852915201UL, 5421010862427522175UL, "100000000000000000100000000000000000001",
    ),
  ]
  for v in vectors {
    assert_eq(decimal_digits(v.0, v.1), v.2)
  }
  assert_eq(without_trailing_zeros("0"), ("0", 0))
  assert_eq(without_trailing_zeros("1"), ("1", 0))
  assert_eq(without_trailing_zeros("101"), ("101", 0))
  assert_eq(without_trailing_zeros("10"), ("1", 1))
  assert_eq(without_trailing_zeros("1200700"), ("12007", 2))
}

///|
test "a decimal cell reads as its unscaled integer over its scale" {
  // Zero, and a value with and without fraction digits to drop.
  assert_eq(decimal_cell(0UL, 0UL, 2), dec("0"))
  assert_eq(decimal_cell(150UL, 0UL, 2), dec("1.5"))
  assert_eq(decimal_cell(150UL, 0UL, 0), dec("150"))
  // A negative value whose low half is zero carries into the high half.
  let all_ones = 0xFFFFFFFFFFFFFFFFUL
  assert_eq(decimal_cell(0UL, all_ones, 0), dec("-18446744073709551616"))
  assert_eq(decimal_cell(0UL, all_ones, 4), dec("-1844674407370955.1616"))
  assert_eq(decimal_cell(all_ones, all_ones, 0), dec("-1"))
  assert_eq(decimal_cell(18446744073709551466UL, all_ones, 2), dec("-1.5"))
  // The most a signed 128-bit integer holds below zero, like its
  // positive counterpart, counts 39 digits.
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(decimal_cell(0UL, 0x8000000000000000UL, 0))
    }),
    "Arrow IPC: column \"d\" carries a decimal cell with 39 significant digits, past the 34 a decimal holds",
  )
  // Trailing zeros are dropped from the digits and folded into the scale.
  assert_eq(
    decimal_cell(7766279631452241920UL, 5UL, 0),
    dec("100000000000000000000"),
  )
  assert_eq(
    decimal_cell(10680464442257309696UL, 18446744073709551610UL, 4),
    dec("-10000000000000000"),
  )
  assert_eq(
    decimal_cell(3136633892082024448UL, 5421010862427522UL, 2),
    dec("1E+33"),
  )
  assert_eq(
    decimal_cell(687399551400673280UL, 5421010862427522170UL, 0),
    dec("1E+38"),
  )
  // The widest cells a decimal holds: 34 significant digits.
  assert_eq(
    decimal_cell(4003012203950112767UL, 542101086242752UL, 3),
    dec("9999999999999999999999999999999.999"),
  )
  assert_eq(
    decimal_cell(16033479673939144690UL, 66926059427634UL, 0),
    dec("1234567890123456789012345678901234"),
  )
  // The same digits with a 35th refuse, naming the column and the count.
  let too_many = "Arrow IPC: column \"d\" carries a decimal cell with 35 significant digits, past the 34 a decimal holds"
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(decimal_cell(12760844149715033977UL, 669260594276348UL, 0))
    }),
    too_many,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(decimal_cell(all_ones, 0x7FFFFFFFFFFFFFFFUL, 0))
    }),
    "Arrow IPC: column \"d\" carries a decimal cell with 39 significant digits, past the 34 a decimal holds",
  )
  // A negative scale lifts the integer: the trailing zeros are not the
  // scale's to drop.
  assert_eq(decimal_cell(0UL, all_ones, -2), dec("-1844674407370955161600"))
  // A big-endian body carries the high half first, each half big-endian.
  let be = fn(v : UInt64) -> Bytes {
    Bytes::makei(8, i => ((v >> (8 * (7 - i)).to_int()) & 0xFFUL).to_byte())
  }
  let swapped = decimal128_of(
    Buf::{
      bytes: joined([be(5UL), be(7766279631452241920UL)]),
      base: 0,
      len: 16,
    },
    0,
    0,
    true,
    "d",
  )
  assert_eq(swapped, dec("100000000000000000000"))
  assert_eq(
    decimal128_of(
      Buf::{ bytes: joined([be(all_ones), be(0UL)]), base: 0, len: 16, },
      0,
      0,
      true,
      "d",
    ),
    dec("-18446744073709551616"),
  )
}

// ── the writer's cell readers ─────────────────────────────────────────

///|
test "a column of dtype Null names no Arrow type to write" {
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(arrow_type_of(@types.DataType::Null, [], "n", None))
    }),
    "cannot write Arrow IPC: a column of dtype Null, which names no buffer to write",
  )
}

///|
test "a struct cell's field it leaves out reads as null, and a list's cells flatten" {
  let whole = @types.Scalar::Struct(
    @types.StructValue::StructValue([
      @types.FieldValue::FieldValue("a", @types.Scalar::Int(1)),
    ]),
  )
  let bare = @types.Scalar::Struct(@types.StructValue::StructValue([]))
  assert_eq(struct_cells([whole, bare, @types.Scalar::Null], 0), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(struct_cells([whole], 1), [@types.Scalar::Null])
  let list = @types.Scalar::List(
    @types.ListValue::ListValue([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
  )
  assert_eq(list_cells([list, @types.Scalar::Null]), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
}
