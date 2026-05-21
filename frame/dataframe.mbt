///|
/// A column-oriented, schema-aware table. `DataFrame` owns an ordered list
/// of equally-tall `Series`, a derived `Schema`, and a private
/// `name_to_index` cache so column lookup by name is `O(1)`.
///
/// The struct is `pub` (fields private outside the package), so callers
/// always go through the constructors below — those rebuild the cache and
/// the schema in lock-step with the column vector, preserving the
/// invariants:
///   * `schema.field_names() == columns.map(.name)`
///   * `columns.all(c => c.len() == nrows)`
///   * `name_to_index[name] == i  ⇔  columns[i].name == name`
pub struct DataFrame {
  schema : @types.Schema
  columns : Array[Series]
  nrows : Int
  name_to_index : Map[String, Int]
} derive(Eq, Debug)

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build a `DataFrame` from a list of `Series`. Validates:
/// - all columns have the same length (`Err(LengthMismatch)` otherwise);
/// - no two columns share a name (`Err(DuplicateColumn(name))`).
///
/// Zero columns is valid and produces a 0×0 frame.
pub fn DataFrame::new(
  columns : Array[Series],
) -> Result[DataFrame, @types.DataError] {
  let nrows = if columns.is_empty() { 0 } else { columns[0].len() }
  for c in columns {
    if c.len() != nrows {
      return Err(@types.DataError::LengthMismatch)
    }
  }
  let fields : Array[@types.Field] = columns.map(fn(c) {
    @types.Field::new(c.name(), c.dtype())
  })
  let schema = match @types.Schema::new(fields) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let name_to_index : Map[String, Int] = {}
  for i, c in columns {
    name_to_index[c.name()] = i
  }
  Ok({ schema, columns, nrows, name_to_index })
}

///|
/// Build a 0-row `DataFrame` matching `schema`. Each column is an empty
/// `Series` of the field's declared dtype.
///
/// Returns `Err(Unsupported(...))` if any field carries `DataType::Null` —
/// v0.1 has no concrete Null backend (and a CSV-inferred Null column has
/// nothing to materialise into).
pub fn DataFrame::empty(
  schema : @types.Schema,
) -> Result[DataFrame, @types.DataError] {
  let columns : Array[Series] = []
  for f in schema.fields() {
    let storage = match f.dtype() {
      @types.DataType::Int => @column.BuiltinColumn::from_ints([])
      @types.DataType::Float => @column.BuiltinColumn::from_floats([])
      @types.DataType::Bool => @column.BuiltinColumn::from_bools([])
      @types.DataType::String => @column.BuiltinColumn::from_strings([])
      @types.DataType::Null =>
        return Err(
          @types.DataError::Unsupported(
            "cannot build empty DataFrame column of dtype Null: " + f.name(),
          ),
        )
    }
    columns.push(Series::from_builtin(f.name(), storage))
  }
  let name_to_index : Map[String, Int] = {}
  for i, c in columns {
    name_to_index[c.name()] = i
  }
  Ok({ schema, columns, nrows: 0, name_to_index })
}

