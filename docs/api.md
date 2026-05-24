# MoonFrame v0.1 — Public API

> Status: **skeleton only.** This document is the source of truth for the
> v0.1 public surface. Each phase fills in its section as it ships.
> When a symbol is published in code, it must appear here.

Once **P13** lands, the facade package `ihb2032/MoonFrame` will re-export
all symbols below. Until then, import the sub-packages
(`types`, `column`, `frame`, `ops`, `io`) directly — sub-package imports
remain supported even after the facade ships.

---

## `types` — Value types and errors

> Implemented in **P1** (`error.mbt`, `dtype.mbt`, `scalar.mbt`) and
> **P3** (`field.mbt`, `schema.mbt`).

- `enum DataError` — 10 variants: `ColumnNotFound` / `DuplicateColumn` /
  `TypeMismatch` / `LengthMismatch` / `IndexOutOfBounds` / `ParseError` /
  `InvalidOperation` / `IoError` / `EmptyDataFrame` / `Unsupported`.
  `DataError::message()` renders a human-readable description; the
  `Show` impl renders the variant form for assertion snapshots.
- `enum DataType` — `Int | Float | Bool | String | Null`, with
  `is_numeric` / `is_integer` / `is_float` / `is_string` / `is_bool`
- `enum Scalar` — cell value; `dtype` / `is_null` / `to_string` (value
  form, e.g. `Int(42) → "42"`, `Null → ""`) / `as_int` / `as_float` /
  `as_bool` / `as_string` accessors; total ordering via `eq` / `lt` /
  `lte` / `gt` / `gte` (each returns `Result[Bool, DataError]` so that
  `Null` short-circuits to `Err(TypeMismatch)`)
- `struct Field` — column metadata: `name`, `dtype`, `nullable`.
  - Constructors: `Field::new(name, dtype)` (defaults `nullable = true`),
    `Field::with_nullable(name, dtype, nullable)`.
  - Accessors: `name` / `dtype` / `nullable`.
  - `rename(new_name)` returns a copy with a different name.
- `struct Schema` — ordered list of `Field`s with duplicate-name
  detection.
  - `Schema::new(fields)` — returns `Err(DuplicateColumn(name))` on the
    first repeated name; otherwise `Ok(schema)`. An empty input is
    valid.
  - Inspection: `fields` / `field_names` / `len` / `is_empty`.
  - Lookup: `index_of(name)` and `field(name)` return
    `Err(ColumnNotFound(name))` for unknown columns; `field_at(i)`
    returns `Err(IndexOutOfBounds(i))` outside `[0, len)`.
  - `select(names)` — project a sub-schema preserving the order of
    `names`. Missing names → `ColumnNotFound`; duplicates inside the
    pick list → `DuplicateColumn`.
  - `rename(old_name, new_name)` — `ColumnNotFound` if `old_name` is
    missing; `DuplicateColumn` if `new_name` collides with another
    existing column. Renaming to the same name is a no-op (but still
    validates `old_name` exists).

---

## `column` — Column storage backends

> Implemented in **P2** (initial Option-based draft) and **P3.5**
> (`bitmap.mbt`, `builtin.mbt` rewritten to Apache Arrow style: a raw
> data buffer plus a separate bit-packed validity bitmap).

### Validity bitmap

- `struct Bitmap { bits : Bytes, len : Int }` — Arrow-compatible
  validity bitmap, byte-packed at **1 bit per row, 1 = valid, 0 = null**.
  Slot `i` lives in `bits[i / 8]` at bit `i % 8` (LSB first), and a
  bitmap of `len` slots occupies exactly `⌈len / 8⌉` bytes. Trailing
  bits past `len` are kept zero so popcount is safe over the whole
  buffer. Note: some MoonBit ecosystem libraries (e.g.
  `smallbearrr/pandas`) use the opposite convention (`true = null`).
- Constructors: `Bitmap::all_valid(len)` / `Bitmap::all_null(len)` /
  `Bitmap::from_bools(Array[Bool])` (`true ↦ valid`) /
  `Bitmap::from_options[T](Array[T?])` (`Some(_) ↦ valid`).
