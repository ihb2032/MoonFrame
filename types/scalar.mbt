///|
/// A single cell value in a DataFrame.
///
/// `Null` represents a missing value. All `as_*` conversions and comparisons
/// involving `Null` `raise TypeMismatch(...)` — callers must check
/// `is_null()` first or handle the error.
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
  match self {
    Null => true
    _ => false
  }
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
/// `raise TypeMismatch(...)`.
pub fn Scalar::as_int(self : Scalar) -> Int64 raise DataError {
  match self {
    Int(v) => v
    Null => raise TypeMismatch("expected Int, got Null")
    other => raise TypeMismatch("expected Int, got \{other.dtype()}")
  }
}

///|
/// `Float` cells return their `Double`; `Int` cells are promoted to
/// `Double`; other concrete variants and `Null` `raise TypeMismatch(...)`.
pub fn Scalar::as_float(self : Scalar) -> Double raise DataError {
  match self {
    Float(v) => v
    Int(v) => v.to_double()
    Null => raise TypeMismatch("expected Float, got Null")
    other => raise TypeMismatch("expected Float, got \{other.dtype()}")
  }
}

///|
/// `Bool` cells return their value; other concrete variants and `Null`
/// `raise TypeMismatch(...)`.
pub fn Scalar::as_bool(self : Scalar) -> Bool raise DataError {
  match self {
    Bool(v) => v
    Null => raise TypeMismatch("expected Bool, got Null")
    other => raise TypeMismatch("expected Bool, got \{other.dtype()}")
  }
}

///|
/// `String` cells return their value; other concrete variants and `Null`
/// `raise TypeMismatch(...)`.
pub fn Scalar::as_string(self : Scalar) -> String raise DataError {
  match self {
    String(v) => v
    Null => raise TypeMismatch("expected String, got Null")
    other => raise TypeMismatch("expected String, got \{other.dtype()}")
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
  raise TypeMismatch("cannot compare \{left.dtype()} and \{right.dtype()}")
}

///|
/// Equality between two `Scalar`s. Two `Null`s, or `Null` and a value,
/// `raise TypeMismatch` — callers must guard nullability explicitly. Mixed
/// numeric types (`Int` vs `Float`) compare after promoting `Int` to
/// `Double` (the Float64 supertype, as in Polars); NaN follows IEEE 754
/// semantics (`NaN == NaN` is `false`).
///
/// Precision caveat: the `Int`→`Double` promotion is lossy for an `Int`
/// magnitude beyond 2^53, where a `Double` can no longer represent every
/// integer, so two distinct large values can compare equal — e.g.
/// `Int(9223372036854775807)` (2^63-1) promotes to `2^63`, which equals
/// `Float(9.223372036854776e18)`. Same-dtype `Int`/`Int` comparisons are
/// always exact; only the mixed `Int`-vs-`Float` arms widen.
pub fn Scalar::eq(self : Scalar, other : Scalar) -> Bool raise DataError {
  match (self, other) {
    (Null, _) | (_, Null) => raise TypeMismatch("cannot compare with Null")
    (Int(a), Int(b)) => a == b
    (Float(a), Float(b)) => a == b
    (Int(a), Float(b)) => a.to_double() == b
    (Float(a), Int(b)) => a == b.to_double()
    (Bool(a), Bool(b)) => a == b
    (String(a), String(b)) => a == b
    _ => type_mismatch_for_compare(self, other)
  }
}

///|
/// Strict less-than. NaN follows IEEE 754: any comparison involving `NaN`
/// returns `false`. `Null` short-circuits to `raise`. Mixed `Int`-vs-`Float`
/// ordering widens `Int` to `Double` and shares `eq`'s 2^53 precision caveat,
/// so it can mis-order two distinct values across that boundary.
pub fn Scalar::lt(self : Scalar, other : Scalar) -> Bool raise DataError {
  match (self, other) {
    (Null, _) | (_, Null) => raise TypeMismatch("cannot compare with Null")
    (Int(a), Int(b)) => a < b
    (Float(a), Float(b)) => a < b
    (Int(a), Float(b)) => a.to_double() < b
    (Float(a), Int(b)) => a < b.to_double()
    (Bool(a), Bool(b)) => (a |> bool_to_int) < (b |> bool_to_int)
    (String(a), String(b)) => compare_string_lex(a, b) < 0
    _ => type_mismatch_for_compare(self, other)
  }
}

///|
/// Less-than-or-equal — `eq` or `lt`. Shares their `Null`-`raise` and
/// `Int`/`Float` promotion semantics.
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
