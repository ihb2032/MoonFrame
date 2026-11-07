///|
/// A single cell value in a DataFrame.
///
/// `Null` represents a missing value. The `as_*` conversions `raise
/// `TypeMismatch(Expected(expected, got, ""))` on a wrong dtype (`got = Null` for a null
/// cell). Comparisons between cells are column-level — an expression's
/// `eq` / `lt` / `gt` verbs — and their dtype matrix lives on the comparison
/// kernel, not here.
///
/// The `Float` variant carries a 64-bit `Double`; the `Int` variant carries
/// a 64-bit `Int64`. Use `as_float` for explicit access; `Int` is also
/// accepted via numeric promotion to `Double`. The `Date` variant carries
/// whole days since the Unix epoch (`1970-01-01` = day `0`), rendering as an
/// ISO `YYYY-MM-DD` string.
#derive(Eq, Debug)
pub(all) enum Scalar {
  Int(Int64)
  Float(Double)
  Bool(Bool)
  String(String)
  Date(Int64)
  Timestamp(Int64)
  Decimal(Int32, Int64)
  Duration(Int64)
  Null
}

///|
pub extend Scalar with Eq::{equal, not_equal}

///|
pub extend Scalar with Show::{output}

///|
pub extend Scalar with Debug::{to_repr}

///|
/// The `DataType` corresponding to this value's variant.
pub fn Scalar::dtype(self : Scalar) -> DataType {
  match self {
    Int(_) => DataType::Int
    Float(_) => DataType::Float
    Bool(_) => DataType::Bool
    String(_) => DataType::String
    Date(_) => DataType::Date
    Timestamp(_) => DataType::Timestamp
    Decimal(scale, _) => DataType::Decimal(scale)
    Duration(_) => DataType::Duration
    Null => DataType::Null
  }
}

///|
/// `true` only for the `Null` (missing-value) variant.
pub fn Scalar::is_null(self : Scalar) -> Bool {
  self is Null
}

///|
/// Value-style rendering: `Int(42)` → `"42"`, `String("ab")` → `"ab"`,
/// `Date(0)` → `"1970-01-01"`, `Null` → `""`. Use the `Show` impl for the
/// variant-form rendering.
pub fn Scalar::to_string(self : Scalar) -> String {
  match self {
    Int(v) => v.to_string()
    Float(v) => v.to_string()
    Bool(v) => v.to_string()
    String(v) => v
    Date(v) => date_days_to_iso(v)
    Timestamp(v) => timestamp_micros_to_iso(v)
    Decimal(scale, v) => decimal_unscaled_to_string(scale, v)
    Duration(v) => duration_micros_to_iso(v)
    Null => ""
  }
}

///|
/// The `TypeMismatch(Expected(want, got, ""))` a typed accessor raises when a
/// cell is not `want`: the dtype is read off `got`, and `message()` rebuilds
/// the "expected T, got X" wording (`X = Null` for a null cell, whose dtype is
/// `Null`). Generic in the accessor's return type since it only ever raises.
fn[T] expected_type(got : Scalar, want : DataType) -> T raise DataError {
  raise TypeMismatch(TypeMismatchDetail::Expected(want, got.dtype(), ""))
}

///|
/// `Int` cells return their `Int64`; other concrete variants and `Null`
/// `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_int(self : Scalar) -> Int64 raise DataError {
  match self {
    Int(v) => v
    other => expected_type(other, DataType::Int)
  }
}

///|
/// `Float` cells return their `Double`; `Int` cells are promoted to
/// `Double`; other concrete variants and `Null` `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_float(self : Scalar) -> Double raise DataError {
  match self {
    Float(v) => v
    Int(v) => v.to_double()
    other => expected_type(other, DataType::Float)
  }
}

///|
/// `Bool` cells return their value; other concrete variants and `Null`
/// `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_bool(self : Scalar) -> Bool raise DataError {
  match self {
    Bool(v) => v
    other => expected_type(other, DataType::Bool)
  }
}

