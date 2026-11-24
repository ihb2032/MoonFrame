// The Decimal128 cell: sixteen bytes of an unscaled two's-complement
// integer, under the type's scale. MoonFrame's decimal is a decimal128
// floating-point value, whose coefficient holds 34 digits; an unscaled
// integer that needs no more than that, counted without its trailing
// zeros, is read exactly — digit for digit — and one that needs more
// refuses naming the column. The same digits are written back, lifted by
// the scale, when a decimal column is written.

///|
/// The decimal a Decimal128 cell carries: `scale` fraction digits over
/// the two's-complement integer in the sixteen bytes at `at`.
fn decimal128_of(
  data : Buf,
  at : Int32,
  scale : Int32,
  big : Bool,
  column : String,
) -> @types.Dec128 raise @types.DataError {
  // Sixteen bytes in the body's endianness: the low half comes first in
  // a little-endian body, and the high half in a big-endian one.
  let (low, high) = if big {
    (data.uint(at + 8, 8, big), data.uint(at, 8, big))
  } else {
    (data.uint(at, 8, big), data.uint(at + 8, 8, big))
  }
  let negative = high >> 63 == 1UL
  // A negative integer's magnitude is its two's complement: the low half
  // inverted and raised by one, which carries into the high half when the
  // low half is zero.
  let (mag_low, mag_high) = if negative {
    let flipped = low ^ 0xFFFFFFFFFFFFFFFFUL
    if low == 0UL {
      (0UL, (high ^ 0xFFFFFFFFFFFFFFFFUL) + 1UL)
    } else {
      (flipped + 1UL, high ^ 0xFFFFFFFFFFFFFFFFUL)
    }
  } else {
    (low, high)
  }
  let (coefficient, zeros) = without_trailing_zeros(
    decimal_digits(mag_low, mag_high),
  )
  if coefficient.length() > 34 {
    raise cannot_carry(
      "column \"\{column}\" carries a decimal cell with \{coefficient.length()} significant digits, past the 34 a decimal holds",
    )
  }
  // The value is assembled from its digits, each step by ten and each
  // digit added exact while the coefficient holds at most 34 of them, and
  // scaled by the power of ten the trailing zeros and the column's scale
  // give — so no digit is rounded away, and nothing is left to a parser.
  let ten = @types.Dec128::of_int64(10L)
  let mut value = @types.Dec128::zero()
  for digit in coefficient {
    value = value
      .mul(ten)
      .add(@types.Dec128::of_int64((digit.to_int() - 48).to_int64()))
  }
  let scaled = value.mul(@types.Dec128::of_int64_scale(1L, scale=scale - zeros))
  if negative {
    scaled.neg()
  } else {
    scaled
  }
}

///|
/// The decimal digits of a 128-bit magnitude given as its low and high
/// 64-bit halves, with no leading zero; `"0"` for zero. The magnitude is
/// divided by 10^9 over four 32-bit limbs until nothing is left, and the
/// remainders are its groups of nine digits, least significant first.
fn decimal_digits(low : UInt64, high : UInt64) -> String {
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
