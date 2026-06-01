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
    other =>
      raise TypeMismatch("expected Int, got " + other.dtype().to_string())
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
    other =>
      raise TypeMismatch("expected Float, got " + other.dtype().to_string())
  }
}

///|
pub fn Scalar::as_bool(self : Scalar) -> Bool raise DataError {
  match self {
    Bool(v) => v
    Null => raise TypeMismatch("expected Bool, got Null")
    other =>
      raise TypeMismatch("expected Bool, got " + other.dtype().to_string())
  }
}

///|
pub fn Scalar::as_string(self : Scalar) -> String raise DataError {
  match self {
    String(v) => v
    Null => raise TypeMismatch("expected String, got Null")
    other =>
      raise TypeMismatch("expected String, got " + other.dtype().to_string())
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
    "cannot compare " +
    left.dtype().to_string() +
    " and " +
    right.dtype().to_string(),
  )
}

///|
/// Equality between two `Scalar`s. Two `Null`s, or `Null` and a value,
/// `raise TypeMismatch` — callers must guard nullability explicitly. Mixed
/// numeric types (`Int` vs `Float`) compare after promoting `Int` to
/// `Double`; NaN follows IEEE 754 semantics (`NaN == NaN` is `false`).
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
/// returns `false`. `Null` short-circuits to `raise`.
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
pub fn Scalar::lte(self : Scalar, other : Scalar) -> Bool raise DataError {
  if self.eq(other) {
    true
  } else {
    self.lt(other)
  }
}

///|
pub fn Scalar::gt(self : Scalar, other : Scalar) -> Bool raise DataError {
  other.lt(self)
}

///|
pub fn Scalar::gte(self : Scalar, other : Scalar) -> Bool raise DataError {
  other.lte(self)
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
/// Lexicographic string comparison by UTF-16 code unit, returning the
/// usual `-1` / `0` / `1`. MoonBit's built-in `<` / `Compare` on `String`
/// is **shortlex** (length first, then code unit) — e.g. `"fig" < "apple"`
/// is `true` because `"fig"` is shorter, which surprises users expecting
/// pandas / SQL dictionary order. Every user-facing ordering in MoonFrame
/// (`Scalar::lt`, `Series::min` / `max`, `DataFrame::sort_by`) routes through
/// this helper instead of the built-in operator so they all agree.
pub fn compare_string_lex(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  for i in 0..<n {
    let ca = a[i]
    let cb = b[i]
    if ca < cb {
      return -1
    }
    if ca > cb {
      return 1
    }
  }
  if la < lb {
    -1
  } else if la > lb {
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
    Int(v) => logger.write_string("Int(" + v.to_string() + ")")
    Float(v) => logger.write_string("Float(" + v.to_string() + ")")
    Bool(v) => logger.write_string("Bool(" + v.to_string() + ")")
    String(v) => logger.write_string("String(\"" + v + "\")")
    Null => logger.write_string("Null")
  }
}