///|
/// `String` cells return their value; other concrete variants and `Null`
/// `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_string(self : Scalar) -> String raise DataError {
  match self {
    String(v) => v
    other => expected_type(other, DataType::String)
  }
}

///|
/// `Show` renders the variant form (`Int(42)`, `String("ab")`, `Null`).
/// For value-style rendering use `to_string()`.
pub impl Show for Scalar with fn output(self, logger) {
  match self {
    Int(v) => logger <+ "Int(\{v})"
    Float(v) => logger <+ "Float(\{v})"
    Bool(v) => logger <+ "Bool(\{v})"
    String(v) => logger <+ "String(\"\{@text.escape_debug(v)}\")"
    Date(v) => logger <+ "Date(\{date_days_to_iso(v)})"
    Timestamp(v) => logger <+ "Timestamp(\{timestamp_micros_to_iso(v)})"
    Decimal(scale, v) =>
      logger <+ "Decimal(\{scale}, \{decimal_unscaled_to_string(scale, v)})"
    Duration(v) => logger <+ "Duration(\{duration_micros_to_iso(v)})"
    Null => logger.write_string("Null")
  }
}

///|
/// Zero-pad a non-negative `Int64`'s decimal text to `width` digits —
/// one body for the ISO renderers' two- / four- / six-digit fields,
/// the width living at each call site.
fn pad_zero(n : Int64, width : Int32) -> String {
  let s = n.to_string()
  if s.length() >= width {
    s
  } else {
    String::make(width - s.length(), '0') + s
  }
}

///|
/// Render whole days since the Unix epoch as an ISO `YYYY-MM-DD` date —
/// the one rendering a `Scalar::Date` has (value form, `Show` form, CSV /
/// JSON cell form all share it, so the spellings cannot drift). Proleptic
/// Gregorian, via the days-to-civil algorithm: negative day counts (dates
/// before 1970) included. The year is zero-padded to four digits — ISO
/// 8601's `YYYY` basic range is `0000`–`9999`, so year 800 renders
/// `0800-…` and year 0 `0000-…`; a year outside the basic range carries
/// the expanded-representation form's sign — `-` below year 1, `+` above
/// 9999 (an expanded year without its sign is no ISO spelling).
fn date_days_to_iso(days : Int64) -> String {
  let (year, m, d) = date_days_to_civil(days)

  // The year pads its magnitude to four digits and carries its own sign —
  // `Int64::MIN` cannot occur here (the algorithm's `y` is bounded by
  // `|days| / 365`), so negating is safe.
  let year_text = if year < 0 {
    "-" + pad_zero(-year, 4)
  } else if year > 9999 {
    "+" + pad_zero(year, 4)
  } else {
    pad_zero(year, 4)
  }
  "\{year_text}-\{pad_zero(m, 2)}-\{pad_zero(d, 2)}"
}

///|
/// Split a microsecond count since the epoch into its whole-day floor and
/// the within-day remainder in `[0, 86_400_000_000)` — the decomposition
/// both the ISO rendering and the `dt_*` verbs read, so an instant's date
/// half and its clock half cannot disagree. Floor semantics by remainder
/// first: the C-remainder `r` carries the dividend's sign and never wraps,
/// `micros - r` is a multiple of the day bound no larger than the dividend,
/// and the corrections keep both the day quotient and the remainder small —
/// so the trick stays equivalent to floor division at every `Int64`, where
/// subtracting the bound before dividing (the direct spelling) would
/// underflow near MIN.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn timestamp_micros_to_day(micros : Int64) -> (Int64, Int64) {
  let r = micros % 86_400_000_000L
  let day = (micros - r) / 86_400_000_000L - (if r < 0L { 1L } else { 0L })
  let rem = r + (if r < 0L { 86_400_000_000L } else { 0L })
  (day, rem)
}

