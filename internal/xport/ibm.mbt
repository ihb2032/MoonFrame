// The IBM hexadecimal floating-point a numeric cell is stored in, and its
// conversion to the numbers the library holds.

///|
/// The 64 bits of one numeric cell, named as the IBM layout names them.
/// The first byte carries the sign in its high bit and a 7-bit base-16
/// exponent in excess of 64; the other 56 bits are a fraction standing
/// for the hexadecimal fraction `0.f`. A cell holds the value
/// `(-1)^sign * 0.f * 16^(exponent - 64)`, which is
/// `fraction * 2^(4 * (exponent - 78))` once the fraction is read as an
/// integer.
priv struct IbmBits {
  first : Int32
  fraction : UInt64
}

///|
/// The bits of the numeric cell `width` bytes wide that starts at byte
/// `at`. A numeric variable is stored in 2 to 8 bytes; a cell narrower
/// than 8 holds the leading bytes of the 8-byte spelling, so the bytes it
/// lacks are zeros. `at + width` lies inside the bytes.
fn ibm_bits(bytes : Bytes, at : Int32, width : Int32) -> IbmBits {
  let mut fraction = 0UL
  for i in 1..<8 {
    fraction = if i < width {
      (fraction << 8) | bytes[at + i].to_uint64()
    } else {
      fraction << 8
    }
  }
  { first: bytes[at].to_int(), fraction, }
}

///|
/// Whether the bits spell one of the 28 missing values: `.`, `._` or
/// `.A` to `.Z`. Each is a first byte of `0x2E`, `0x5F`, or `0x41` to
/// `0x5A`, followed by seven zero bytes. The sign bit takes part: the
/// same byte with its high bit set spells a number, not a missing value.
fn IbmBits::is_missing(self : IbmBits) -> Bool {
  self.fraction == 0UL &&
  (
    self.first == 0x2E ||
    self.first == 0x5F ||
    (self.first >= 0x41 && self.first <= 0x5A)
  )
}

///|
/// Whether the sign bit is set.
fn IbmBits::is_negative(self : IbmBits) -> Bool {
  self.first >= 0x80
}

///|
/// The power of two `2^exponent`, for an exponent from -1022 to 1023:
/// a double with that exponent field and a zero fraction.
fn power_of_two(exponent : Int32) -> Double {
  ((exponent + 1023).to_uint64() << 52).reinterpret_as_double()
}

///|
/// The double nearest to the cell's value: the value itself when the
/// fraction needs 53 significant bits or fewer, and otherwise the
/// correctly rounded double (round half to even). The conversion is
/// integer arithmetic throughout, so no double rounding intervenes.
///
/// A nonzero fraction has a magnitude between 2^-312 and 2^252, so the
/// result is a normal double. A zero fraction is zero, with the sign bit
/// as its sign: the spelling `0x80` followed by seven zeros reads as
/// -0.0.
fn IbmBits::to_double(self : IbmBits) -> Double {
  if self.fraction == 0UL {
    return if self.is_negative() { -0.0 } else { 0.0 }
  }
  // Dropping the trailing zeros leaves an odd integer whose bit length
  // is the fraction's count of significant bits, whichever hex digit
  // leads the fraction.
  let zeros = self.fraction.ctz()
  let odd = self.fraction >> zeros
  let significant = 64 - odd.clz()
  let power = 4 * ((self.first & 0x7F) - 78) + zeros
  let (significand, exponent) = if significant <= 53 {
    (odd, power)
  } else {
    // One to three bits must go: round half to even on what is dropped.
    let drop = significant - 53
    let kept = odd >> drop
    let lost = odd & ((1UL << drop) - 1UL)
    let half = 1UL << (drop - 1)
    let round_up = lost > half || (lost == half && (kept & 1UL) == 1UL)
    let mut rounded = kept + (if round_up { 1UL } else { 0UL })
    // The kept part stands `drop` bits lower than the odd part did.
    let mut scale = power + drop
    if rounded == 1UL << 53 {
      rounded = 1UL << 52
      scale += 1
    }
    (rounded, scale)
  }
  let magnitude = significand.to_double() * power_of_two(exponent)
  if self.is_negative() {
    -magnitude
  } else {
    magnitude
  }
}

///|
/// The cell's value in whole days, when its double is a whole number a
/// signed 64-bit count holds; otherwise `Err`.
fn IbmBits::to_days(self : IbmBits) -> Result[Int64, Unit] {
  let value = self.to_double()
  if value != value.floor() ||
    value > 9000000000000000000.0 ||
    value < -9000000000000000000.0 {
    Err(())
  } else {
    Ok(value.to_int64())
  }
}

///|
/// The cell's value in whole microseconds, when its double spells that
/// count without loss: `value * 10^6` in double arithmetic is a whole
/// number, a signed 64-bit count holds it, and divided by `10^6` again it
/// is the same double. A value with a part below a microsecond that its
/// double can tell from zero fails the last test, so it is `Err`, and no
/// such part is ever rounded away.
fn IbmBits::to_micros(self : IbmBits) -> Result[Int64, Unit] {
  let value = self.to_double()
  if value == 0.0 {
    return Ok(0L)
  }
  let scaled = value * 1000000.0
  if scaled != scaled.floor() ||
    scaled > 9000000000000000000.0 ||
    scaled < -9000000000000000000.0 ||
    scaled / 1000000.0 != value {
    Err(())
  } else {
    Ok(scaled.to_int64())
  }
}

///|
/// The IBM spelling of a finite double as the 64 bits of a cell. Every
/// finite double whose magnitude lies in `[16^-65, 16^63)` is an IBM
/// float exactly: the double's 53 significant bits move left by 0 to 3
/// bits into the 56-bit fraction. Outside that range lies `Err`: the
/// format would need a fraction that is not normalized, and readers do
/// not agree on what such a spelling holds.
fn ibm_bits_of(value : Double) -> Result[UInt64, Unit] {
  let bits = value.reinterpret_as_uint64()
  let sign = bits >> 63
  let stored_exponent = (bits >> 52) & 0x7FFUL
  if stored_exponent == 0UL || stored_exponent == 0x7FFUL {
    return Err(())
  }
  // The double is `significand * 2^exponent` with a 53-bit significand.
  let exponent = stored_exponent.to_int() - 1023
  let significand = (1UL << 52) | (bits & ((1UL << 52) - 1UL))
  // The IBM exponent is the base-16 power the magnitude sits below. An
  // arithmetic shift floors, which a negative exponent needs.
  let base16 = (exponent + 4) >> 2
  let shift_left = exponent + 4 - 4 * base16
  if base16 < -64 || base16 > 63 {
    return Err(())
  }
  Ok(
    (sign << 63) |
    ((base16 + 64).to_uint64() << 56) |
    (significand << shift_left),
  )
}

///|
/// The 64 bits of the missing value `.`.
const MISSING : UInt64 = 0x2E00000000000000UL
