// Whitebox tests of the conversions the interchange codecs share: a
// 32-bit float widened, and a decimal against the unscaled integer a
// fixed-point format carries it as.

///|
test "a 32-bit float's bits widen to the Double that holds them" {
  assert_eq(float32_bits_to_double(0x3F800000U), 1.0)
  assert_eq(float32_bits_to_double(0xBFC00000U), -1.5)
  assert_eq(float32_bits_to_double(0x40490FDBU), 3.1415927410125732)
  assert_eq(float32_bits_to_double(0x7F800000U), @double.infinity)
  assert_eq(float32_bits_to_double(0xFF800000U), @double.neg_infinity)
  assert_true(float32_bits_to_double(0x7FC00000U).is_nan())
  assert_true(float32_bits_to_double(0xFFC00000U).is_nan())
  // Zero keeps its sign; a subnormal, the smallest normal, and the
  // largest finite are held exactly.
  assert_eq(
    float32_bits_to_double(0x80000000U).reinterpret_as_uint64(),
    0x8000000000000000UL,
  )
  assert_eq(float32_bits_to_double(0x00000000U).reinterpret_as_uint64(), 0UL)
  assert_eq(float32_bits_to_double(0x00000001U), 1.401298464324817e-45)
  assert_eq(float32_bits_to_double(0x007FFFFFU), 1.1754942106924411e-38)
  assert_eq(float32_bits_to_double(0x00800000U), 1.1754943508222875e-38)
  assert_eq(float32_bits_to_double(0x7F7FFFFFU), 3.4028234663852886e+38)
  assert_eq(float32_bits_to_double(0x4420A147U), 642.5199584960938)
}

///|
/// Whether `bits` widens to the `Double` the platform's own 32-bit float
/// gives — bit for bit, so a signed zero is told from an unsigned one; a
/// NaN is compared as a NaN, its payload the conversion's own.
fn assert_widened(bits : UInt32) -> Unit raise {
  let mine = float32_bits_to_double(bits)
  let reference = Float::reinterpret_from_uint(bits).to_double()
  if reference.is_nan() {
    assert_true(mine.is_nan(), msg="\{bits}")
  } else {
    assert_eq(
      mine.reinterpret_as_uint64(),
      reference.reinterpret_as_uint64(),
      msg="\{bits}",
    )
  }
}

///|
test "a 32-bit float widens as the platform's own float does, over the format" {
  // Zero both ways, the smallest and the largest subnormal, the smallest
  // and the largest normal, an infinity, and a NaN — both signs of each.
  let edges : Array[UInt32] = [
    0x00000000U, 0x80000000U, 0x00000001U, 0x807FFFFFU, 0x007FFFFFU, 0x00800000U,
    0x80800000U, 0x7F7FFFFFU, 0xFF7FFFFFU, 0x7F800000U, 0xFF800000U, 0x7FC00000U,
    0xFFC00000U, 0x7F800001U,
  ]
  for bits in edges {
    assert_widened(bits)
  }
  // Every exponent with a spread of fractions: a deterministic walk over
  // the format, so a pattern the edges miss is still met.
  let mut bits = 0x9E3779B9U
  for _ in 0..<4096 {
    bits = bits * 1664525U + 1013904223U
    assert_widened(bits)
  }
  for exponent in 0..<=255 {
    let base = exponent.reinterpret_as_uint() << 23
    assert_widened(base)
    assert_widened(base | 0x7FFFFFU)
    assert_widened(base | 0x400000U | 0x80000000U)
  }
  // Values a reader can check by eye, beyond the fixed ones above.
  assert_eq(float32_bits_to_double(0x4B800000U), 16777216.0)
  assert_eq(float32_bits_to_double(0x33800000U), 5.960464477539063e-08)
}

///|
/// Whether the decimal an unscaled integer reads as equals the decimal
/// `want` spells — by value, whatever either one's spelling.
fn reads(
  low : UInt64,
  high : UInt64,
  negative~ : Bool,
  scale~ : Int32,
  want : String,
) -> Unit raise {
  match Dec128::of_unscaled(low, high, negative~, scale~) {
    Some(value) =>
      match Dec128::parse_opt(want) {
        Some(expected) => assert_true(value.sub(expected).is_zero())
        None => fail("\{want} does not spell a decimal")
      }
    None => fail("the integer was expected to read")
  }
}

///|
/// Whether an unscaled integer has no exact decimal.
fn refuses_unscaled(
  low : UInt64,
  high : UInt64,
  negative~ : Bool,
  scale~ : Int32,
) -> Unit raise {
  if Dec128::of_unscaled(low, high, negative~, scale~) is Some(_) {
    fail("the integer was expected to refuse")
  }
}