///|
/// The `(hour, minute, second, microsecond)` a within-day microsecond count
/// in `[0, 86_400_000_000)` names — plain divisions over a non-negative
/// remainder, the clock half of `timestamp_micros_to_day`'s split. A count
/// outside the day range answers whatever its own divisions name; the
/// callers that reach it pass the split's remainder.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn day_micros_to_clock(within_day : Int64) -> (Int64, Int64, Int64, Int64) {
  (
    within_day / 3_600_000_000L,
    within_day % 3_600_000_000L / 60_000_000L,
    within_day % 60_000_000L / 1_000_000L,
    within_day % 1_000_000L,
  )
}

///|
/// The ISO 8601 rendering of a microsecond count since the epoch — the one
/// rendering a `Scalar::Timestamp` has (value form, `Show` form, CSV / JSON
/// cell form all share it), composed from the date rendering above plus the
/// time-of-day the remainder names. The microsecond fraction is always six
/// digits, so the rendering round-trips (a parser can read back exactly the
/// count it came from); instants before the epoch carry the date's negative
/// year sign, the time-of-day stays in `[00:00:00, 24:00:00)`.
fn timestamp_micros_to_iso(micros : Int64) -> String {
  let (day, rem) = timestamp_micros_to_day(micros)

  let (hour, minute, second, frac) = day_micros_to_clock(rem)
  "\{date_days_to_iso(day)}T\{pad_zero(hour, 2)}:\{pad_zero(minute, 2)}:\{pad_zero(second, 2)}.\{pad_zero(frac, 6)}"
}

///|
/// The ISO 8601 duration rendering of a microsecond span — the one
/// rendering a `Scalar::Duration` has (value form, `Show` form, CSV / JSON
/// cell form all share it): days-and-time form, the seconds field always
/// present with a six-digit fraction (the `Timestamp` rendering's rule, so
/// the two temporal riders spell time alike), a day / hour / minute field
/// omitted when it is zero, and a leading `-` for a backwards span. The
/// magnitude is taken as an unsigned count (`Int64::MIN`'s own magnitude
/// is not representable as a positive `Int64`), so every span renders.
fn duration_micros_to_iso(micros : Int64) -> String {
  let sign = if micros < 0L { "-" } else { "" }
  // The magnitude is negated in the unsigned domain — a two's-complement
  // reinterpretation of a negative span would read as a huge count — so
  // every span decomposes, `Int64::MIN`'s own magnitude included, and
  // each decomposed field fits an `Int64` with room.
  let bits = micros.reinterpret_as_uint64()
  let u = if micros < 0L { 0UL - bits } else { bits }
  let day_us : UInt64 = 86_400_000_000UL
  let days = (u / day_us).reinterpret_as_int64()
  let rem = u % day_us
  let hour = (rem / 3_600_000_000UL).reinterpret_as_int64()
  let minute = (rem % 3_600_000_000UL / 60_000_000UL).reinterpret_as_int64()
  let second = (rem % 60_000_000UL / 1_000_000UL).reinterpret_as_int64()
  let frac = (rem % 1_000_000UL).reinterpret_as_int64()

  let days_text = if days == 0L { "" } else { "\{days}D" }
  let hour_text = if hour == 0L { "" } else { "\{hour}H" }
  let minute_text = if minute == 0L { "" } else { "\{minute}M" }
  "\{sign}P\{days_text}T\{hour_text}\{minute_text}\{second}.\{pad_zero(frac, 6)}S"
}

