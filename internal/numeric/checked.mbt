// The checked `Int64` arithmetic the decimal dtype rides: a decimal cell's
// magnitude must stay exact (the dtype's whole point), so every widening
// step — an add that leaves the range, a multiply, a rescale's shift —
// either holds or reports `None`, never wraps into a confidently wrong
// value the way plain `Int64` arithmetic (total, documented as wrapping for
// the `Int` dtype) would. Each check is one range test on the result,
// spelled once here beside its siblings; this package is self-contained,
// so the refusal is an `Option` and the error vocabulary belongs to the
// kernel that asks.

///|
/// The exact sum of two `Int64` magnitudes, or `None` when the sum leaves
/// the range. Same-signed operands are the only overflow shape (a
/// mixed-sign pair cancels toward zero), so the sign flip of the result is
/// the whole test.
pub fn add_checked(a : Int64, b : Int64) -> Int64? {
  let r = a + b
  if (a >= 0L && b >= 0L && r < 0L) || (a < 0L && b < 0L && r >= 0L) {
    None
  } else {
    Some(r)
  }
}

///|
/// The exact difference of two `Int64` magnitudes, or `None` when it
/// leaves the range. Subtraction cannot be spelled `add_checked(a, -b)`:
/// negating a `MIN` subtrahend wraps before the check ever sees a true
/// value, so the `MIN` case is decided directly — a non-negative minuend
/// leaves the range, a negative one lands in `[0, MAX]` exactly.
pub fn sub_checked(a : Int64, b : Int64) -> Int64? {
  if b == -9_223_372_036_854_775_808L {
    if a >= 0L {
      None
    } else {
      Some(a - b)
    }
  } else {
    add_checked(a, -b)
  }
}

///|
/// The exact product of two `Int64` magnitudes, or `None` when it leaves
/// the range. The divide-back verification catches every wraparound (a
/// zero operand short-circuits; the `MIN * -1 = MIN` wraparound fails the
/// check, since `MIN / MIN` is `1`, not `-1`). The one quotient `Int64`
/// division cannot represent — `MIN / -1`, a trap on every backend, not a
/// `None` — is refused before the verification divides: a wrapped product
/// of `MIN` beside a `-1` operand is an overflow by definition.
pub fn mul_checked(a : Int64, b : Int64) -> Int64? {
  if a == 0L || b == 0L {
    return Some(0L)
  }
  if (a == -1L && b == -9_223_372_036_854_775_808L) ||
    (a == -9_223_372_036_854_775_808L && b == -1L) {
    return None
  }
  let r = a * b
  if r / a != b || r / b != a {
    None
  } else {
    Some(r)
  }
}

///|
/// Re-express an unscaled decimal magnitude at a larger scale — the exact
/// shift `v * 10^(to - from)`, or `None` when it leaves the range. A
/// smaller (precision-losing) or equal target is refused the same way:
/// this lift exists to align two scales, and only the widening direction
/// is exact.
pub fn rescale_unscaled(from : Int32, to : Int32, v : Int64) -> Int64? {
  if to <= from {
    return None
  }
  let mut r = v
  for _ in from..<to {
    match mul_checked(r, 10L) {
      Some(shifted) => r = shifted
      None => return None
    }
  }
  Some(r)
}
