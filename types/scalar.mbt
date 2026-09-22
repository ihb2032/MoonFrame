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
pub(all) enum Scalar {
  Int(Int64)
  Float(Double)
  Bool(Bool)
  String(String)
  Date(Int64)
  Null
} derive(Eq, Debug)

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
    Null => logger.write_string("Null")
  }
}

///|
/// Render whole days since the Unix epoch as an ISO `YYYY-MM-DD` date —
/// the one rendering a `Scalar::Date` has (value form, `Show` form, CSV /
/// JSON cell form all share it, so the spellings cannot drift). Proleptic
/// Gregorian, via the days-to-civil algorithm: negative day counts (dates
/// before 1970) included.
fn date_days_to_iso(days : Int64) -> String {
  let z = days + 719468L
  // Floor division, so dates before the era anchor land in the previous
  // 400-year era instead of truncating toward zero.
  let era = if z >= 0 { z / 146097L } else { (z - 146096L) / 146097L }
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = if m <= 2L { y + 1L } else { y }
  fn pad2(n : Int64) -> String {
    if n < 10 {
      "0\{n}"
    } else {
      n.to_string()
    }
  }

  "\{year}-\{pad2(m)}-\{pad2(d)}"
}