///|
/// The plain decimal rendering of an unscaled magnitude under a scale — the
/// one rendering a `Scalar::Decimal` has (value form, `Show` form, CSV /
/// JSON cell form all share it): the integer part, a point, and the fraction
/// zero-padded to exactly `scale` digits, so the rendering round-trips. A
/// zero scale renders with no point (`Decimal(0)` is an integer spelling);
/// a negative magnitude keeps one sign, its fraction digits from the
/// magnitude (`-5` under scale 2 renders `-0.05`). The magnitude's digits
/// come straight from `Int64::to_string` — `MIN` included, its digits after
/// the sign are the true magnitude — and the point is placed by counting
/// digits, never by arithmetic on the magnitude: no negation to wrap, no
/// power of ten to overflow, no division to trap. A scale outside the
/// enforced envelope `[0, 18]` can only arrive in a hand-built `pub(all)`
/// scalar; it renders as a named non-value rather than a number.
fn decimal_unscaled_to_string(scale : Int32, unscaled : Int64) -> String {
  if scale < 0 || scale > 18 {
    return "<decimal scale \{scale} outside the envelope [0, 18], unscaled \{unscaled}>"
  }
  if scale == 0 {
    return unscaled.to_string()
  }
  let raw = unscaled.to_string()
  let (sign, digits) = if unscaled < 0 {
    ("-", raw[1:].to_owned())
  } else {
    ("", raw)
  }
  if digits.length() <= scale {
    let mut frac = ""
    for _ in 0..<(scale - digits.length()) {
      frac = frac + "0"
    }
    "\{sign}0.\{frac}\{digits}"
  } else {
    let split = digits.length() - scale
    "\{sign}\{digits[:split].to_owned()}.\{digits[split:].to_owned()}"
  }
}

///|
/// The Gregorian calendar `(year, month, day)` a day count since the epoch
/// names, via the days-to-civil algorithm — negative counts (dates before
/// 1970) included. The one home of the calendar math: the ISO rendering
/// above composes it, and the engine's `dt_*` expression verbs read their
/// components from it, so the string and the verbs cannot disagree.
/// Total and correct over every `Int64`: the era arithmetic never forms
/// `days + 719468` (which wraps within 719468 of `Int64::MAX`), but splits
/// the count into an era quotient and a non-negative remainder first —
/// the same remainder-first floor division the timestamp rendering uses.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn date_days_to_civil(days : Int64) -> (Int64, Int64, Int64) {
  // `days = q * 146097 + s` with `s` in `[0, 146097)`: the C-remainder
  // never wraps, the quotient's correction shifts it to the floor, and
  // `s + 719468` is the original algorithm's `z` reduced into the current
  // era — always a small non-negative number.
  let s0 = days % 146097L
  let q0 = (days - s0) / 146097L
  let q = if s0 < 0L { q0 - 1L } else { q0 }
  let s = if s0 < 0L { s0 + 146097L } else { s0 }
  let z = s + 719468L
  // Floor division of `z` by the era length, both now non-negative and
  // small — the composite era is the split quotient plus z's own.
  let era = q + z / 146097L
  let doe = z % 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = if m <= 2L { y + 1L } else { y }
  (year, m, d)
}

///|
/// The day count since the epoch a Gregorian `(year, month, day)` names —
/// the inverse of `date_days_to_civil` above and its partner in the one
/// home of the calendar math: the ISO date parsing composes the pair as its
/// own validation (a scanned date is accepted exactly when the round trip
/// returns it unchanged, which threads month lengths and leap years with
/// no second copy of the rules). Exact over every year the inverse can
/// name — `|year|` below ~2.5e16, the image of every `Int64` day count —
/// via the same remainder-first floor the forward conversion uses; beyond
/// that the era product wraps (no `Int64` day count corresponds anyway).
fn days_from_civil(year : Int64, month : Int64, day : Int64) -> Int64 {
  // March-based months, so the leap day lands at a year's end where the
  // era arithmetic ignores it.
  let y = if month <= 2L { year - 1L } else { year }
  // Floor `y / 400` remainder-first: the C-remainder never wraps and the
  // correction keeps `yoe` a small non-negative remainder.
  let r = y % 400L
  let era = (y - r) / 400L - (if r < 0L { 1L } else { 0L })
  let yoe = r + (if r < 0L { 400L } else { 0L })
  let mp = if month > 2L { month - 3L } else { month + 9L }
  let doy = (153L * mp + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}
