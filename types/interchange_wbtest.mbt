// Whitebox tests of the conversion the interchange codecs share: a
// 32-bit float widened.

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