///|
test "an unscaled integer reads as the decimal it carries" {
  reads(123456789UL, 0UL, negative=false, scale=2, "1234567.89")
  reads(123456789UL, 0UL, negative=true, scale=2, "-1234567.89")
  reads(0UL, 0UL, negative=false, scale=5, "0")
  reads(0UL, 0UL, negative=true, scale=5, "0")
  reads(1UL, 0UL, negative=true, scale=0, "-1")
  // The zeros a magnitude ends in are a power of ten of their own: the
  // scale still to apply is the column's less those.
  reads(500UL, 0UL, negative=false, scale=1, "50")
  reads(500UL, 0UL, negative=false, scale=4, "0.05")
  // The high half in play: 2^64 + 5 over three fraction digits.
  reads(5UL, 1UL, negative=false, scale=3, "18446744073709551.621")
  // Thirty-four significant digits are the most a decimal holds.
  let widest = Dec128::parse_opt("9999999999999999999999999999999999")
  assert_true(widest is Some(_))
  if widest is Some(value) {
    match value.to_unscaled(scale=0) {
      Some((high, low, negative)) => {
        assert_false(negative)
        match Dec128::of_unscaled(low, high, negative~, scale=0) {
          Some(back) => assert_true(back.sub(value).is_zero())
          None => fail("thirty-four digits read back")
        }
      }
      None => fail("thirty-four digits lift")
    }
  }
  // A magnitude needing more than thirty-four digits has no exact
  // decimal: every bit set is thirty-nine digits, and 2^127 is one of
  // them with thirty-eight after it.
  refuses_unscaled(
    0xFFFF_FFFF_FFFF_FFFFUL,
    0xFFFF_FFFF_FFFF_FFFFUL,
    negative=false,
    scale=0,
  )
  refuses_unscaled(0UL, 0x8000000000000000UL, negative=true, scale=0)
  // Unless they end in zeros: 10^37 is one digit and thirty-seven
  // zeros — the widest power of ten thirty-eight digits hold.
  let round = Dec128::of_int64_scale(1L, scale=-37)
  if round.to_unscaled(scale=0) is Some((high, low, negative)) {
    match Dec128::of_unscaled(low, high, negative~, scale=0) {
      Some(back) => assert_true(back.sub(round).is_zero())
      None => fail("10^37 reads back")
    }
  } else {
    fail("10^37 lifts")
  }
}

///|
test "a decimal lifts to the unscaled integer it is written as" {
  // Whole numbers lift under any scale that is a count of zeros.
  assert_eq(Dec128::zero().to_unscaled(scale=0), Some((0UL, 0UL, false)))
  assert_eq(
    Dec128::of_int64(12L).to_unscaled(scale=0),
    Some((0UL, 12UL, false)),
  )
  assert_eq(
    Dec128::of_int64(12L).to_unscaled(scale=3),
    Some((0UL, 12000UL, false)),
  )
  // A negative decimal lifts to its magnitude and its sign.
  let owed = Dec128::parse_opt("-12.50").unwrap_or(Dec128::nan())
  assert_eq(owed.to_unscaled(scale=2), Some((0UL, 1250UL, true)))
  // A lifted value that is not a whole number does not lift.
  assert_eq(
    Dec128::parse_opt("1.25").unwrap_or(Dec128::zero()).to_unscaled(scale=1),
    None,
  )
  // Nor one that is not a finite number, nor one past 128 bits.
  assert_eq(Dec128::nan().to_unscaled(scale=0), None)
  assert_eq(Dec128::infinity().to_unscaled(scale=0), None)
  assert_eq(Dec128::of_int64_scale(1L, scale=38).to_unscaled(scale=0), None)
  assert_eq(Dec128::of_int64_scale(1L, scale=39).to_unscaled(scale=0), None)
  // A zero lifts to zero with its sign.
  assert_eq(Dec128::zero(neg=true).to_unscaled(scale=2), Some((0UL, 0UL, true)))
  // Every decimal the reference spellings name lifts and reads back.
  for
    text in [
      "0", "-1", "1234567.89", "-0.0001", "99999999.9999", "9999999999999999999999999999999999",
    ] {
    let value = Dec128::parse_opt(text).unwrap_or(Dec128::nan())
    match value.to_unscaled(scale=4) {
      Some((high, low, negative)) =>
        match Dec128::of_unscaled(low, high, negative~, scale=4) {
          Some(back) => assert_true(back.sub(value).is_zero())
          None => fail("\{text} reads back")
        }
      None => fail("\{text} lifts")
    }
  }
}

///|
test "the 128-bit accumulator carries between its halves" {
  // Ten times 3689348814741910323 is 2^65 - 2, and adding 2 carries into
  // the high half a second time.
  assert_eq(times_ten_plus(0UL, 3689348814741910323UL, 2UL), (2UL, 0UL))
  assert_eq(times_ten_plus(0UL, 0UL, 7UL), (0UL, 7UL))
  assert_eq(
    mul_u64(0xFFFF_FFFF_FFFF_FFFFUL, 0xFFFF_FFFF_FFFF_FFFFUL),
    (1UL, 0xFFFF_FFFF_FFFF_FFFEUL),
  )
  assert_eq(mul_u64(0UL, 0xFFFF_FFFF_FFFF_FFFFUL), (0UL, 0UL))
}