- Inspection: `len` / `is_valid(i)` / `is_null(i)` / `null_count()`.
  Index-based accessors return `Err(IndexOutOfBounds(i))` outside
  `[0, len)`.
- Transforms: `slice(start, length)` (rebuilds by repacking — no
  zero-copy view; v0.2 may optimise), `take(indices)` (gather with
  duplicates allowed; first out-of-bounds index wins),
  `bit_and(other)` (`LengthMismatch` if lengths differ — `and` is a
  reserved keyword in MoonBit, hence `bit_and`).

### BuiltinColumn

- `struct BuiltinColumn { data : ColumnData, validity : Bitmap }` —
  Arrow-style column. The `data` array holds raw values (no `Option`
  boxing); null slots carry per-dtype placeholders (`Int = 0`,
  `Float = 0.0`, `Bool = false`, `String = ""`) that never leak through
  public methods, because every read consults `validity` first. v0.2
  will add a `ColumnStorage` abstraction over this struct without
  changing the public API.
- `pub(all) enum ColumnData` — `Int(Array[Int]) | Float(Array[Float]) |
  Bool(Array[Bool]) | String(Array[String])`. Element type is the raw
  value; nullability lives on the enclosing column.
- Constructors (8, signatures unchanged from P2): `from_ints` /
  `from_int_options` / `from_floats` / `from_float_options` /
  `from_bools` / `from_bool_options` / `from_strings` /
  `from_string_options`. The `*_options` constructors build the
  validity bitmap from the `Some/None` pattern and place placeholder
  values in the data buffer at null slots.
- Inspection: `dtype` / `len` / `is_empty` / `null_count` /
  `is_null(i)` / `get(i)`. Index-based accessors return
  `Err(IndexOutOfBounds(i))` outside `[0, len)`.
- Sub-views: `slice(start, end)` (half-open, copies both data and
  validity) / `take(indices)` (gather with duplicates allowed; first
  out-of-bounds index wins).
- Cast: `cast(target)` dispatches to one of — validity is preserved
  verbatim across every cast.
  - `to_int` — identity on Int; Float truncates towards zero (`NaN`,
    `±Inf`, and values outside `Int32` range → `ParseError`); Bool maps
    `true → 1`, `false → 0`; String parses with `@string.parse_int`
    (non-numeric on a valid slot → `ParseError`).
  - `to_float` — Int promoted via `Float::from_int`; identity on
    Float; Bool maps to `1.0` / `0.0`; String parses with
    `@string.parse_double` then narrowed to 32-bit.
  - `to_string_column` — every dtype rendered with `Scalar::to_string`
    semantics (e.g. `Int(42) → "42"`, `Bool(true) → "true"`).
  - `Bool` / `Null` targets return `Err(Unsupported)`.
- Typed accessors (zero-boxing fast path for ops): `int_values` /
  `float_values` / `bool_values` / `string_values` return
  `Result[(Array[T], Bitmap), DataError]`. Wrong dtype →
  `Err(TypeMismatch)`. Always consult the returned `Bitmap` before
  reading the data array — null slots hold the dtype placeholder.

---

## `frame` — Series, DataFrame, RowView

> Implemented in **P4** (Series + stats) and **P5** (DataFrame,
> RowView).

### Series

- `struct Series { name : String, storage : @column.BuiltinColumn }` —
  named column wrapping a `BuiltinColumn`. The struct is `pub` (fields
  private outside the package), so callers always go through the
  constructors and accessors below.
- Constructors (10):
  - `Series::new(name, storage)` — wrap an existing `BuiltinColumn`.
  - `Series::from_builtin(name, storage)` — explicit alias for `new`.
  - `from_ints` / `from_int_options` / `from_floats` /
    `from_float_options` / `from_bools` / `from_bool_options` /
    `from_strings` / `from_string_options` — dtype shortcuts that
    delegate to the matching `BuiltinColumn::from_*` constructor.
