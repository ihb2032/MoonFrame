///|
/// A single cell value in a DataFrame.
///
/// `Null` represents a missing value. The `as_*` conversions `raise
/// TypeMismatch(Expected(expected, got, ""))` on a wrong dtype (`got = Null` for a null
/// cell). Comparisons `raise TypeMismatch(...)` on `Null`, or
/// `TypeMismatch(Operation("compare", left, right))` on an incomparable non-null pair —
/// callers must check `is_null()` first or handle the error.
///
/// The `Float` variant carries a 64-bit `Double`; the `Int` variant carries
/// a 64-bit `Int64`. Use `as_float` for explicit access; `Int` is also
/// accepted via numeric promotion to `Double`.
pub(all) enum Scalar {
  Int(Int64)
  Float(Double)
  Bool(Bool)
  String(String)
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
/// `Null` → `""`. Use the `Show` impl for the variant-form rendering.
pub fn Scalar::to_string(self : Scalar) -> String {
  match self {
    Int(v) => v.to_string()
    Float(v) => v.to_string()
    Bool(v) => v.to_string()
    String(v) => v
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
/// Always raises — the shared failure path for `eq` / `lt` on two
/// incomparable concrete dtypes. The `Bool` result type lets it slot into
/// the comparison match arms that produce a `Bool`.
fn type_mismatch_for_compare(
  left : Scalar,
  right : Scalar,
) -> Bool raise DataError {
  raise TypeMismatch(
    TypeMismatchDetail::Operation("compare", left.dtype(), right.dtype()),
  )
}

///|
/// The shared `Null`-`raise` for `eq` / `lt`: a comparison against `Null` is an
/// error the caller must guard, not a silent `false`. `Bool`-typed to slot into
/// the comparison match arms, like `type_mismatch_for_compare`.
fn null_compare_error() -> Bool raise DataError {
  raise TypeMismatch(TypeMismatchDetail::Message("cannot compare with Null"))
}

///|
/// Equality between two `Scalar`s. Two `Null`s, or `Null` and a value,
/// `raise TypeMismatch` — callers must guard nullability explicitly. Mixed
/// numeric types (`Int` vs `Float`) compare **exactly** — the `Int64` is not
/// promoted to `Double`, so two distinct values never collide above `2^53`
/// (e.g. `Int(9007199254740993)` is *not* equal to
/// `Float(9007199254740992.0)`, and `Int64::MAX` is not equal to the `2^63`
/// `Double` a promotion would round it to). This is a deliberate departure
/// from Polars' Float64-supertype promotion, chosen for correctness. `NaN`
/// follows IEEE 754 (`NaN == NaN` is `false`).
pub fn Scalar::eq(self : Scalar, other : Scalar) -> Bool raise DataError {
  match (self, other) {
    (Null, _) | (_, Null) => null_compare_error()
    (Int(a), Int(b)) => a == b
    (Float(a), Float(b)) => a == b
    (Int(a), Float(b)) => int64_eq_double(a, b)
    (Float(a), Int(b)) => int64_eq_double(b, a)
    (Bool(a), Bool(b)) => a == b
    (String(a), String(b)) => a == b
    _ => type_mismatch_for_compare(self, other)
  }
}

///|
/// Strict less-than. NaN follows IEEE 754: any comparison involving `NaN`
/// returns `false`. `Null` short-circuits to `raise`. Mixed `Int`-vs-`Float`
/// ordering is **exact** (no `Int`→`Double` promotion), so it never mis-orders
/// two distinct values across the `2^53` boundary — the same deliberate
/// departure from Polars as `eq`.
pub fn Scalar::lt(self : Scalar, other : Scalar) -> Bool raise DataError {
  match (self, other) {
    (Null, _) | (_, Null) => null_compare_error()
    (Int(a), Int(b)) => a < b
    (Float(a), Float(b)) => a < b
    (Int(a), Float(b)) => int64_lt_double(a, b)
    (Float(a), Int(b)) => double_lt_int64(a, b)
    (Bool(a), Bool(b)) => (a |> bool_to_int) < (b |> bool_to_int)
    (String(a), String(b)) => @text.compare_string_lex(a, b) < 0
    _ => type_mismatch_for_compare(self, other)
  }
}

///|
/// Less-than-or-equal — `eq` or `lt`. Shares their `Null`-`raise` and exact
/// `Int`/`Float` comparison semantics.
pub fn Scalar::lte(self : Scalar, other : Scalar) -> Bool raise DataError {
  if self.eq(other) {
    true
  } else {
    self.lt(other)
  }
}

///|
/// Whether the pair reaches a value arm of `lt` / `eq` — i.e. anything but
/// the incomparable-dtypes fallthrough. `Null` counts: it reaches the
/// dedicated `Null`-`raise` arm, whose fixed message has no operand order
/// to preserve. The gate `gt` / `gte` consult so their transposed
/// delegation cannot also transpose the diagnostic.
fn comparable_pair(a : Scalar, b : Scalar) -> Bool {
  match (a, b) {
    (Null, _) | (_, Null) => true
    (Int(_) | Float(_), Int(_) | Float(_)) => true
    (Bool(_), Bool(_)) => true
    (String(_), String(_)) => true
    _ => false
  }
}

///|
/// Strict greater-than, defined as `other.lt(self)` — same `Null`-`raise` and
/// ordering rules as `lt`. The delegation transposes the operands, so the
/// incomparable-dtypes diagnostic is issued here first, in the caller's
/// operand order — `Int(1).gt(String("x"))` reports "Int and String", not
/// the transposed pair `eq` / `lt` / `lte` would never produce.
pub fn Scalar::gt(self : Scalar, other : Scalar) -> Bool raise DataError {
  if !comparable_pair(self, other) {
    type_mismatch_for_compare(self, other)
  } else {
    other.lt(self)
  }
}

///|
/// Greater-than-or-equal, defined as `other.lte(self)` — same rules as
/// `lte`, with `gt`'s call-order diagnostic for an incomparable pair.
pub fn Scalar::gte(self : Scalar, other : Scalar) -> Bool raise DataError {
  if !comparable_pair(self, other) {
    type_mismatch_for_compare(self, other)
  } else {
    other.lte(self)
  }
}

///|
fn bool_to_int(b : Bool) -> Int {
  if b {
    1
  } else {
    0
  }
}

///|
/// `Show` renders the variant form (`Int(42)`, `String("ab")`, `Null`).
/// For value-style rendering use `to_string()`.
pub impl Show for Scalar with fn output(self, logger) {
  match self {
    Int(v) => logger.write_string("Int(\{v})")
    Float(v) => logger.write_string("Float(\{v})")
    Bool(v) => logger.write_string("Bool(\{v})")
    String(v) => logger.write_string("String(\"\{@text.escape_debug(v)}\")")
    Null => logger.write_string("Null")
  }
}
