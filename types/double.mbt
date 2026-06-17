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
