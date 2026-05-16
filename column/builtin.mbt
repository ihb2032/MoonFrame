///|
/// Single-backend columnar storage used by `Series` in v0.1.
///
/// Each variant wraps `Array[Option[T]]` directly — `None` denotes a null
/// cell. v0.2 will introduce a `ColumnStorage` abstraction over this enum
/// (and a `NumericColumn` variant) without changing this layer's API.
pub(all) enum BuiltinColumn {
  Int(Array[Int?])
  Float(Array[Double?])
  Bool(Array[Bool?])
  String(Array[String?])
} derive(Eq, Debug)

// ── Constructors ───────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values (no nulls).
pub fn BuiltinColumn::from_ints(values : Array[Int]) -> BuiltinColumn {
  Int(values.map(fn(v) { Some(v) }))
}

///|
/// Build an `Int` column where `None` entries are nulls.
pub fn BuiltinColumn::from_int_options(values : Array[Int?]) -> BuiltinColumn {
  Int(values)
}

///|
/// Build a `Float` column from raw values (no nulls).
pub fn BuiltinColumn::from_floats(values : Array[Double]) -> BuiltinColumn {
  Float(values.map(fn(v) { Some(v) }))
}

///|
/// Build a `Float` column where `None` entries are nulls.
pub fn BuiltinColumn::from_float_options(
  values : Array[Double?],
) -> BuiltinColumn {
  Float(values)
}

///|
/// Build a `Bool` column from raw values (no nulls).
pub fn BuiltinColumn::from_bools(values : Array[Bool]) -> BuiltinColumn {
  Bool(values.map(fn(v) { Some(v) }))
}

///|
/// Build a `Bool` column where `None` entries are nulls.
pub fn BuiltinColumn::from_bool_options(values : Array[Bool?]) -> BuiltinColumn {
  Bool(values)
}

///|
/// Build a `String` column from raw values (no nulls).
pub fn BuiltinColumn::from_strings(values : Array[String]) -> BuiltinColumn {
  String(values.map(fn(v) { Some(v) }))
}

///|
/// Build a `String` column where `None` entries are nulls.
pub fn BuiltinColumn::from_string_options(
  values : Array[String?],
) -> BuiltinColumn {
  String(values)
}

// ── Inspection ────────────────────────────────────────────────────────

///|
pub fn BuiltinColumn::dtype(self : BuiltinColumn) -> @types.DataType {
  match self {
    Int(_) => @types.DataType::Int
    Float(_) => @types.DataType::Float
    Bool(_) => @types.DataType::Bool
    String(_) => @types.DataType::String
  }
}

///|
pub fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  match self {
    Int(a) => a.length()
    Float(a) => a.length()
    Bool(a) => a.length()
    String(a) => a.length()
  }
}

///|
pub fn BuiltinColumn::is_empty(self : BuiltinColumn) -> Bool {
  self.len() == 0
}

///|
pub fn BuiltinColumn::null_count(self : BuiltinColumn) -> Int {
  let mut count = 0
  match self {
    Int(a) =>
      for v in a {
        if v is None {
          count = count + 1
        }
      }
    Float(a) =>
      for v in a {
        if v is None {
          count = count + 1
        }
      }
    Bool(a) =>
      for v in a {
        if v is None {
          count = count + 1
        }
      }
    String(a) =>
      for v in a {
        if v is None {
          count = count + 1
        }
      }
  }
  count
}

