///|
/// A column-oriented, schema-aware table. `DataFrame` owns an ordered list
/// of equally-tall `Series`, a derived `Schema`, and a private
/// `name_to_index` cache so column lookup by name is `O(1)`.
///
/// The fields are `priv` (private to this package), so a frame can only ever
/// be *built* through the constructors below — which rebuild the cache and the
/// schema in lock-step with the column vector — and *read* through the
/// copy-returning accessors (`columns()` / `column_series()` / `schema()`).
/// External code cannot reach the live `columns` / `name_to_index` containers,
/// so it cannot mutate a validated frame into an inconsistent state. The
/// preserved invariants:
///   * `schema.field_names() == columns.map(.name)`
///   * `columns.all(c => c.len() == nrows)`
///   * `name_to_index[name] == i  ⇔  columns[i].name == name`
pub struct DataFrame {
  priv schema : @types.Schema
  priv columns : Array[Series]
  priv nrows : Int
  priv name_to_index : Map[String, Int]
} derive(Eq, Debug)

///|
pub extend DataFrame with Eq::{equal, not_equal}

///|
pub extend DataFrame with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build a `DataFrame` from a list of `Series`. Validates:
/// - all columns have the same length (`raise LengthMismatch` otherwise);
/// - no two columns share a name (`raise DuplicateColumn(name)`).
///
/// Zero columns is valid and produces a `0×0` frame: with no column to anchor
/// a height, this constructor has nothing to infer a row count from. A
/// column-less frame *may* carry rows — `select([])`, a `drop` of every
/// column and `from_rows` under an empty schema all keep their input's height
/// — but those entry points know the height independently and build it
/// through `from_parts`.
///
/// The input array is copied, so mutating `columns` after construction
/// cannot perturb the frame's invariants (the `Series` values themselves
/// are immutable).
///
/// The type's own constructor — the spelling every canonically-constructed
/// type in MoonFrame uses (`Schema::Schema`, `Field::Field`, the options
/// types). The entry points that build a frame a *different* way keep their
/// own names: `empty` from a schema, `from_rows` from a `Scalar` matrix.
pub fn DataFrame::DataFrame(
  columns : Array[Series],
) -> DataFrame raise @types.DataError {
  let nrows = if columns.is_empty() { 0 } else { columns[0].len() }
  DataFrame::from_parts(columns, nrows)
}

///|
/// Build a `DataFrame` from a column vector and an explicit row count — the
/// general form `DataFrame::DataFrame` narrows by inferring the height from
/// `columns[0]`. It validates the same two things (all columns as tall as
/// `nrows`, no two columns sharing a name) but takes the height as given, so
/// it can build the one shape an inferred height cannot express: **`N×0`**, a
/// frame with rows but no columns.
///
/// `N×0` is a real shape in MoonFrame rather than a degenerate `0×0`.
/// Projecting a frame to zero columns keeps its height (`select([])`, a
/// `drop` of every column), JSON records with no fields do too (`[{}, {}]`
/// reads as `2×0`), and a file read whose projection matches no header yields
/// the file's rows and no columns. Only INV2 ties `nrows` to the column
/// vector, and it ranges over the columns that exist, so for a column-less
/// frame this field carries the height alone.
///
/// Engine-internal. The length check is vacuous for zero columns, leaving
/// `nrows` unvalidated there, so callers pass a non-negative count —
/// `check_invariants`' INV7 is the property a stray negative would break.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::from_parts(
  columns : Array[Series],
  nrows : Int,
) -> DataFrame raise @types.DataError {
  DataFrame::from_parts_with_fields(
    columns,
    columns.map(c => @types.Field::Field(c.name(), c.dtype())),
    nrows,
  )
}

///|
/// `from_parts` under a caller-supplied field vector — the constructor behind
/// the projections that *carry* metadata rather than re-derive it (`select`,
/// `drop`, `with_columns`). `fields` is index-aligned with `columns` and
/// agrees with each column's name and dtype; what it can differ in is the
/// declared `nullable`, which a derived field would reset to the `Field`
/// constructor default. Re-validated through `Schema::Schema`, so a repeated
/// name still raises `DuplicateColumn`.
fn DataFrame::from_parts_with_fields(
  columns : Array[Series],
  fields : Array[@types.Field],
  nrows : Int,
) -> DataFrame raise @types.DataError {
  let columns = columns.copy()
  if !columns.all(c => c.len() == nrows) {
    raise @types.DataError::LengthMismatch
  }
  let schema = @types.Schema::Schema(fields)
  { schema, columns, nrows, name_to_index: index_by_name(columns) }
}

