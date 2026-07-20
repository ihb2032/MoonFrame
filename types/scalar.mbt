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
/// `Int` cells return their `Int64`; other concrete variants and `Null`
/// `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_int(self : Scalar) -> Int64 raise DataError {
  match self {
    Int(v) => v
    // Structured: the dtypes are read off the error, and `message()` rebuilds
    // the old "expected Int, got X" wording (`X = Null` for a null cell, whose
    // dtype is `Null`).
    other =>
      raise TypeMismatch(
        TypeMismatchDetail::Expected(DataType::Int, other.dtype(), ""),
      )
  }
}

///|
/// `Float` cells return their `Double`; `Int` cells are promoted to
/// `Double`; other concrete variants and `Null` `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_float(self : Scalar) -> Double raise DataError {
  match self {
    Float(v) => v
    Int(v) => v.to_double()
    other =>
      raise TypeMismatch(
        TypeMismatchDetail::Expected(DataType::Float, other.dtype(), ""),
      )
  }
}

///|
/// `Bool` cells return their value; other concrete variants and `Null`
/// `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_bool(self : Scalar) -> Bool raise DataError {
  match self {
    Bool(v) => v
    other =>
      raise TypeMismatch(
        TypeMismatchDetail::Expected(DataType::Bool, other.dtype(), ""),
      )
  }
}

///|
/// `String` cells return their value; other concrete variants and `Null`
/// `raise TypeMismatch(Expected(...))`.
pub fn Scalar::as_string(self : Scalar) -> String raise DataError {
  match self {
    String(v) => v
    other =>
      raise TypeMismatch(
        TypeMismatchDetail::Expected(DataType::String, other.dtype(), ""),
      )
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
    (Null, _) | (_, Null) =>
      raise TypeMismatch(
        TypeMismatchDetail::Message("cannot compare with Null"),
      )
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
    (Null, _) | (_, Null) =>
      raise TypeMismatch(
        TypeMismatchDetail::Message("cannot compare with Null"),
      )
    (Int(a), Int(b)) => a < b
    (Float(a), Float(b)) => a < b
    (Int(a), Float(b)) => int64_lt_double(a, b)
    (Float(a), Int(b)) => double_lt_int64(a, b)
    (Bool(a), Bool(b)) => (a |> bool_to_int) < (b |> bool_to_int)
    (String(a), String(b)) => compare_string_lex(a, b) < 0
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
    String(v) => logger.write_string("String(\"\{escape_debug(v)}\")")
    Null => logger.write_string("Null")
  }
}

///|
/// Display-syntax rendering of a literal `Scalar` — the one spelling shared
/// by the `expr` explain renderer and the `lazy` plan printer, so the two
/// can never drift apart (each used to carry a hand-synced private copy).
/// `Int` / `Bool` render bare, a `String` is quoted and
/// `escape_debug`-escaped so it stays distinguishable and on one line, and
/// the (unevaluatable) null literal renders as `null`. A `Float` stays
/// distinct from an `Int`: `Double::to_string` prints a finite whole value
/// without a decimal point (`1.0` -> `"1"`), so a `.0` suffix is re-added,
/// and it drops the sign of negative zero (`-0.0` -> `"0"`) even though the
/// two zeros evaluate observably differently under division
/// (`1.0 / -0.0 = -inf`), so the sign is re-added from the sign bit;
/// `NaN` / `Infinity` / `-Infinity` are non-finite and keep their own
/// spelling. Display syntax, not the debug form `Scalar`'s own `Show`
/// produces.
pub fn format_scalar_literal(value : Scalar) -> String {
  match value {
    Int(v) => v.to_string()
    Float(v) =>
      if v == 0.0 && v.reinterpret_as_int64() != 0L {
        "-0.0"
      } else {
        let s = v.to_string()
        let finite = v - v == 0.0
        let has_point = s.iter().any(c => c == '.' || c == 'e' || c == 'E')
        if finite && !has_point {
          s + ".0"
        } else {
          s
        }
      }
    Bool(v) => v.to_string()
    String(v) => "\"\{escape_debug(v)}\""
    Null => "null"
  }
}