- Inspection: `name` / `dtype` / `len` / `is_empty` / `null_count` /
  `null_rate` / `is_null(i)` / `get(i)` / `storage`. `null_rate`
  returns `0.0` for an empty series (avoids a `0/0` NaN that would
  propagate through downstream stats). `storage` exposes the
  underlying column so ops can reach the typed accessors.
- Transforms:
  - `rename(new_name)` — `O(1)`; storage is shared.
  - `slice(start, end)` / `take(indices)` — delegate to
    `BuiltinColumn` and bubble the same `IndexOutOfBounds` /
    `InvalidOperation` diagnostics.
  - `drop_nulls()` — gather non-null indices; result has a fully-valid
    bitmap and `len = original.len - original.null_count`.
  - `fill_null(value : Scalar)` — replace every null cell with
    `value`. `Scalar::Null` and dtype-mismatched scalars return
    `Err(TypeMismatch)`.
  - `cast(target)` / `to_int` / `to_float` / `to_string_series` —
    forward to the underlying column. `to_string_series` is total
    (always `Ok`).

### Stats (file: `series_stats.mbt`)

- `count()` — non-null count.
- `sum()` — `Int` / `Float` series return `Scalar::Int` /
  `Scalar::Float`; empty / all-null is the additive identity (`0` /
  `0.0`). `Bool` / `String` → `Err(TypeMismatch)`.
- `mean()` — `Float` result (Int sums promoted). Empty / all-null
  numeric → `Err(InvalidOperation)`. Non-numeric → `Err(TypeMismatch)`.
- `min()` / `max()` — supported on every dtype; empty / all-null returns
  `Ok(Scalar::Null)`. `Float` NaN follows IEEE 754: `<` / `>` against
  NaN is `false`, so NaN never displaces a non-NaN best. `Bool` order
  is `false < true`.