///|
/// Build the name→index lookup cache from a column vector: position `i` maps
/// from `columns[i].name()`. Every constructor routes through `Schema::Schema`,
/// which rejects duplicate names before this runs, so the `(name, i)` pairs
/// are 1:1 with the columns. Shared by `new`, `empty`, and `from_rows`.
fn index_by_name(columns : Array[Series]) -> Map[String, Int] {
  Map::from_array(columns.mapi((i, c) => (c.name(), i)))
}

///|
/// Build a 0-row `DataFrame` matching `schema`. Each column is an empty
/// `Series` of the field's declared dtype.
///
/// The `schema` is re-validated through `Schema::Schema` (`raise
/// DuplicateColumn(name)` on a repeated name): every `Schema` constructor
/// already rejects duplicates, so this is defence-in-depth that keeps the
/// frame's "no duplicate names" invariant true regardless of how the schema
/// was built.
///
/// `raise Unsupported(...)` if any field carries `DataType::Null` — v0.1 has
/// no concrete Null backend (and a CSV-inferred Null column has nothing to
/// materialise into).
pub fn DataFrame::empty(
  schema : @types.Schema,
) -> DataFrame raise @types.DataError {
  let schema = @types.Schema::Schema(schema.fields())
  let columns : Array[Series] = schema
    .fields()
    .map(f => {
      // Dispatch on the field's *physical* type — the buffer it needs. `Null`
      // has none (`physical()` is `None`), which is precisely why an all-null
      // column cannot be materialised, so the rejection reads as "no physical
      // backend" rather than a special-cased variant.
      let storage = match f.dtype().physical() {
        Some(@types.PhysicalType::I64) => @column.BuiltinColumn::from_ints([])
        Some(@types.PhysicalType::F64) => @column.BuiltinColumn::from_floats([])
        Some(@types.PhysicalType::Bool) => @column.BuiltinColumn::from_bools([])
        Some(@types.PhysicalType::Utf8) =>
          @column.BuiltinColumn::from_strings([])
        None =>
          raise @types.DataError::Unsupported(
            "cannot build empty DataFrame column of dtype Null: \{f.name()}",
          )
      }
      Series::from_builtin(f.name(), storage)
    })
  { schema, columns, nrows: 0, name_to_index: index_by_name(columns) }
}

///|
/// Decode column `column` of a row-major `Scalar` matrix into the typed
/// optional cells a `Series::from_*_options` constructor takes: a
/// `Scalar::Null` becomes `None`, a cell `decode` recognises is unwrapped, and
/// anything else `raise`s `TypeMismatch(Expected(field.dtype(), got, name))`.
/// Rows are visited in order, so the reported cell is the first offending one.
///
/// The skeleton `from_rows`' four typed arms share: each supplies only the
/// `Scalar` variant it reads and the constructor that consumes the result, so a
/// dtype added later cannot quietly skip the null mapping or the mismatch
/// error. `rows` is pre-validated to be `schema.len()` wide, so `row[column]`
/// is in-bounds.
fn[T] typed_column_cells(
  rows : Array[Array[@types.Scalar]],
  column : Int,
  field : @types.Field,
  decode : (@types.Scalar) -> T?,
) -> Array[T?] raise @types.DataError {
  rows.map(row => {
    match row[column] {
      @types.Scalar::Null => None
      cell =>
        match decode(cell) {
          Some(v) => Some(v)
          None =>
            raise @types.DataError::TypeMismatch(
              @types.TypeMismatchDetail::Expected(
                field.dtype(),
                cell.dtype(),
                field.name(),
              ),
            )
        }
    }
  })
}

