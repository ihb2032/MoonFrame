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
) -> DataFrame raise @types.DataError {
  let nrows = if columns.is_empty() { 0 } else { columns[0].len() }
  for c in columns {
    if c.len() != nrows {
      raise @types.DataError::LengthMismatch
    }
  }
  let fields : Array[@types.Field] = columns.map(fn(c) {
    @types.Field::new(c.name(), c.dtype())
  })
  let schema = @types.Schema::new(fields)
  { schema, columns, nrows, name_to_index: index_by_name(columns) }
}

///|
/// Build the name→index lookup cache from a column vector: position `i` maps
/// from `columns[i].name()`. A later duplicate name would overwrite an
/// earlier index, but every constructor routes through `Schema::new`, which
/// rejects duplicate names before this runs — so the cache is 1:1 with the
/// columns. Shared by `new`, `empty`, and `from_rows`.
fn index_by_name(columns : Array[Series]) -> Map[String, Int] {
  let name_to_index : Map[String, Int] = {}
  for i, c in columns {
    name_to_index[c.name()] = i
  }
  name_to_index
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
) -> DataFrame raise @types.DataError {
  let columns : Array[Series] = schema
    .fields()
    .map(f => {
      let storage = match f.dtype() {
        @types.DataType::Int => @column.BuiltinColumn::from_ints([])
        @types.DataType::Float => @column.BuiltinColumn::from_floats([])
        @types.DataType::Bool => @column.BuiltinColumn::from_bools([])
        @types.DataType::String => @column.BuiltinColumn::from_strings([])
        @types.DataType::Null =>
          raise @types.DataError::Unsupported(
            "cannot build empty DataFrame column of dtype Null: " + f.name(),
          )
      }
      Series::from_builtin(f.name(), storage)
    })
  { schema, columns, nrows: 0, name_to_index: index_by_name(columns) }
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
) -> DataFrame raise @types.DataError {
  let ncols = schema.len()
  for row in rows {
    if row.length() != ncols {
      raise @types.DataError::LengthMismatch
    }
  }
  // A schema with zero columns cannot anchor a positive row count: every
  // row had to be width-0 to pass the check above, and `DataFrame::new`'s
  // convention is that a column-less frame is row-less (`0×0`). Normalise
  // `nrows` to 0 there so `from_rows` agrees with `new` / `empty` and the
  // result satisfies INV7 in `check_invariants`.
  let nrows = if ncols == 0 { 0 } else { rows.length() }
  // `fields()` materialises all fields; indexing `[0, ncols)` is in-bounds
  // (`fields.length() == schema.len() == ncols`).
  let fields = schema.fields()
  let columns : Array[Series] = Array::makei(ncols, i => {
    let field = fields[i]
    match field.dtype() {
      @types.DataType::Int =>
        Series::from_int_options(
          field.name(),
          rows.map(row => {
            match row[i] {
              @types.Scalar::Int(v) => Some(v)
              @types.Scalar::Null => None
              other =>
                raise @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects Int, got " +
                  other.dtype().to_string(),
                )
            }
          }),
        )
      @types.DataType::Float =>
        Series::from_float_options(
          field.name(),
          rows.map(row => {
            match row[i] {
              @types.Scalar::Float(v) => Some(v)
              @types.Scalar::Null => None
              other =>
                raise @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects Float, got " +
                  other.dtype().to_string(),
                )
            }
          }),
        )
      @types.DataType::Bool =>
        Series::from_bool_options(
          field.name(),
          rows.map(row => {
            match row[i] {
              @types.Scalar::Bool(v) => Some(v)
              @types.Scalar::Null => None
              other =>
                raise @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects Bool, got " +
                  other.dtype().to_string(),
                )
            }
          }),
        )
      @types.DataType::String =>
        Series::from_string_options(
          field.name(),
          rows.map(row => {
            match row[i] {
              @types.Scalar::String(v) => Some(v)
              @types.Scalar::Null => None
              other =>
                raise @types.DataError::TypeMismatch(
                  "column \"" +
                  field.name() +
                  "\" expects String, got " +
                  other.dtype().to_string(),
                )
            }
          }),
        )
      @types.DataType::Null =>
        raise @types.DataError::Unsupported(
          "cannot build DataFrame column of dtype Null: " + field.name(),
        )
    }
  })
  { schema, columns, nrows, name_to_index: index_by_name(columns) }
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
/// The columns as `Series`, in declaration order. A fresh array is
/// returned (the `Series` themselves are immutable, storage shared), so
/// ops / IO layers can iterate columns directly instead of repeatedly
/// looking each up by name; mutating the returned array can't perturb the
/// frame's invariants.
pub fn DataFrame::column_series(self : DataFrame) -> Array[Series] {
  self.columns.copy()
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
) -> Series raise @types.DataError {
  match self.name_to_index.get(name) {
    Some(i) => self.columns[i]
    None => raise @types.DataError::ColumnNotFound(name)
  }
}

