// The value conversions the interchange codecs share: a 32-bit float
// widened to the `Double` that holds every one of its values exactly, and
// a decimal read from and written to the unscaled integer a fixed-point
// format carries it as. A decimal's coefficient holds 34 digits, so an
// integer that needs more, counted without its trailing zeros, has no
// exact decimal; the reading answers `None`, and the caller refuses.

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

///|
/// The decimal an unscaled integer carries: its magnitude as a low and a
/// high 64-bit half, under `negative`, with `scale` fraction digits. The
/// digits are built up exactly, each step multiplying by ten, and the
/// scale is applied as a power of ten — no digit is rounded and nothing is
/// left to a parser. `None` when the integer needs more than 34 significant
/// digits, counted without its trailing zeros: the one shape a decimal
/// cannot hold.
#doc(hidden)
#internal(engine, "MoonFrame interchange codecs share the unscaled-integer reading of a decimal")
pub fn Dec128::of_unscaled(
  low : UInt64,
  high : UInt64,
  negative~ : Bool,
  scale~ : Int32,
) -> Dec128? {
  let (coefficient, zeros) = without_trailing_zeros(unscaled_digits(low, high))
  if coefficient.char_length() > 34 {
    return None
  }
  let ten = Dec128::of_int64(10L)
  let mut value = Dec128::zero()
  for digit in coefficient {
    value = value
      .mul(ten)
      .add(Dec128::of_int64((digit.to_int() - 48).to_int64()))
  }
  // The zeros the magnitude ends in are a power of ten of their own, so
  // the scale that still has to be applied is the column's less those —
  // and a negative remainder scales the value up.
  let scaled = value.mul(Dec128::of_int64_scale(1L, scale=scale - zeros))
  Some(if negative { scaled.neg() } else { scaled })
}

///|
/// The unscaled integer a decimal carries under `scale` fraction digits:
/// its magnitude as a low and a high 64-bit half, and whether it is
/// negative. The value is lifted by the power of ten the scale names and
/// its digits accumulate into 128 bits. `None` when the decimal is not a
/// finite number, when the lifted value is not a whole number, or when
/// that whole number needs more than 38 digits — past the precision a
/// 128-bit two's-complement integer is taken to carry.
#doc(hidden)
#internal(engine, "MoonFrame interchange codecs share the unscaled-integer writing of a decimal")
pub fn Dec128::to_unscaled(
  self : Dec128,
  scale~ : Int32,
) -> (UInt64, UInt64, Bool)? {
  if !self.is_finite() {
    return None
  }
  let negative = self.is_negative()
  // The canonical spelling keeps no trailing zero in its coefficient, so
  // a lifted value with a negative exponent is not a whole number. A
  // finite value's exponent is its own field and its digits its limbs.
  let canon = self.abs().canonical()
  let exponent = canon.exp
  let count = dec_sig_digits(canon.limbs)
  if exponent + scale < 0 || count + exponent + scale > 38 {
    return None
  }
  let mut hi = 0UL
  let mut lo = 0UL
  for pos = count - 1; pos >= 0; pos = pos - 1 {
    let digit = dec_digit_at(canon.limbs, pos).to_uint64()
    let (next_hi, next_lo) = times_ten_plus(hi, lo, digit)
    hi = next_hi
    lo = next_lo
  }
  for _ in 0..<(exponent + scale) {
    let (next_hi, next_lo) = times_ten_plus(hi, lo, 0UL)
    hi = next_hi
    lo = next_lo
  }
  Some((hi, lo, negative))
}

///|
/// The decimal digits of a 128-bit magnitude given as its low and high
/// 64-bit halves, with no leading zero; `"0"` for zero. The magnitude is
/// divided by 10^9 over four 32-bit limbs until nothing is left, and the
/// remainders are its groups of nine digits, least significant first.
fn unscaled_digits(low : UInt64, high : UInt64) -> String {
  let limbs : Array[UInt64] = [
    low & 0xFFFFFFFFUL,
    low >> 32,
    high & 0xFFFFFFFFUL,
    high >> 32,
  ]
  let base : UInt64 = 1000000000UL
  let groups : Array[Int64] = []
  let mut left = limbs[0] != 0UL ||
    limbs[1] != 0UL ||
    limbs[2] != 0UL ||
    limbs[3] != 0UL
  while left {
    let mut remainder : UInt64 = 0UL
    for i = 3; i >= 0; i = i - 1 {
      // The remainder is below 10^9, so the pair below 2^62.
      let current = (remainder << 32) | limbs[i]
      limbs[i] = current / base
      remainder = current % base
    }
    groups.push(remainder.reinterpret_as_int64())
    left = limbs[0] != 0UL ||
      limbs[1] != 0UL ||
      limbs[2] != 0UL ||
      limbs[3] != 0UL
  }
  if groups.is_empty() {
    return "0"
  }
  let mut text = groups[groups.length() - 1].to_string()
  for i = groups.length() - 2; i >= 0; i = i - 1 {
    let group = groups[i].to_string()
    let mut pad = 9 - group.length()
    while pad > 0 {
      text = "\{text}0"
      pad -= 1
    }
    text = "\{text}\{group}"
  }
  text
}

///|
/// The digits without the zeros they end in, and how many there were.
fn without_trailing_zeros(digits : String) -> (String, Int32) {
  let mut end = digits.length()
  while end > 1 && digits[end - 1] == '0' {
    end -= 1
  }
  (digits[:end].to_owned(), digits.length() - end)
}

///|
/// Ten times a 128-bit accumulator plus one digit, over the high and low
/// halves — the multiply-by-ten-and-carry every digit of the accumulator
/// passes through. The caller bounds the run at 38 digits, so no bit ever
/// leaves the pair.
fn times_ten_plus(
  acc_hi : UInt64,
  acc_lo : UInt64,
  digit : UInt64,
) -> (UInt64, UInt64) {
  let lo_prod = mul_u64(10UL, acc_lo)
  let hi_prod = mul_u64(10UL, acc_hi)
  let new_hi = hi_prod.0 + lo_prod.1
  let new_lo = lo_prod.0 + digit
  if new_lo < lo_prod.0 {
    (new_hi + 1UL, new_lo)
  } else {
    (new_hi, new_lo)
  }
}

///|
/// The low and high halves of a UInt64 product (low, high) — the multiply
/// the 128-bit accumulator rides, over 32-bit halves.
fn mul_u64(a : UInt64, b : UInt64) -> (UInt64, UInt64) {
  let a_lo = a & 0xFFFF_FFFFUL
  let a_hi = a >> 32
  let b_lo = b & 0xFFFF_FFFFUL
  let b_hi = b >> 32
  let ll = a_lo * b_lo
  let lh = a_lo * b_hi
  let hl = a_hi * b_lo
  let hh = a_hi * b_hi
  let mid1 = ll + (lh << 32)
  let carry1 = if mid1 < ll { 1UL } else { 0UL }
  let mid2 = mid1 + (hl << 32)
  let carry2 = if mid2 < mid1 { 1UL } else { 0UL }
  (mid2, hh + (lh >> 32) + (hl >> 32) + carry1 + carry2)
}
