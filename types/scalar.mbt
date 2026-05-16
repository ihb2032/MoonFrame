///|
/// A single cell value in a DataFrame.
///
/// `Null` represents a missing value. All `as_*` conversions and comparisons
/// involving `Null` return `Err(TypeMismatch(...))` — callers must check
/// `is_null()` first or accept the error.
pub(all) enum Scalar {
  Int(Int)
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
pub fn Scalar::as_int(self : Scalar) -> Result[Int, DataError] {
  match self {
    Int(v) => Ok(v)
    Null => Err(TypeMismatch("expected Int, got Null"))
    other => Err(TypeMismatch("expected Int, got " + other.dtype().to_string()))
  }
}

///|
pub fn Scalar::as_float(self : Scalar) -> Result[Double, DataError] {
  match self {
    Float(v) => Ok(v)
    Int(v) => Ok(v.to_double())
    Null => Err(TypeMismatch("expected Float, got Null"))
    other =>
      Err(TypeMismatch("expected Float, got " + other.dtype().to_string()))
  }
}

///|
pub fn Scalar::as_bool(self : Scalar) -> Result[Bool, DataError] {
  match self {
    Bool(v) => Ok(v)
    Null => Err(TypeMismatch("expected Bool, got Null"))
    other =>
      Err(TypeMismatch("expected Bool, got " + other.dtype().to_string()))
  }
}

///|
pub fn Scalar::as_string(self : Scalar) -> Result[String, DataError] {
  match self {
    String(v) => Ok(v)
    Null => Err(TypeMismatch("expected String, got Null"))
    other =>
      Err(TypeMismatch("expected String, got " + other.dtype().to_string()))
  }
}

///|
fn type_mismatch_for_compare(
  left : Scalar,
  right : Scalar,
) -> Result[Bool, DataError] {
  Err(
    TypeMismatch(
      "cannot compare " +
      left.dtype().to_string() +
      " and " +
      right.dtype().to_string(),
    ),
  )
}

///|
/// Equality between two `Scalar`s. Two `Null`s, or `Null` and a value,
/// return `Err` — callers must guard nullability explicitly. Mixed numeric
/// types (`Int` vs `Float`) compare via numeric value.
pub fn Scalar::eq(self : Scalar, other : Scalar) -> Result[Bool, DataError] {
  match (self, other) {
    (Null, _) | (_, Null) => Err(TypeMismatch("cannot compare with Null"))
    (Int(a), Int(b)) => Ok(a == b)
    (Float(a), Float(b)) => Ok(a == b)
    (Int(a), Float(b)) => Ok(a.to_double() == b)
    (Float(a), Int(b)) => Ok(a == b.to_double())
    (Bool(a), Bool(b)) => Ok(a == b)
    (String(a), String(b)) => Ok(a == b)
    _ => type_mismatch_for_compare(self, other)
  }
}

///|
pub fn Scalar::lt(self : Scalar, other : Scalar) -> Result[Bool, DataError] {
  match (self, other) {
    (Null, _) | (_, Null) => Err(TypeMismatch("cannot compare with Null"))
    (Int(a), Int(b)) => Ok(a < b)
    (Float(a), Float(b)) => Ok(a < b)
    (Int(a), Float(b)) => Ok(a.to_double() < b)
    (Float(a), Int(b)) => Ok(a < b.to_double())
    (Bool(a), Bool(b)) => Ok((a |> bool_to_int) < (b |> bool_to_int))
    (String(a), String(b)) => Ok(a < b)
    _ => type_mismatch_for_compare(self, other)
  }
}

///|
pub fn Scalar::lte(self : Scalar, other : Scalar) -> Result[Bool, DataError] {
  let eq_res = self.eq(other)
  let lt_res = self.lt(other)
  match (eq_res, lt_res) {
    (Ok(e), Ok(l)) => Ok(e || l)
    (Err(e), _) => Err(e)
    (_, Err(e)) => Err(e)
  }
}

///|
pub fn Scalar::gt(self : Scalar, other : Scalar) -> Result[Bool, DataError] {
  other.lt(self)
}

///|
pub fn Scalar::gte(self : Scalar, other : Scalar) -> Result[Bool, DataError] {
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
/// `Show` renders the variant form (`Int(42)`, `String("ab")`, `Null`).
/// For value-style rendering use `to_string()`.
pub impl Show for Scalar with output(self, logger) {
  match self {
    Int(v) => logger.write_string("Int(" + v.to_string() + ")")
    Float(v) => logger.write_string("Float(" + v.to_string() + ")")
    Bool(v) => logger.write_string("Bool(" + v.to_string() + ")")
    String(v) => logger.write_string("String(\"" + v + "\")")
    Null => logger.write_string("Null")
  }
}
