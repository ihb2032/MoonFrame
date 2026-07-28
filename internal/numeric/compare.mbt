///|
/// Whether `n` falls in the range `Double::to_int64` converts faithfully —
/// i.e. within `Int64`'s representable range. `Int64::MIN = -2^63` is exactly
/// representable as a `Double`; `Int64::MAX = 2^63 - 1` is not — the largest
/// `Double` strictly below `2^63` is `9223372036854774784` (`2^63 - 1024`),
/// and anything above it rounds to a `Double` >= `2^63` that would overflow
/// `Int64`. `NaN` is out of range (every comparison with it is `false`). The
/// shared guard that `Float`->`Int` casting (`@column`) and JSON integer
/// reading (`@io`) both check before calling `Double::to_int64`, whose result
/// is implementation-defined outside this range. Total.
pub fn double_fits_int64(n : Double) -> Bool {
  n >= min_int_as_double && n <= max_int_as_double
}

///|
/// `Int64::MIN = -2^63`, exactly representable as a `Double`.
let min_int_as_double : Double = -9223372036854775808.0

///|
/// The largest `Double` strictly below `2^63` (`2^63 - 1024`) — the effective
/// upper bound, since `Int64::MAX = 2^63 - 1` is not exactly representable.
let max_int_as_double : Double = 9223372036854774784.0

///|
/// `a == b`, comparing an `Int64` and a `Double` **exactly** — no promotion to
/// `Double`, so no precision loss above `2^53`. `false` when `b` is `NaN`, has
/// a fractional part, or lies outside `Int64`'s range (so `Int64::MAX` is not
/// equal to the `2^63` `Double` its promotion would round to). Total.
pub fn int64_eq_double(a : Int64, b : Double) -> Bool {
  if double_fits_int64(b) {
    let bi = b.to_int64()
    bi == a && bi.to_double() == b
  } else {
    false
  }
}

///|
/// `a < b`, comparing an `Int64` and a `Double` **exactly**. `NaN` is
/// unordered, so any comparison with it is `false`. Total.
pub fn int64_lt_double(a : Int64, b : Double) -> Bool {
  if b.is_nan() {
    false
  } else if !double_fits_int64(b) {
    // `b >= 2^63` (or `+Inf`) ⟹ `a < b`; `b < -2^63` (or `-Inf`) ⟹ `a > b`.
    b > max_int_as_double
  } else {
    let bf = b.floor()
    let bi = bf.to_int64()
    a < bi || (a == bi && b > bf)
  }
}

///|
/// `a < b`, comparing a `Double` and an `Int64` **exactly** (the transposed
/// direction of `int64_lt_double`). `NaN` is unordered (`false`). Total.
pub fn double_lt_int64(a : Double, b : Int64) -> Bool {
  if a.is_nan() {
    false
  } else if !double_fits_int64(a) {
    // `a < -2^63` (or `-Inf`) ⟹ `a < b`; `a >= 2^63` (or `+Inf`) ⟹ `a > b`.
    a < min_int_as_double
  } else {
    a.floor().to_int64() < b
  }
}
