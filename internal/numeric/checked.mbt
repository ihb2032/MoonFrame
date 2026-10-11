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
/// The exact product of two `Int64` magnitudes, or `None` when it leaves
/// the range. The divide-back verification catches every wraparound (a
/// zero operand short-circuits; the `MIN * -1 = MIN` wraparound fails the
/// check, since `MIN / MIN` is `1`, not `-1`).
pub fn mul_checked(a : Int64, b : Int64) -> Int64? {
  if a == 0L || b == 0L {
    return Some(0L)
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
pub fn rescale_unscaled(from : Int, to : Int, v : Int64) -> Int64? {
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