///|
/// Build a `DataFrame` from a row-major matrix of `Scalar`s. Each row
/// must have exactly `schema.len()` cells, and each cell must either
/// match the column's declared dtype or be `Scalar::Null`.
///
/// The height is always `rows.length()`, including under an empty schema:
/// `from_rows(Schema::Schema([]), [[], []])` is the `2×0` frame, since
/// width-0 rows are still rows (see `from_parts`).
///
/// Raises:
/// - `DuplicateColumn(name)` — the schema carries a repeated field name.
///   Every `Schema` constructor already rejects duplicates, so this is
///   defence-in-depth: re-validating through `Schema::Schema` here (as `empty`
///   does) keeps the "no duplicate names" invariant regardless of how the
///   schema reached this call.
/// - `LengthMismatch` — a row's width differs from `schema.len()`.
/// - `TypeMismatch(Expected(expected, got, column))` — a non-null cell's dtype doesn't
///   match the schema's dtype for that column (the pieces kept structured).
/// - `Unsupported(...)` — schema declares a `Null`-dtype column (same
///   reason as `empty`).
/// - `NullInNonNullable(name)` — a `Scalar::Null` lands in a column whose
///   field is declared `nullable = false`.
pub fn DataFrame::from_rows(
  schema : @types.Schema,
  rows : Array[Array[@types.Scalar]],
) -> DataFrame raise @types.DataError {
  let schema = @types.Schema::Schema(schema.fields())
  let ncols = schema.len()
  if !rows.all(row => row.length() == ncols) {
    raise @types.DataError::LengthMismatch
  }
  // The row count comes from `rows`, never from the columns: under an empty
  // schema every row had to be width-0 to pass the check above, and those
  // rows still count — `from_rows(Schema::Schema([]), [[], []])` is `2×0`,
  // not `0×0` (see `from_parts`).
  let nrows = rows.length()
  // `fields()` materialises all fields; indexing `[0, ncols)` is in-bounds
  // (`fields.length() == schema.len() == ncols`).
  let fields = schema.fields()
  let columns : Array[Series] = Array::makei(ncols, i => {
    let field = fields[i]
    // Each typed arm supplies only two things — the `Scalar` variant its dtype
    // reads, and the `Series` constructor that consumes the decoded cells. The
    // null mapping, the `TypeMismatch` for a foreign cell, and the row order
    // that decides which cell is reported live once, in `typed_column_cells`.
    let column = match field.dtype() {
      @types.DataType::Int =>
        Series::from_int_options(
          field.name(),
          typed_column_cells(rows, i, field, cell => {
            if cell is @types.Scalar::Int(v) {
              Some(v)
            } else {
              None
            }
          }),
        )
      @types.DataType::Float =>
        Series::from_float_options(
          field.name(),
          typed_column_cells(rows, i, field, cell => {
            if cell is @types.Scalar::Float(v) {
              Some(v)
            } else {
              None
            }
          }),
        )
      @types.DataType::Bool =>
        Series::from_bool_options(
          field.name(),
          typed_column_cells(rows, i, field, cell => {
            if cell is @types.Scalar::Bool(v) {
              Some(v)
            } else {
              None
            }
          }),
        )
      @types.DataType::String =>
        Series::from_string_options(
          field.name(),
          typed_column_cells(rows, i, field, cell => {
            if cell is @types.Scalar::String(v) {
              Some(v)
            } else {
              None
            }
          }),
        )
      @types.DataType::Null =>
        raise @types.DataError::Unsupported(
          "cannot build DataFrame column of dtype Null: \{field.name()}",
        )
    }
    // Enforce the field's declared non-nullability: a `nullable = false`
    // field must not carry nulls. `empty` builds 0-row columns and so can
    // never violate this; `from_rows` is the only constructor where row data
    // can place a null under such a field.
    if !field.nullable() && column.null_count() > 0 {
      raise @types.DataError::NullInNonNullable(field.name())
    }
    column
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
/// Materialise every column's cells as a column-major matrix of `Scalar`s:
/// `result[c][r]` is the cell at column `c`, row `r`, with `Scalar::Null`
/// for a null slot (one inner array per column, each `nrows` long).
/// Equivalent to `column_series().map(s => s.to_scalars())`, and **total** —
/// `Series::to_scalars` is total over every backend.
///
/// This is the one-pass bulk read the row-oriented serialisers (`format_csv` /
/// the JSON record emitter) share: each materialises the whole frame once,
/// then assembles a record by plain `[c][r]` indexing rather than a per-cell
/// `item`, so no row walk pays a repeated bounds-checked lookup. (The table
/// renderers `to_html` / `to_markdown` instead scalarise only the visible row
/// window, per column, via `table_cell_matrix`.)
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::to_scalar_matrix(
  self : DataFrame,
) -> Array[Array[@types.Scalar]] {
  self.columns.map(s => s.to_scalars())
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
/// `O(1)` lookup of the column named `name`. `raise ColumnNotFound(name)`
/// if the column is missing.
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
/// Column at position `i`. Out-of-bounds `raise IndexOutOfBounds(i)`.
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
/// Read the cell at `(row, name)` as a `Scalar`, mirroring Polars'
/// `DataFrame.item(row, column)`. Surfaces `ColumnNotFound` for unknown
/// names and `IndexOutOfBounds` for row indices outside `[0, nrows)`.
pub fn DataFrame::item(
  self : DataFrame,
  row : Int,
  name : String,
) -> @types.Scalar raise @types.DataError {
  self.get_column(name).get(row)
}

///|
/// Row `i`'s cells as a `Scalar` tuple in column order (a null cell as
/// `Scalar::Null`), mirroring Polars' `DataFrame.row`. Row indices outside
/// `[0, nrows)` `raise IndexOutOfBounds(i)`; for many rows, `rows()` reads
/// the whole frame in one pass instead.
pub fn DataFrame::row(
  self : DataFrame,
  i : Int,
) -> Array[@types.Scalar] raise @types.DataError {
  if i < 0 || i >= self.nrows {
    raise @types.DataError::IndexOutOfBounds(i)
  }
  // `i` is in range and every column has `nrows` cells, so `Series::get`
  // never raises here — the bound is checked once, up front.
  [
    for s in self.columns => s.get(i)
  ]
}

///|
/// Every row as a `Scalar` tuple in column order (`result[r][c]`), the
/// row-major transpose of `to_scalar_matrix`, mirroring Polars'
/// `DataFrame.rows`. Total — materialises the frame once.
pub fn DataFrame::rows(self : DataFrame) -> Array[Array[@types.Scalar]] {
  let cols = self.to_scalar_matrix()
  Array::makei(self.nrows, r => cols.map(c => c[r]))
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// First `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails. Also exposed under its Polars / SQL name
/// `limit` (via `#alias`) — the eager twin of `LazyFrame::limit`, keeping
/// the two surfaces verb-for-verb aligned.
#alias(limit)
pub fn DataFrame::head(self : DataFrame, n : Int) -> DataFrame {
  let m = clamp_take(n, self.nrows)
  // `0 <= m <= nrows == c.len()`, so the contiguous row slice is in-bounds
  // and needs no bounds-checking `Result`.
  let new_cols : Array[Series] = self.columns.map(c => slice_series(c, 0, m))
  // Names and schema are unchanged — reuse the cache verbatim.
  self.with_same_schema(new_cols, m)
}

///|
/// Last `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails.
pub fn DataFrame::tail(self : DataFrame, n : Int) -> DataFrame {
  let m = clamp_take(n, self.nrows)
  let start = self.nrows - m
  // Same in-bounds argument as `head`: `start + m == nrows == c.len()`.
  let new_cols : Array[Series] = self.columns.map(c => slice_series(c, start, m))
  self.with_same_schema(new_cols, m)
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
      "slice start > end: \{start} > \{end}",
    )
  }
  // Bounds were already validated against `self.nrows`, which equals every
  // column's length, so the contiguous slice is in-bounds.
  let new_cols : Array[Series] = self.columns.map(c => {
    slice_series(c, start, end - start)
  })
  self.with_same_schema(new_cols, end - start)
}

///|
/// Gather rows by index. Returns a frame whose i-th row is
/// `self[indices[i]]`. Any out-of-bounds index surfaces as
/// `IndexOutOfBounds(idx)`.
pub fn DataFrame::gather(
  self : DataFrame,
  indices : Array[Int],
) -> DataFrame raise @types.DataError {
  for i in indices {
    if i < 0 || i >= self.nrows {
      raise @types.DataError::IndexOutOfBounds(i)
    }
  }
  // An identity permutation (`indices == [0, nrows)`) gathers every row in
  // place — a no-op rebuild — so return `self`. The check is `O(n)` with an
  // early exit, dwarfed by the gather it can skip; a genuine reorder or a
  // strict subset (a `filter` / `drop_nulls` that drops rows) fails it on the
  // length test or the first out-of-place index.
  if is_identity_perm(indices, self.nrows) {
    return self
  }
  // Indices were just validated against `self.nrows`, so the per-column
  // gather is in-bounds.
  let new_cols = self.columns.map(c => gather_series(c, indices))
  self.with_same_schema(new_cols, indices.length())
}

///|
/// Whether `indices` is the identity permutation `[0, 1, ..., nrows - 1]` —
/// the case where a gather reproduces the frame unchanged. Lets `gather`
/// short-circuit a no-op copy (an already-ordered `sort`, a `filter`
/// that keeps every row). Fails fast: a length mismatch or the first
/// out-of-place index returns `false` before the rest is scanned.
fn is_identity_perm(indices : Array[Int], nrows : Int) -> Bool {
  if indices.length() != nrows {
    return false
  }
  for i in 0..<indices.length() {
    if indices[i] != i {
      return false
    }
  }
  true
}

// ── Storage backend control ───────────────────────────────────────────

///|
/// The storage backend of each column, in declaration order — `Numeric`
/// for all-valid unboxed numeric columns, `Builtin` otherwise. Parallel to
/// `columns()` / the schema's fields.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::storage_kinds(self : DataFrame) -> Array[@column.StorageKind] {
  self.columns.map(c => c.storage_kind())
}

///|
/// Move every eligible column onto the `Numeric` fast-path backend,
/// best-effort and **total**: an all-valid Int / Float column converts; a
/// column carrying nulls, a non-numeric column, or one already `Numeric` is
/// kept unchanged (via the non-raising `try_column_to_numeric`, so a column
/// that cannot move never fails the whole frame). Names, dtypes, and values
/// are unchanged — only the backing representation of the converted columns
/// — so the schema and `O(1)` lookup cache are reused verbatim.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::to_numeric(self : DataFrame) -> DataFrame {
  let new_cols = self.columns.map(try_column_to_numeric)
  self.with_same_schema(new_cols, self.nrows)
}

///|
/// Materialise every column onto the general-purpose `Builtin` backend (the
/// inverse of `to_numeric`). Total and lossless — `Numeric` columns widen
/// with an all-valid bitmap, `Builtin` columns are unchanged — so names,
/// dtypes, and values are preserved and the schema / lookup cache are
/// reused verbatim.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::to_builtin(self : DataFrame) -> DataFrame {
  let new_cols = self.columns.map(c => c.to_builtin())
  self.with_same_schema(new_cols, self.nrows)
}