- `unique_count()` — distinct non-null values, keyed by
  `Scalar::to_string`. Within a fixed-dtype series this is a precise
  equality test; all `Float` `NaN` cells collapse into a single bucket
  (matching pandas' `nunique` on NaN).

- `describe()` — one-row summary `DataFrame`. Every series gets
  `count` / `null_count` / `unique_count` (`Int`). Numeric series add
  `mean` (`Float`, `Null` for empty / all-null). All dtypes add `min`
  and `max`, typed to match the source series (`Null` cells when the
  reduction has no value). Column order: numeric — `count`,
  `null_count`, `unique_count`, `mean`, `min`, `max`; `Bool` / `String`
  — `count`, `null_count`, `unique_count`, `min`, `max`.

### DataFrame

- `struct DataFrame` — column-oriented table. Fields are private
  outside the package: `schema : Schema`, `columns : Array[Series]`,
  `nrows : Int`, plus a private `name_to_index : Map[String, Int]`
  cache so name-based column lookup is `O(1)`. Constructors keep the
  schema, the column vector, and the cache in lock-step, preserving:
  `schema.field_names() == columns.map(.name)`,
  `columns.all(c => c.len() == nrows)`, and
  `name_to_index[name] == i ⇔ columns[i].name == name`.
- Constructors (3):
  - `DataFrame::new(columns)` — `Err(LengthMismatch)` if any column
    differs in length from `columns[0]`; `Err(DuplicateColumn(name))`
    on a repeated name (via `Schema::new`). Zero columns is valid and
    produces a `0×0` frame.
  - `DataFrame::empty(schema)` — zero-row frame matching `schema`.
    Each column is built via the corresponding `BuiltinColumn::from_*`
    constructor with an empty array. `Err(Unsupported(...))` if any
    field carries `DataType::Null` (no concrete Null backend in v0.1).
  - `DataFrame::from_rows(schema, rows)` — row-major build. Each row
    must have `schema.len()` cells; each cell must either match the
    column's dtype or be `Scalar::Null`. Errors:
    `LengthMismatch` (row width), `TypeMismatch(...)` (cell vs column
    dtype), `Unsupported(...)` (Null-dtype field).
- Inspection: `shape() -> (Int, Int)` (rows, cols) / `schema()` /
  `columns() -> Array[String]` (fresh per call — caller can mutate
  without affecting the frame) / `nrows()` / `ncols()` /
  `is_empty()` (`nrows == 0`).
- Accessors:
  - `get_column(name)` — `O(1)` via the cache;
    `Err(ColumnNotFound(name))` if missing.
  - `get_column_at(i)` — positional lookup with
    `Err(IndexOutOfBounds(i))` outside `[0, ncols)`.
  - `get(row, name)` — single-cell `Scalar` read. Forwards
    `ColumnNotFound` from `get_column` and `IndexOutOfBounds` from
    `Series::get`.
  - `row(i)` — open a `RowView` over the given row; row indices
    outside `[0, nrows)` return `Err(IndexOutOfBounds(i))`.
- Transforms (all keep the schema and `name_to_index` intact):
  - `head(n)` / `tail(n)` — first / last `n` rows; `n` is clamped to
    `[0, nrows]`, so both are total.
  - `slice(start, end)` — half-open row slice. Same diagnostics as
    `Series::slice`: `IndexOutOfBounds` on out-of-range bounds,
    `InvalidOperation(...)` when `start > end`.
  - `take(indices)` — row-wise gather (duplicates allowed); first
    out-of-bounds index surfaces as `IndexOutOfBounds(idx)`.
- `check_invariants()` — verification helper. Returns `Ok(())` exactly
  when the frame satisfies its six structural invariants (schema /
  columns / `name_to_index` lock-step, per-column length `== nrows`,
  no out-of-range or mismatched cache entries); otherwise
  `Err(String)` describing the first violation. Defined as the formal
  specification of "a well-formed DataFrame" in `frame/invariants.mbt`
  and asserted by every `ops/` test on the operator's output. Public
  API constructors (`new` / `empty` / `from_rows`) and transforms
  (`head` / `tail` / `slice` / `take`) can never produce an
  invariant-violating frame — the failure branches exist to catch
  internal bugs and to be exercised by whitebox tests that bypass the
  constructors.

### RowView

- `struct RowView { df : DataFrame, row_index : Int }` — borrowed
  view of a single row; no per-row allocation. Built via
  `DataFrame::row(i)`, which validates the row index up front.
- `index()` — the row position the view was opened at.
- `get(name)` — `Scalar` cell read; null cells return
  `Ok(Scalar::Null)`. `Err(ColumnNotFound(name))` for unknown columns.
- `is_null(name)` — `Bool` per cell; same error path as `get`.
- Typed accessors (`get_int` / `get_float` / `get_bool` /
  `get_string`) compose `get(name)` with `Scalar::as_int` /
  `as_float` / `as_bool` / `as_string`, so they inherit the
  `Scalar::as_*` rules: `Err(TypeMismatch(...))` for the wrong dtype
  **or** a null cell. `get_float` additionally promotes `Int` cells
  via `Scalar::as_float`.

---

## `ops` — Operations

> Implemented in **P6 – P10**. One operator per file. Each op is a
> **free function** rather than a `DataFrame` method (MoonBit's orphan
> rule prevents adding inherent methods to `@frame.DataFrame` from a
> sibling package), so the call site is `@ops.filter(df, ...)` rather
> than `df.filter(...)`. Every op routes its result through the
> `frame` package's invariant-preserving constructors / transforms,
> so the returned frame is guaranteed to satisfy `check_invariants()`.

### Column ops (P6)

Routed through `DataFrame::new`, which rebuilds the schema and
`name_to_index` cache.

- `select(df, names) -> Result[DataFrame, DataError]` — project
  columns in the requested order. `Err(ColumnNotFound(name))` for
  unknown names; `Err(DuplicateColumn(name))` for duplicates in the
  pick list. First-error wins is positional.
- `drop(df, names) -> Result[DataFrame, DataError]` — remove the named
  columns, preserving the remaining order. Duplicates in `names` are
  tolerated (idempotent). `Err(ColumnNotFound(name))` on the first
  unknown entry.
- `rename(df, mapping : Array[(String, String)]) -> Result[DataFrame, DataError]`
  — apply renames in input order, so each step's `new_name` becomes
  visible to subsequent steps (which is what makes the three-step
  swap `[(a, _t), (b, a), (_t, b)]` work). `Err(ColumnNotFound)` for
  an unknown source; `Err(DuplicateColumn)` if a `new_name` collides
  with another current column. `(name, name)` is a no-op that still
  validates existence.
- `with_column(df, series) -> Result[DataFrame, DataError]` — append
  `series` as the rightmost column. `Err(DuplicateColumn(name))` if
  `series.name()` already exists; `Err(LengthMismatch)` if
  `series.len() != df.nrows()`. For a `0×0` frame, `nrows == 0`, so
  only an empty series is accepted — bootstrap with `DataFrame::new`
  instead.
- `replace_column(df, name, series) -> Result[DataFrame, DataError]`
  — swap the named column in place. The target `name` is preserved on
  the new column (i.e. `series.name()` is ignored for naming
  purposes), so the schema name order stays stable when a caller only
  wants to swap data / dtype. Cross-dtype replacement is allowed.
  `Err(ColumnNotFound(name))` if `name` doesn't exist;
  `Err(LengthMismatch)` if `series.len() != df.nrows()`.

### Row filter (P7)

Both filter ops route their result through `DataFrame::take`, so the
returned frame keeps the input's schema verbatim (column names,
dtypes, nullability, order) and only the row count changes. Filtering
every row out collapses to a 0-row frame **with the original
schema** — the meaningful distinction from `select(df, [])`, which
collapses the columns.