///|
/// `Err(IndexOutOfBounds)` if `index` is outside `[0, len)`.
pub fn BuiltinColumn::is_null(
  self : BuiltinColumn,
  index : Int,
) -> Result[Bool, @types.DataError] {
  if index < 0 || index >= self.len() {
    return Err(@types.DataError::IndexOutOfBounds(index))
  }
  let res = match self {
    Int(a) => a[index] is None
    Float(a) => a[index] is None
    Bool(a) => a[index] is None
    String(a) => a[index] is None
  }
  Ok(res)
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index returns
/// `Err(IndexOutOfBounds)`.
pub fn BuiltinColumn::get(
  self : BuiltinColumn,
  index : Int,
) -> Result[@types.Scalar, @types.DataError] {
  if index < 0 || index >= self.len() {
    return Err(@types.DataError::IndexOutOfBounds(index))
  }
  let s = match self {
    Int(a) =>
      match a[index] {
        Some(v) => @types.Scalar::Int(v)
        None => @types.Scalar::Null
      }
    Float(a) =>
      match a[index] {
        Some(v) => @types.Scalar::Float(v)
        None => @types.Scalar::Null
      }
    Bool(a) =>
      match a[index] {
        Some(v) => @types.Scalar::Bool(v)
        None => @types.Scalar::Null
      }
    String(a) =>
      match a[index] {
        Some(v) => @types.Scalar::String(v)
        None => @types.Scalar::Null
      }
  }
  Ok(s)
}

// ── Sub-views ─────────────────────────────────────────────────────────

///|
/// Half-open `[start, end)` slice. Requires `0 <= start <= end <= len`.
pub fn BuiltinColumn::slice(
  self : BuiltinColumn,
  start : Int,
  end : Int,
) -> Result[BuiltinColumn, @types.DataError] {
  let len = self.len()
  if start < 0 || start > end || end > len {
    return Err(@types.DataError::IndexOutOfBounds(start))
  }
  let out : BuiltinColumn = match self {
    Int(a) => {
      let buf : Array[Int?] = Array::new(capacity=end - start)
      for i in start..<end {
        buf.push(a[i])
      }
      Int(buf)
    }
    Float(a) => {
      let buf : Array[Double?] = Array::new(capacity=end - start)
      for i in start..<end {
        buf.push(a[i])
      }
      Float(buf)
    }
    Bool(a) => {
      let buf : Array[Bool?] = Array::new(capacity=end - start)
      for i in start..<end {
        buf.push(a[i])
      }
      Bool(buf)
    }
    String(a) => {
      let buf : Array[String?] = Array::new(capacity=end - start)
      for i in start..<end {
        buf.push(a[i])
      }
      String(buf)
    }
  }
  Ok(out)
}

///|
/// Gather: produce a new column whose i-th entry is `self[indices[i]]`.
/// Any out-of-bounds index returns `Err(IndexOutOfBounds(idx))`.
pub fn BuiltinColumn::take(
  self : BuiltinColumn,
  indices : Array[Int],
) -> Result[BuiltinColumn, @types.DataError] {
  let len = self.len()
  for i in indices {
    if i < 0 || i >= len {
      return Err(@types.DataError::IndexOutOfBounds(i))
    }
  }
  let n = indices.length()
  let out : BuiltinColumn = match self {
    Int(a) => {
      let buf : Array[Int?] = Array::new(capacity=n)
      for i in indices {
        buf.push(a[i])
      }
      Int(buf)
    }
    Float(a) => {
      let buf : Array[Double?] = Array::new(capacity=n)
      for i in indices {
        buf.push(a[i])
      }
      Float(buf)
    }
    Bool(a) => {
      let buf : Array[Bool?] = Array::new(capacity=n)
      for i in indices {
        buf.push(a[i])
      }
      Bool(buf)
    }
    String(a) => {
      let buf : Array[String?] = Array::new(capacity=n)
      for i in indices {
        buf.push(a[i])
      }
      String(buf)
    }
  }
  Ok(out)
}

// ── Cast ──────────────────────────────────────────────────────────────

///|
/// Dispatch a cast by target dtype. `Bool` and `Null` targets are not
/// supported in v0.1 — see `to_int` / `to_float` / `to_string_column`
/// for the supported targets.
pub fn BuiltinColumn::cast(
  self : BuiltinColumn,
  target : @types.DataType,
) -> Result[BuiltinColumn, @types.DataError] {
  match target {
    Int => self.to_int()
    Float => self.to_float()
    String => self.to_string_column()
    Bool => Err(@types.DataError::Unsupported("cast to Bool"))
    Null => Err(@types.DataError::Unsupported("cast to Null"))
  }
}

///|
/// Convert to `Int`. Supported sources: `Int` (identity), `Float`
/// (truncated towards zero), `Bool` (`true` → 1, `false` → 0),
/// `String` (parsed; non-numeric values return `ParseError`).
pub fn BuiltinColumn::to_int(
  self : BuiltinColumn,
) -> Result[BuiltinColumn, @types.DataError] {
  match self {
    Int(_) => Ok(self)
    Float(a) => {
      let buf : Array[Int?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(x) => buf.push(Some(x.to_int()))
          None => buf.push(None)
        }
      }
      Ok(Int(buf))
    }
    Bool(a) => {
      let buf : Array[Int?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(true) => buf.push(Some(1))
          Some(false) => buf.push(Some(0))
          None => buf.push(None)
        }
      }
      Ok(Int(buf))
    }
    String(a) => {
      let buf : Array[Int?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          None => buf.push(None)
          Some(s) => {
            let parsed = try? @string.parse_int(s.view())
            match parsed {
              Ok(n) => buf.push(Some(n))
              Err(_) =>
                return Err(
                  @types.DataError::ParseError(
                    "cannot parse Int from \"" + s + "\"",
                  ),
                )
            }
          }
        }
      }
      Ok(Int(buf))
    }
  }
}