// ── Internal helpers ──────────────────────────────────────────────────

///|
/// Rebuild the frame from `new_cols` and `nrows`, reusing this frame's schema
/// and `O(1)` name→index cache verbatim. The schema-preserving constructor
/// behind the row-only transforms (`head` / `tail` / `slice` / `gather` /
/// `fill_null` / `unique`) and the backend re-representations (`to_numeric` /
/// `to_builtin`): the column values or backing change but the names and dtypes
/// do not, so the cache stays valid and these never pay to rebuild it through
/// `DataFrame::DataFrame` (`O(n)`, and able to raise). Total — the caller guarantees
/// `new_cols` still matches the schema and carries `nrows` rows each.
///
/// Spelt as a struct update so that a field added to `DataFrame` later is
/// carried over by default — only what a row transform actually changes is
/// named here.
fn DataFrame::with_same_schema(
  self : DataFrame,
  new_cols : Array[Series],
  nrows : Int,
) -> DataFrame {
  { ..self, columns: new_cols, nrows }
}

///|
/// The column an expression only *renames*, if any. `col("x")` reads column
/// `x` and changes nothing about its cells; `col("x").with_alias("y")` changes
/// nothing but the name. Every other expression computes — including `cast`,
/// which keeps the cells but not the dtype — so it has no source column whose
/// metadata the result could inherit.
///
/// Written without a wildcard so a new `Expr` variant has to state whether it
/// is a pure rename rather than defaulting to "no".
fn projection_source(expr : @expr.Expr) -> String? {
  match expr {
    @expr.Expr::Col(name) => Some(name)
    @expr.Expr::Alias(inner, _) => projection_source(inner)
    @expr.Expr::Lit(_)
    | @expr.Expr::LitSeries(_)
    | @expr.Expr::Binary(_, _, _)
    | @expr.Expr::Unary(_, _)
    | @expr.Expr::Agg(_, _)
    | @expr.Expr::Str(_, _)
    | @expr.Expr::Cast(_, _)
    | @expr.Expr::Ternary(_, _, _)
    | @expr.Expr::FillNull(_, _)
    | @expr.Expr::FillNan(_, _)
    | @expr.Expr::IsIn(_, _)
    | @expr.Expr::IsBetween(_, _, _, _)
    | @expr.Expr::Map(_, _, _)
    | @expr.Expr::MapBatches(_, _, _, _) => None
  }
}