///|
/// Build a `DataFrame` from a row-major matrix of `Scalar`s. Each row
/// must have exactly `schema.len()` cells, and each cell must either
/// match the column's declared dtype or be `Scalar::Null`.
///
/// Errors:
/// - `Err(LengthMismatch)` — a row's width differs from `schema.len()`.
/// - `Err(TypeMismatch(...))` — a non-null cell's dtype doesn't match
///   the schema's dtype for that column.
/// - `Err(Unsupported(...))` — schema declares a `Null`-dtype column
///   (same reason as `empty`).
pub fn DataFrame::from_rows(
  schema : @types.Schema,
  rows : Array[Array[@types.Scalar]],
) -> Result[DataFrame, @types.DataError] {
  let ncols = schema.len()
  for row in rows {
    if row.length() != ncols {
      return Err(@types.DataError::LengthMismatch)
    }
  }
  let nrows = rows.length()
  let columns : Array[Series] = []
  for i in 0..<ncols {
    // `field_at(i)` cannot fail in `[0, ncols)`.
    let field = schema.field_at(i).unwrap()
    let dt = field.dtype()
    let series = match dt {
      @types.DataType::Int => {
        let buf : Array[Int?] = Array::new(capacity=nrows)
        for row in rows {
          match row[i] {
            @types.Scalar::Int(v) => buf.push(Some(v))
            @types.Scalar::Null => buf.push(None)
            other =>
              return Err(
                @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects Int, got " +
                  other.dtype().to_string(),
                ),
              )
          }
        }
        Series::from_int_options(field.name(), buf)
      }
      @types.DataType::Float => {
        let buf : Array[Float?] = Array::new(capacity=nrows)
        for row in rows {
          match row[i] {
            @types.Scalar::Float(v) => buf.push(Some(v))
            @types.Scalar::Null => buf.push(None)
            other =>
              return Err(
                @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects Float, got " +
                  other.dtype().to_string(),
                ),
              )
          }
        }
        Series::from_float_options(field.name(), buf)
      }
      @types.DataType::Bool => {
        let buf : Array[Bool?] = Array::new(capacity=nrows)
        for row in rows {
          match row[i] {
            @types.Scalar::Bool(v) => buf.push(Some(v))
            @types.Scalar::Null => buf.push(None)
            other =>
              return Err(
                @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects Bool, got " +
                  other.dtype().to_string(),
                ),
              )
          }
        }
        Series::from_bool_options(field.name(), buf)
      }
      @types.DataType::String => {
        let buf : Array[String?] = Array::new(capacity=nrows)
        for row in rows {
          match row[i] {
            @types.Scalar::String(v) => buf.push(Some(v))
            @types.Scalar::Null => buf.push(None)
            other =>
              return Err(
                @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects String, got " +
                  other.dtype().to_string(),
                ),
              )
          }
        }
        Series::from_string_options(field.name(), buf)
      }
      @types.DataType::Null =>
        return Err(
          @types.DataError::Unsupported(
            "cannot build DataFrame column of dtype Null: " + field.name(),
          ),
        )
    }
    columns.push(series)
  }
  let name_to_index : Map[String, Int] = {}
  for i, c in columns {
    name_to_index[c.name()] = i
  }
  Ok({ schema, columns, nrows, name_to_index })
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// `(nrows, ncols)`.
pub fn DataFrame::shape(self : DataFrame) -> (Int, Int) {
  (self.nrows, self.columns.length())
}

///|
/// The schema (column names + dtypes + nullability) of this frame.
pub fn DataFrame::schema(self : DataFrame) -> @types.Schema {
  self.schema
}

///|
/// Column names in declaration order. A fresh array is returned so that
/// mutation by the caller cannot break the schema/columns invariants.
pub fn DataFrame::columns(self : DataFrame) -> Array[String] {
  self.columns.map(fn(c) { c.name() })
}

///|
/// Number of rows. Equal to every column's `len()`.
pub fn DataFrame::nrows(self : DataFrame) -> Int {
  self.nrows
}

///|
/// Number of columns.
pub fn DataFrame::ncols(self : DataFrame) -> Int {
  self.columns.length()
}

///|
/// `true` when the frame has zero rows. Note that a frame with zero
/// columns and zero rows is also empty (`nrows == 0`). A 0×N frame
/// (declared schema, no rows yet) is also empty.
pub fn DataFrame::is_empty(self : DataFrame) -> Bool {
  self.nrows == 0
}

// ── Accessors ─────────────────────────────────────────────────────────

///|
/// `O(1)` lookup of the column named `name`. Returns
/// `Err(ColumnNotFound(name))` if the column is missing.
pub fn DataFrame::get_column(
  self : DataFrame,
  name : String,
) -> Result[Series, @types.DataError] {
  match self.name_to_index.get(name) {
    Some(i) => Ok(self.columns[i])
    None => Err(@types.DataError::ColumnNotFound(name))
  }
}

///|
/// Column at position `i`. Out-of-bounds returns
/// `Err(IndexOutOfBounds(i))`.
pub fn DataFrame::get_column_at(
  self : DataFrame,
  i : Int,
) -> Result[Series, @types.DataError] {
  if i < 0 || i >= self.columns.length() {
    return Err(@types.DataError::IndexOutOfBounds(i))
  }
  Ok(self.columns[i])
}