///|
/// Convert to `Float`. Supported sources: `Int` (promoted), `Float`
/// (identity), `Bool` (`true` → 1.0, `false` → 0.0), `String` (parsed;
/// non-numeric values return `ParseError`).
pub fn BuiltinColumn::to_float(
  self : BuiltinColumn,
) -> Result[BuiltinColumn, @types.DataError] {
  match self {
    Float(_) => Ok(self)
    Int(a) => {
      let buf : Array[Double?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(x) => buf.push(Some(x.to_double()))
          None => buf.push(None)
        }
      }
      Ok(Float(buf))
    }
    Bool(a) => {
      let buf : Array[Double?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(true) => buf.push(Some(1.0))
          Some(false) => buf.push(Some(0.0))
          None => buf.push(None)
        }
      }
      Ok(Float(buf))
    }
    String(a) => {
      let buf : Array[Double?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          None => buf.push(None)
          Some(s) => {
            let parsed = try? @string.parse_double(s.view())
            match parsed {
              Ok(x) => buf.push(Some(x))
              Err(_) =>
                return Err(
                  @types.DataError::ParseError(
                    "cannot parse Float from \"" + s + "\"",
                  ),
                )
            }
          }
        }
      }
      Ok(Float(buf))
    }
  }
}

///|
/// Convert to `String`. Each cell is rendered with the same value-form
/// used by `Scalar::to_string` (e.g. `Int(42)` → `"42"`, `Bool(true)` →
/// `"true"`). Nulls remain `None`.
pub fn BuiltinColumn::to_string_column(
  self : BuiltinColumn,
) -> Result[BuiltinColumn, @types.DataError] {
  match self {
    String(_) => Ok(self)
    Int(a) => {
      let buf : Array[String?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(x) => buf.push(Some(x.to_string()))
          None => buf.push(None)
        }
      }
      Ok(String(buf))
    }
    Float(a) => {
      let buf : Array[String?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(x) => buf.push(Some(x.to_string()))
          None => buf.push(None)
        }
      }
      Ok(String(buf))
    }
    Bool(a) => {
      let buf : Array[String?] = Array::new(capacity=a.length())
      for v in a {
        match v {
          Some(true) => buf.push(Some("true"))
          Some(false) => buf.push(Some("false"))
          None => buf.push(None)
        }
      }
      Ok(String(buf))
    }
  }
}

// ── Typed accessors (zero-boxing fast path for ops) ──────────────────

///|
/// Borrow the underlying `Array[Option[Int]]`. Returns `Err(TypeMismatch)`
/// when the column is not an `Int` column.
pub fn BuiltinColumn::int_values(
  self : BuiltinColumn,
) -> Result[Array[Int?], @types.DataError] {
  match self {
    Int(a) => Ok(a)
    other =>
      Err(
        @types.DataError::TypeMismatch(
          "expected Int column, got " + other.dtype().to_string(),
        ),
      )
  }
}

///|
/// Borrow the underlying `Array[Option[Double]]`. Returns
/// `Err(TypeMismatch)` when the column is not a `Float` column.
pub fn BuiltinColumn::float_values(
  self : BuiltinColumn,
) -> Result[Array[Double?], @types.DataError] {
  match self {
    Float(a) => Ok(a)
    other =>
      Err(
        @types.DataError::TypeMismatch(
          "expected Float column, got " + other.dtype().to_string(),
        ),
      )
  }
}

///|
/// Borrow the underlying `Array[Option[Bool]]`. Returns `Err(TypeMismatch)`
/// when the column is not a `Bool` column.
pub fn BuiltinColumn::bool_values(
  self : BuiltinColumn,
) -> Result[Array[Bool?], @types.DataError] {
  match self {
    Bool(a) => Ok(a)
    other =>
      Err(
        @types.DataError::TypeMismatch(
          "expected Bool column, got " + other.dtype().to_string(),
        ),
      )
  }
}

///|
/// Borrow the underlying `Array[Option[String]]`. Returns
/// `Err(TypeMismatch)` when the column is not a `String` column.
pub fn BuiltinColumn::string_values(
  self : BuiltinColumn,
) -> Result[Array[String?], @types.DataError] {
  match self {
    String(a) => Ok(a)
    other =>
      Err(
        @types.DataError::TypeMismatch(
          "expected String column, got " + other.dtype().to_string(),
        ),
      )
  }
}