///|
/// The `Field` a projected column carries. An expression that only renames a
/// column leaves its cells untouched, so the result keeps that column's
/// declared `nullable` under the output name; a computed one gets a field
/// derived from the result, whose flag is the `Field` constructor default.
///
/// `source_fields` is the frame's own field vector, materialised once by the
/// caller rather than per expression. A named source column is always present:
/// the expression was evaluated against this frame first, and a name the frame
/// lacks raised `ColumnNotFound` there.
fn DataFrame::carried_field(
  self : DataFrame,
  source_fields : Array[@types.Field],
  expr : @expr.Expr,
  column : Series,
  name : String,
) -> @types.Field {
  let carried = match projection_source(expr) {
    Some(src) => self.name_to_index.get(src).map(i => source_fields[i])
    None => None
  }
  match carried {
    Some(field) => field.rename(name)
    None => @types.Field::Field(name, column.dtype())
  }
}

///|
/// Rebuild the frame under an edited field vector — the rename verbs' sibling
/// of `with_same_schema`. `fields` is index-aligned with the column vector and
/// differs from `self.schema`'s only in the field *names* (`rename` /
/// `rename_with` map each through `Field::rename`), so this re-validates it
/// through `Schema::Schema` — `raise DuplicateColumn(name)` on the first repeat —
/// retitles each column to its field's name, and rebuilds the `O(1)`
/// name→index cache, which unlike `with_same_schema` cannot be reused because
/// the names moved. Row count and column order are untouched.
///
/// Carrying the fields rather than re-deriving them through `DataFrame::DataFrame` is
/// what keeps a renamed column's metadata: `new` names every field with the
/// `Field` constructor default, resetting a declared `nullable = false`, while
/// a rename by contract changes nothing but the name.
fn DataFrame::with_renamed_fields(
  self : DataFrame,
  fields : Array[@types.Field],
) -> DataFrame raise @types.DataError {
  let schema = @types.Schema::Schema(fields)
  // `fields` is index-aligned with the column vector, so `columns[i]` is
  // in-bounds and the rebuilt schema mirrors the columns name-for-name.
  let new_cols = fields.mapi((i, f) => self.columns[i].rename(f.name()))
  {
    schema,
    columns: new_cols,
    nrows: self.nrows,
    name_to_index: index_by_name(new_cols),
  }
}

///|
/// Resolve a `subset` selector — an `Array[Expr]` of column keys — to the named
/// columns, validating in order. Each key names a column through the §0 naming
/// rule (`Expr::output_name`: a bare `col("x")` names `"x"`, an alias names the
/// alias), and `get_column` raises `ColumnNotFound` on the first name absent
/// from the frame, before any per-row work runs. The key expression is **never
/// evaluated** — only its output name is consulted — the shared "name-only"
/// contract behind the `subset` of `drop`, `drop_nulls`, and `unique`. A
/// repeated key resolves the same column twice; each caller absorbs that (a
/// collapsing drop set, an AND of validity masks, a repeated group-key cell).
fn DataFrame::resolve_subset_columns(
  self : DataFrame,
  keys : Array[@expr.Expr],
) -> Array[Series] raise @types.DataError {
  keys.map(key => self.get_column(expr_output_name(key)))
}