///|
/// Read the cell at `(row, name)` as a `Scalar`. Surfaces
/// `ColumnNotFound` for unknown names and `IndexOutOfBounds` for
/// row indices outside `[0, nrows)`.
pub fn DataFrame::get(
  self : DataFrame,
  row : Int,
  name : String,
) -> Result[@types.Scalar, @types.DataError] {
  match self.get_column(name) {
    Err(e) => Err(e)
    Ok(s) => s.get(row)
  }
}

///|
/// Lightweight view of a single row. The view borrows the underlying
/// frame, so accessors stay `O(1)` and there's no per-row allocation.
/// Row indices outside `[0, nrows)` return `Err(IndexOutOfBounds(i))`.
pub fn DataFrame::row(
  self : DataFrame,
  i : Int,
) -> Result[RowView, @types.DataError] {
  if i < 0 || i >= self.nrows {
    return Err(@types.DataError::IndexOutOfBounds(i))
  }
  Ok({ df: self, row_index: i })
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// First `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails.
pub fn DataFrame::head(self : DataFrame, n : Int) -> DataFrame {
  let m = clamp_take(n, self.nrows)
  let new_cols : Array[Series] = self.columns.map(fn(c) {
    // `slice(0, m)` cannot fail because `0 <= m <= nrows == c.len()`.
    c.slice(0, m).unwrap()
  })
  // Names and schema are unchanged — reuse the cache verbatim.
  {
    schema: self.schema,
    columns: new_cols,
    nrows: m,
    name_to_index: self.name_to_index,
  }
}

///|
/// Last `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails.
pub fn DataFrame::tail(self : DataFrame, n : Int) -> DataFrame {
  let m = clamp_take(n, self.nrows)
  let start = self.nrows - m
  let new_cols : Array[Series] = self.columns.map(fn(c) {
    // `slice(start, nrows)` cannot fail by the same argument as `head`.
    c.slice(start, self.nrows).unwrap()
  })
  {
    schema: self.schema,
    columns: new_cols,
    nrows: m,
    name_to_index: self.name_to_index,
  }
}

///|
/// Half-open `[start, end)` row slice. Bounds checks mirror
/// `Series::slice` (and `BuiltinColumn::slice`): out-of-range starts /
/// ends surface as `IndexOutOfBounds`, `start > end` as
/// `InvalidOperation`.
pub fn DataFrame::slice(
  self : DataFrame,
  start : Int,
  end : Int,
) -> Result[DataFrame, @types.DataError] {
  // Validate bounds once using the first column (or against `nrows` if
  // there are no columns).
  if start < 0 {
    return Err(@types.DataError::IndexOutOfBounds(start))
  }
  if end > self.nrows {
    return Err(@types.DataError::IndexOutOfBounds(end))
  }
  if start > end {
    return Err(
      @types.DataError::InvalidOperation(
        "slice start > end: " + start.to_string() + " > " + end.to_string(),
      ),
    )
  }
  let new_cols : Array[Series] = self.columns.map(fn(c) {
    // Bounds were already validated against `self.nrows`, which equals
    // every column's length.
    c.slice(start, end).unwrap()
  })
  Ok({
    schema: self.schema,
    columns: new_cols,
    nrows: end - start,
    name_to_index: self.name_to_index,
  })
}

///|
/// Gather rows by index. Returns a frame whose i-th row is
/// `self[indices[i]]`. Any out-of-bounds index surfaces as
/// `IndexOutOfBounds(idx)`.
pub fn DataFrame::take(
  self : DataFrame,
  indices : Array[Int],
) -> Result[DataFrame, @types.DataError] {
  for i in indices {
    if i < 0 || i >= self.nrows {
      return Err(@types.DataError::IndexOutOfBounds(i))
    }
  }
  let new_cols : Array[Series] = []
  for c in self.columns {
    // Indices were just validated against `self.nrows`; per-column
    // `take` cannot fail.
    new_cols.push(c.take(indices).unwrap())
  }
  Ok({
    schema: self.schema,
    columns: new_cols,
    nrows: indices.length(),
    name_to_index: self.name_to_index,
  })
}

// ── Internal helpers ──────────────────────────────────────────────────

///|
/// Clamp a head/tail `n` request into `[0, len]`.
fn clamp_take(n : Int, len : Int) -> Int {
  if n < 0 {
    0
  } else if n > len {
    len
  } else {
    n
  }
}