///|
/// Column at position `i`. Out-of-bounds returns
/// `Err(IndexOutOfBounds(i))`.
pub fn DataFrame::get_column_at(
  self : DataFrame,
  i : Int,
) -> Series raise @types.DataError {
  if i < 0 || i >= self.columns.length() {
    raise @types.DataError::IndexOutOfBounds(i)
  }
  self.columns[i]
}

///|
/// Read the cell at `(row, name)` as a `Scalar`. Surfaces
/// `ColumnNotFound` for unknown names and `IndexOutOfBounds` for
/// row indices outside `[0, nrows)`.
pub fn DataFrame::get(
  self : DataFrame,
  row : Int,
  name : String,
) -> @types.Scalar raise @types.DataError {
  self.get_column(name).get(row)
}

///|
/// Borrow row `i` without bounds-checking the index. This is total — it
/// never aborts — because every `RowView` accessor re-validates the row
/// index and returns `Err(IndexOutOfBounds)` for an out-of-range view. It
/// is the companion to `row` for call sites (like `filter`) that already
/// iterate `[0, nrows)` and so don't need the eager check.
pub fn DataFrame::row_view(self : DataFrame, i : Int) -> RowView {
  { df: self, row_index: i }
}

///|
/// Lightweight view of a single row. The view borrows the underlying
/// frame, so accessors stay `O(1)` and there's no per-row allocation.
/// Row indices outside `[0, nrows)` return `Err(IndexOutOfBounds(i))`.
pub fn DataFrame::row(
  self : DataFrame,
  i : Int,
) -> RowView raise @types.DataError {
  if i < 0 || i >= self.nrows {
    raise @types.DataError::IndexOutOfBounds(i)
  }
  self.row_view(i)
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// First `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails.
pub fn DataFrame::head(self : DataFrame, n : Int) -> DataFrame {
  let m = clamp_take(n, self.nrows)
  // `0 <= m <= nrows == c.len()`, so the contiguous row slice is in-bounds
  // and needs no bounds-checking `Result`.
  let new_cols : Array[Series] = self.columns.map(c => slice_series(c, 0, m))
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
  // Same in-bounds argument as `head`: `start + m == nrows == c.len()`.
  let new_cols : Array[Series] = self.columns.map(c => slice_series(c, start, m))
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
) -> DataFrame raise @types.DataError {
  // Validate bounds once using the first column (or against `nrows` if
  // there are no columns).
  if start < 0 {
    raise @types.DataError::IndexOutOfBounds(start)
  }
  if end > self.nrows {
    raise @types.DataError::IndexOutOfBounds(end)
  }
  if start > end {
    raise @types.DataError::InvalidOperation(
      "slice start > end: " + start.to_string() + " > " + end.to_string(),
    )
  }
  // Bounds were already validated against `self.nrows`, which equals every
  // column's length, so the contiguous slice is in-bounds.
  let new_cols : Array[Series] = self.columns.map(c => {
    slice_series(c, start, end - start)
  })
  {
    schema: self.schema,
    columns: new_cols,
    nrows: end - start,
    name_to_index: self.name_to_index,
  }
}

///|
/// Gather rows by index. Returns a frame whose i-th row is
/// `self[indices[i]]`. Any out-of-bounds index surfaces as
/// `IndexOutOfBounds(idx)`.
pub fn DataFrame::take(
  self : DataFrame,
  indices : Array[Int],
) -> DataFrame raise @types.DataError {
  for i in indices {
    if i < 0 || i >= self.nrows {
      raise @types.DataError::IndexOutOfBounds(i)
    }
  }
  // Indices were just validated against `self.nrows`, so the per-column
  // gather is in-bounds.
  let new_cols = self.columns.map(c => gather_series(c, indices))
  {
    schema: self.schema,
    columns: new_cols,
    nrows: indices.length(),
    name_to_index: self.name_to_index,
  }
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
