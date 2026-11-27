// The value conversion the interchange codecs share: a 32-bit float
// widened to the `Double` that holds every one of its values exactly.

///|
/// The 32-bit float whose IEEE 754 bits are `bits`, widened to the
/// `Double` that holds every one of its values exactly — the sign kept,
/// a normal's 24-bit significand and exponent rebased, a subnormal an
/// integer multiple of the format's least significant bit, and an infinity
/// or a NaN the same exponent and fraction in the wider format.
#doc(hidden)
#internal(engine, "MoonFrame interchange codecs share the widening of a 32-bit float")
pub fn float32_bits_to_double(bits : UInt32) -> Double {
  let negative = bits >> 31 == 1U
  let exponent = ((bits >> 23) & 0xFFU).reinterpret_as_int()
  let fraction = bits & 0x7FFFFFU
  let magnitude : Double = if exponent == 255 {
    (0x7FF0000000000000UL | (fraction.to_uint64() << 29)).reinterpret_as_double()
  } else if exponent == 0 {
    // Zero, or a subnormal: an integer below 2^23 times the value of the
    // format's least significant bit, a product the `Double` holds
    // exactly.
    fraction.to_double() * FLOAT32_UNIT
  } else {
    // A normal: a 24-bit significand over 2^23, times a power of two.
    (0x800000U | fraction).to_double() /
    8388608.0 *
    ((exponent + 896).to_uint64() << 52).reinterpret_as_double()
  }
  if negative {
    -magnitude
  } else {
    magnitude
  }
}

///|
/// The value of a 32-bit subnormal's least significant bit, 2^-149.
const FLOAT32_UNIT : Double = 1.401298464324817e-45
