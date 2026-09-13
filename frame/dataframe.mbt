///|
/// A column-oriented, schema-aware table. `DataFrame` owns an ordered list
/// of equally-tall `Series` and a derived `Schema`; column lookup by name is
/// `O(1)` through the schema's own index, which is the one name→position
/// map a frame carries.
///
/// The fields are `priv` (private to this package), so a frame can only ever
/// be *built* through the constructors below — which rebuild the schema in
/// lock-step with the column vector — and *read* through accessors
/// that hand out nothing the caller can write back through: `columns()` and
/// `column_series()` build a fresh array each call, and `schema()` returns a
/// `Schema`, whose own fields are private behind a copying reader.
/// External code cannot reach the live `columns` container,
/// so it cannot mutate a validated frame into an inconsistent state.
///
/// What every constructor here establishes and every transform preserves is
/// that those parts agree. That agreement is written once — as INV1–INV5 in
/// `frame/invariants.mbt`, checked by `check_invariants` — and deliberately not
/// restated here, since a second copy is how the two would drift.
pub struct DataFrame {
  priv schema : @types.Schema
  priv columns : Array[Series]
  priv nrows : Int
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
/// Engine-internal, and it establishes INV7 rather than assuming it: a
/// negative `nrows` raises `InvalidOperation`. The length check that forces a
/// non-negative height for a frame with columns is vacuous at zero columns —
/// the very shape this constructor exists to build — so this is where that
/// invariant has to be closed.
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
/// Build a 0-row `DataFrame` matching `schema`. Each column is an empty
/// `Series` of the field's declared dtype.
///
/// The `schema` is re-validated through `Schema::Schema` (`raise
/// DuplicateColumn(name)` on a repeated name): every `Schema` constructor
/// already rejects duplicates, so this is defence-in-depth that keeps the
/// frame's "no duplicate names" invariant true regardless of how the schema
/// was built.
///
/// `raise Unsupported(...)` if any field carries `DataType::Null` — there is
/// no concrete Null backend to materialise into. Only an explicitly built
/// schema can carry it here: the readers never infer `Null`, and a probe
/// window that is entirely null falls back to `String`.
pub fn DataFrame::empty(
  schema : @types.Schema,
) -> DataFrame raise @types.DataError {
  let schema = @types.Schema::Schema(schema.fields())
  // Each empty column's physical dispatch (the buffer its dtype needs, and the
  // `Null`-dtype rejection) lives in `series`, which owns the column, so this
  // constructor no longer matches storage backends. A `Null` field has no
  // physical backend, so `Series::empty_of` raises `Unsupported`.
  let columns : Array[Series] = schema
    .fields()
    .map(f => Series::empty_of(f.name(), f.dtype()))
  { schema, columns, nrows: 0, }
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
  { schema, columns, nrows, }
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
/// The columns as `Series`, in declaration order — the total, ordered way to
/// walk a frame column by column, parallel to `columns()` and the schema's
/// fields. Reach for it instead of looping over `columns()` and calling
/// `get_column(name)` per name: that pays a lookup per column and is fallible
/// on a name this frame does not have, while this is neither.
///
/// A fresh array is returned (the `Series` themselves are immutable, storage
/// shared), so mutating it cannot perturb the frame's invariants. It is a
/// user-facing accessor, not an engine seam: it hands back the public `Series`
/// type and never the storage behind it, and the frame's own operators use it
/// for exactly the same reason a caller would.
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
/// Number of rows. With at least one column it equals every column's `len()`
/// (INV2); a column-less `N×0` frame has none to agree with, and carries its
/// height in the explicit `nrows` field alone.
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
  // INV1 (schema and columns agree on arity) keeps `index_of`'s result in
  // range for the column vector, so the lookup is the schema's `O(1)` index
  // and nothing else.
  self.columns[self.schema.index_of(name)]
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
//
// The row-window transforms (`head` / `tail` / `slice` / `gather`) are a
// family of their own and live in `frame/window.mbt`.
