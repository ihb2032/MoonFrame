///|
/// Apache Arrow style columnar storage used by `Series` in v0.1.
///
/// The column splits values from validity. `data` is a typed array of raw
/// values (no `Option` boxing); `validity` is a bit-packed `Bitmap` where
/// `1 = valid, 0 = null`, matching Arrow's binary layout. Null slots in
/// `data` carry a per-dtype placeholder (`Int = 0`, `Float = 0.0`,
/// `Bool = false`, `String = ""`); public methods always consult
/// `validity` before reading `data`, so the placeholder never leaks.
///
/// v0.2 will introduce a `ColumnStorage` abstraction (plus a
/// `NumericColumn` for unboxed-numeric fast paths) without changing this
/// layer's public API.
///
/// Numeric columns are 64-bit: the `Int` variant stores `Int64` and the
/// `Float` variant stores `Double`, matching `Scalar`'s payloads and the
/// pandas / polars `int64` / `float64` defaults so reductions neither
/// silently overflow nor lose precision.
pub struct BuiltinColumn {
  data : ColumnData
  validity : Bitmap
} derive(Eq, Debug)

///|
/// Backing storage discriminated by dtype. The element type is the raw
/// value; nullability is tracked in the enclosing column's `validity`
/// bitmap.
pub(all) enum ColumnData {
  Int(Array[Int64])
  Float(Array[Double])
  Bool(Array[Bool])
  String(Array[String])
} derive(Eq, Debug)

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values (no nulls).
pub fn BuiltinColumn::from_ints(values : Array[Int64]) -> BuiltinColumn {
  { data: Int(values), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build an `Int` column where `None` entries are nulls. `None` slots
/// receive `0` as the data placeholder; public APIs never expose it.
pub fn BuiltinColumn::from_int_options(values : Array[Int64?]) -> BuiltinColumn {
  {
    data: Int(values.map(v => v.unwrap_or(0))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `Float` column from raw values (no nulls).
pub fn BuiltinColumn::from_floats(values : Array[Double]) -> BuiltinColumn {
  { data: Float(values), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build a `Float` column where `None` entries are nulls. `None` slots
/// receive `0.0` as the data placeholder.
pub fn BuiltinColumn::from_float_options(
  values : Array[Double?],
) -> BuiltinColumn {
  {
    data: Float(values.map(v => v.unwrap_or(0.0))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `Bool` column from raw values (no nulls).
pub fn BuiltinColumn::from_bools(values : Array[Bool]) -> BuiltinColumn {
  { data: Bool(values), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build a `Bool` column where `None` entries are nulls. `None` slots
/// receive `false` as the data placeholder.
pub fn BuiltinColumn::from_bool_options(values : Array[Bool?]) -> BuiltinColumn {
  {
    data: Bool(values.map(v => v.unwrap_or(false))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `String` column from raw values (no nulls).
pub fn BuiltinColumn::from_strings(values : Array[String]) -> BuiltinColumn {
  { data: String(values), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build a `String` column where `None` entries are nulls. `None` slots
/// receive `""` as the data placeholder.
pub fn BuiltinColumn::from_string_options(
  values : Array[String?],
) -> BuiltinColumn {
  {
    data: String(values.map(v => v.unwrap_or(""))),
    validity: Bitmap::from_options(values),
  }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
pub fn BuiltinColumn::dtype(self : BuiltinColumn) -> @types.DataType {
  match self.data {
    Int(_) => @types.DataType::Int
    Float(_) => @types.DataType::Float
    Bool(_) => @types.DataType::Bool
    String(_) => @types.DataType::String
  }
}

///|
pub fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  match self.data {
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
  self.validity.null_count()
}

///|
/// `Err(IndexOutOfBounds)` if `index` is outside `[0, len)`.
pub fn BuiltinColumn::is_null(
  self : BuiltinColumn,
  index : Int,
) -> Result[Bool, @types.DataError] {
  self.validity.is_null(index)
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index returns
/// `Err(IndexOutOfBounds)`.
pub fn BuiltinColumn::get(
  self : BuiltinColumn,
  index : Int,
) -> Result[@types.Scalar, @types.DataError] {
  match self.validity.is_null(index) {
    Err(e) => Err(e)
    Ok(true) => Ok(@types.Scalar::Null)
    Ok(false) => {
      let s = match self.data {
        Int(a) => @types.Scalar::Int(a[index])
        Float(a) => @types.Scalar::Float(a[index])
        Bool(a) => @types.Scalar::Bool(a[index])
        String(a) => @types.Scalar::String(a[index])
      }
      Ok(s)
    }
  }
}

// ── Sub-views ─────────────────────────────────────────────────────────

///|
/// Half-open `[start, end)` slice. Requires `0 <= start <= end <= len`.
///
/// Errors (checked in this order):
/// - `IndexOutOfBounds(start)` when `start < 0`.
/// - `IndexOutOfBounds(end)` when `end > len`.
/// - `InvalidOperation("slice start > end: ...")` when `start > end`.
///
/// `start > len` is not a separate case: it can only occur together with
/// `end > len` (→ `IndexOutOfBounds(end)`) or `start > end`
/// (→ `InvalidOperation`), both already rejected above.
pub fn BuiltinColumn::slice(
  self : BuiltinColumn,
  start : Int,
  end : Int,
) -> Result[BuiltinColumn, @types.DataError] {
  let len = self.len()
  if start < 0 {
    return Err(@types.DataError::IndexOutOfBounds(start))
  }
  if end > len {
    return Err(@types.DataError::IndexOutOfBounds(end))
  }
  if start > end {
    return Err(
      @types.DataError::InvalidOperation(
        "slice start > end: " + start.to_string() + " > " + end.to_string(),
      ),
    )
  }
  let n = end - start
  let data_out : ColumnData = match self.data {
    Int(a) => Int(Array::makei(n, i => a[start + i]))
    Float(a) => Float(Array::makei(n, i => a[start + i]))
    Bool(a) => Bool(Array::makei(n, i => a[start + i]))
    String(a) => String(Array::makei(n, i => a[start + i]))
  }
  // `validity.slice` repeats the same bounds checks against the same logical
  // length, so it cannot fail here.
  let validity_out = self.validity.slice(start, n).unwrap()
  Ok({ data: data_out, validity: validity_out })
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
  let data_out : ColumnData = match self.data {
    Int(a) => Int(indices.map(i => a[i]))
    Float(a) => Float(indices.map(i => a[i]))
    Bool(a) => Bool(indices.map(i => a[i]))
    String(a) => String(indices.map(i => a[i]))
  }
  // Same indices were already validated against the same `len`; the validity
  // gather cannot fail.
  let validity_out = self.validity.take(indices).unwrap()
  Ok({ data: data_out, validity: validity_out })
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
/// Convert to `Int`. Validity is preserved verbatim. Supported sources:
/// - `Int`: identity, no copy.
/// - `Float`: truncated towards zero. `NaN`, `+Inf`, `-Inf`, and values
///   outside the `Int64` range are rejected with `ParseError` — the
///   underlying `Double::to_int64` is implementation-defined on those
///   inputs, so the cast layer guards against them explicitly. Null
///   slots skip the conversion entirely.
/// - `Bool`: `true` → 1, `false` → 0.
/// - `String`: only plain base-10 integers are accepted — an optional
///   `+` / `-` sign followed by ASCII digits. Any other form on a valid
///   (non-null) slot returns `ParseError`, mirroring the CSV reader's
///   inference: `0x` / `0o` / `0b` base prefixes and `1_000` underscore
///   grouping are rejected (pandas / polars keep them as strings), as are
///   leading/trailing whitespace, non-numeric suffixes, empty strings,
///   and decimal integers that overflow 64-bit `Int64`.
pub fn BuiltinColumn::to_int(
  self : BuiltinColumn,
) -> Result[BuiltinColumn, @types.DataError] {
  match self.data {
    Int(_) => Ok(self)
    Float(a) => {
      let buf : Array[Int64] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          let x = a[i]
          if x.is_nan() {
            return Err(@types.DataError::ParseError("cannot cast NaN to Int"))
          } else if x.is_inf() {
            return Err(
              @types.DataError::ParseError("cannot cast Infinity to Int"),
            )
          } else if x < min_int_as_double || x > max_int_as_double {
            return Err(
              @types.DataError::ParseError(
                "Float value out of Int range: " + x.to_string(),
              ),
            )
          } else {
            buf.push(x.to_int64())
          }
        } else {
          buf.push(0)
        }
      }
      Ok({ data: Int(buf), validity: self.validity })
    }
    Bool(a) => {
      let buf : Array[Int64] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          buf.push(if a[i] { 1 } else { 0 })
        } else {
          buf.push(0)
        }
      }
      Ok({ data: Int(buf), validity: self.validity })
    }
    String(a) => {
      let buf : Array[Int64] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          let s = a[i]
          // Only plain base-10 integers are accepted, matching the CSV
          // reader's inference — both route through
          // `@types.is_decimal_int_literal`. `@string.parse_int` defaults
          // to base=0, which would otherwise accept `0x` / `0o` / `0b`
          // prefixes and `1_000` underscore grouping (forms pandas /
          // polars keep as strings); screening first keeps an explicit
          // `to_int` cast consistent with what the reader inferred for the
          // same text.
          if !@types.is_decimal_int_literal(s) {
            return Err(
              @types.DataError::ParseError(
                "cannot parse Int from \"" + s + "\"",
              ),
            )
          }
          let parsed = try? @string.parse_int64(s.view())
          match parsed {
            Ok(n) => buf.push(n)
            Err(_) =>
              return Err(
                @types.DataError::ParseError(
                  "cannot parse Int from \"" + s + "\"",
                ),
              )
          }
        } else {
          buf.push(0)
        }
      }
      Ok({ data: Int(buf), validity: self.validity })
    }
  }
}

///|
/// `Int64::MIN` / `Int64::MAX` projected into `Double` space, used to
/// reject out-of-range `Float`→`Int` casts before `Double::to_int64`
/// (which is implementation-defined outside the representable range).
///
/// `Int64::MIN = -2^63` is exactly representable as a `Double`;
/// `Int64::MAX = 2^63 - 1` is not — the largest `Double` strictly below
/// `2^63` is `9223372036854774784` (`2^63 - 1024`). Anything above it
/// rounds to a `Double` ≥ `2^63` and would overflow `Int64`.
let min_int_as_double : Double = -9223372036854775808.0

///|
let max_int_as_double : Double = 9223372036854774784.0

///|
/// Convert to `Float`. Validity is preserved verbatim. Supported sources:
/// - `Float`: identity, no copy.
/// - `Int`: promoted via `Int64::to_double` (a `Double` has 52 bits of
///   significand, so `Int64`s with magnitude > 2^53 lose precision — this
///   is inherent to the target type and not flagged as an error).
/// - `Bool`: `true` → 1.0, `false` → 0.0.
/// - `String`: parsed via `@string.parse_double`. `1_000`-style underscore
///   grouping is rejected to match the CSV reader (pandas / polars keep
///   such cells as strings); the `inf` / `-inf` / `nan` literals are still
///   accepted. Other malformed strings on valid slots return `ParseError`;
///   finite values beyond the `Double` range collapse to `±Infinity` per
///   IEEE 754.
pub fn BuiltinColumn::to_float(
  self : BuiltinColumn,
) -> Result[BuiltinColumn, @types.DataError] {
  match self.data {
    Float(_) => Ok(self)
    Int(a) => {
      let buf : Array[Double] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          buf.push(a[i].to_double())
        } else {
          buf.push(0.0)
        }
      }
      Ok({ data: Float(buf), validity: self.validity })
    }
    Bool(a) => {
      let buf : Array[Double] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          buf.push(if a[i] { 1.0 } else { 0.0 })
        } else {
          buf.push(0.0)
        }
      }
      Ok({ data: Float(buf), validity: self.validity })
    }
    String(a) => {
      let buf : Array[Double] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          let s = a[i]
          // Reject `1_000`-style underscore grouping to match the CSV
          // reader (`parse_float_opt` in `io/csv.mbt`):
          // `@string.parse_double` accepts underscores, but pandas /
          // polars keep such cells as strings. The `inf` / `-inf` / `nan`
          // literals stay accepted.
          if s.iter().any(c => c == '_') {
            return Err(
              @types.DataError::ParseError(
                "cannot parse Float from \"" + s + "\"",
              ),
            )
          }
          let parsed = try? @string.parse_double(s.view())
          match parsed {
            Ok(x) => buf.push(x)
            Err(_) =>
              return Err(
                @types.DataError::ParseError(
                  "cannot parse Float from \"" + s + "\"",
                ),
              )
          }
        } else {
          buf.push(0.0)
        }
      }
      Ok({ data: Float(buf), validity: self.validity })
    }
  }
}

///|
/// Convert to `String`. Each valid cell is rendered with the same
/// value-form used by `Scalar::to_string` (e.g. `Int(42)` → `"42"`,
/// `Bool(true)` → `"true"`). Null slots get an empty placeholder and
/// remain null in the validity bitmap.
pub fn BuiltinColumn::to_string_column(
  self : BuiltinColumn,
) -> Result[BuiltinColumn, @types.DataError] {
  match self.data {
    String(_) => Ok(self)
    Int(a) => {
      let buf : Array[String] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          buf.push(a[i].to_string())
        } else {
          buf.push("")
        }
      }
      Ok({ data: String(buf), validity: self.validity })
    }
    Float(a) => {
      let buf : Array[String] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          buf.push(a[i].to_string())
        } else {
          buf.push("")
        }
      }
      Ok({ data: String(buf), validity: self.validity })
    }
    Bool(a) => {
      let buf : Array[String] = Array::new(capacity=a.length())
      for i in 0..<a.length() {
        if self.validity.is_valid(i).unwrap() {
          buf.push(if a[i] { "true" } else { "false" })
        } else {
          buf.push("")
        }
      }
      Ok({ data: String(buf), validity: self.validity })
    }
  }
}

// ── Typed accessors (zero-boxing fast path for ops) ──────────────────

///|
/// Return the underlying raw data array and validity bitmap (no `Option`
/// boxing). Data at null slots is a placeholder — always consult
/// `validity` before reading. Returns `Err(TypeMismatch)` when the
/// column is not an `Int` column.
pub fn BuiltinColumn::int_values(
  self : BuiltinColumn,
) -> Result[(Array[Int64], Bitmap), @types.DataError] {
  match self.data {
    Int(a) => Ok((a, self.validity))
    _ =>
      Err(
        @types.DataError::TypeMismatch(
          "expected Int column, got " + self.dtype().to_string(),
        ),
      )
  }
}

///|
/// Like `int_values` but for `Float` columns.
pub fn BuiltinColumn::float_values(
  self : BuiltinColumn,
) -> Result[(Array[Double], Bitmap), @types.DataError] {
  match self.data {
    Float(a) => Ok((a, self.validity))
    _ =>
      Err(
        @types.DataError::TypeMismatch(
          "expected Float column, got " + self.dtype().to_string(),
        ),
      )
  }
}

///|
/// Like `int_values` but for `Bool` columns.
pub fn BuiltinColumn::bool_values(
  self : BuiltinColumn,
) -> Result[(Array[Bool], Bitmap), @types.DataError] {
  match self.data {
    Bool(a) => Ok((a, self.validity))
    _ =>
      Err(
        @types.DataError::TypeMismatch(
          "expected Bool column, got " + self.dtype().to_string(),
        ),
      )
  }
}

///|
/// Like `int_values` but for `String` columns.
pub fn BuiltinColumn::string_values(
  self : BuiltinColumn,
) -> Result[(Array[String], Bitmap), @types.DataError] {
  match self.data {
    String(a) => Ok((a, self.validity))
    _ =>
      Err(
        @types.DataError::TypeMismatch(
          "expected String column, got " + self.dtype().to_string(),
        ),
      )
  }
}