- `filter(df, predicate : (RowView) -> Bool) -> Result[DataFrame, DataError]`
  — keep rows for which `predicate` returns `true`. The predicate
  receives a `RowView` borrowed from `df` (the frame is shared by
  value; per-row access is `O(1)` and allocates nothing). `filter`
  itself never fails on a well-formed `df`: every row index it
  forwards to `take` is in `[0, nrows)` by construction. The
  `Result` shape is preserved for parity with the other ops so call
  sites chain uniformly. The predicate is **not** invoked on a
  zero-row frame.
- `filter_try(df, predicate : (RowView) -> Result[Bool, DataError]) -> Result[DataFrame, DataError]`
  — fallible variant. The first `Err` the predicate returns
  short-circuits the scan and propagates verbatim; rows accepted
  before the failing row are discarded (no partial frame). Use this
  whenever the predicate calls a fallible `RowView` accessor —
  `get_int` / `get_float` / `get_bool` / `get_string` all return
  `Result[T, DataError]` and surface `ColumnNotFound` on misspelled
  names and `TypeMismatch` on dtype / null mismatches. Wrapping
  those in `match … { Ok(v) => v, Err(_) => false }` would silently
  downgrade real bugs into "row excluded".

### Pending in later phases

- `enum SortOrder` / `enum NullOrder` / `struct SortSpec` —
  (pending, P8)
- `sort_by` / `sort_by_many` — (pending, P8) stable mergesort
- `drop_nulls` / `drop_nulls_in` / `fill_null` / `null_count` — (pending, P9)
- `sum` / `mean` / `min` / `max` / `count` / `describe` — (pending, P10),
  return 1×N DataFrames

---

## `io` — Serialization

> Implemented in **P11** (CSV) and **P12** (Markdown, JSON).

- `struct CsvReadOptions` / `struct CsvWriteOptions` — (pending)
- `read_csv` / `read_csv_with_options` — (pending)
- `write_csv` / `write_csv_with_options` — (pending)
- `DataFrame::to_markdown` / `DataFrame::to_markdown_with_limit` — (pending)
- `DataFrame::to_json_records` — (pending)

---

## Out of scope for v0.1

- `GroupBy`, aggregation specs, free `count` / `sum` / `mean` / `min` /
  `max` functions — deferred to v0.2
- `JoinType`, `JoinOptions`, `inner_join`, `left_join` — deferred to v0.2
- `NumericColumn`, `ColumnStorage` abstraction — deferred to v0.2
- HTML output, chart-data export — deferred to v0.3
- Expression / lazy query API — deferred to v0.4
