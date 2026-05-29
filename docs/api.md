# MoonFrame v0.1 — Public API

> Status: **complete** (P13 shipped). This document is the source of
> truth for the v0.1 public surface. Each phase filled in its section
> as it shipped; the facade re-exports them all in one place.
> When a symbol is published in code, it must appear here.

The facade package `ihb2032/MoonFrame` re-exports every symbol below
via `pub using @<subpkg> { ... }`, so a single
`import "ihb2032/MoonFrame" @moonframe` is enough to reach the whole
v0.1 surface. Sub-package imports (`@types`, `@column`, `@frame`,
`@ops`, `@io`) remain supported for callers that only need a slice —
the facade is additive.

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
- `enum Scalar` — cell value (`Int` carries `Int64`, `Float` carries
  `Double`); `dtype` / `is_null` / `to_string` (value
  form, e.g. `Int(42) → "42"`, `Null → ""`) / `as_int` / `as_float` /
  `as_bool` / `as_string` accessors; total ordering via `eq` / `lt` /
  `lte` / `gt` / `gte` (each returns `Result[Bool, DataError]` so that
  `Null` short-circuits to `Err(TypeMismatch)`). `String` comparisons
  use lexicographic order (see `compare_string_lex`), **not** the
  built-in shortlex `<`.
- `fn compare_string_lex(a, b) -> Int` — lexicographic string comparison
  by UTF-16 code unit (`-1` / `0` / `1`). MoonBit's built-in `<` on
  `String` is *shortlex* (length first), which surprises pandas / SQL
  users; every user-facing ordering (`Scalar::lt`, `Series::min` /
  `max`, `@ops.sort_by`) routes through this helper so they all agree.
- `fn is_decimal_int_literal(s) -> Bool` — `true` when `s` is an optional
  `+` / `-` sign followed by ASCII digits and nothing else (rejects
  `0x` / `0o` / `0b` base prefixes and `1_000` underscore grouping). The
  CSV / JSON readers' type inference and the `@column` String→`Int` cast
  both route through this predicate so they agree on what counts as an
  integer literal — `@string.parse_int` defaults to `base = 0` and would
  otherwise accept those forms.
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
- `pub(all) enum ColumnData` — `Int(Array[Int64]) | Float(Array[Double]) |
  Bool(Array[Bool]) | String(Array[String])`. Numeric columns are 64-bit
  (`Int64` / `Double`), matching `Scalar` and the pandas / polars
  `int64` / `float64` defaults. Element type is the raw value;
  nullability lives on the enclosing column.
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
    `±Inf`, and values outside `Int64` range → `ParseError`); Bool maps
    `true → 1`, `false → 0`; String accepts only plain base-10 integers
    (optional `+` / `-` sign then digits) — `0x` / `0o` / `0b` prefixes,
    `1_000` underscore grouping, and `Int64` overflow → `ParseError`,
    matching the CSV reader's inference.
  - `to_float` — Int promoted via `Int64::to_double`; identity on
    Float; Bool maps to `1.0` / `0.0`; String parses with
    `@string.parse_double`. `1_000`-style underscore grouping →
    `ParseError` (matching the CSV reader); `inf` / `-inf` / `nan`
    literals are accepted.
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
  `0.0`). `Bool` / `String` → `Err(TypeMismatch)`. `Int` sums accumulate
  in 64-bit `Int64` (only sums past 2^63 overflow); `Float` sums
  accumulate in 64-bit `Double`. `NaN` cells are skipped (treated as
  missing, like `min` / `max` and `@ops.sort_by`).
- `mean()` — `Double` result. Reductions run in 64-bit (an `Int64` sum
  for `Int` columns, `Double` accumulation for `Float` columns) and the
  division is performed in `Double`, so a long column stays accurate.
  `Float` skips `NaN`, dividing by the non-NaN count. Empty / all-null /
  all-NaN numeric → `Err(InvalidOperation)`. Non-numeric →
  `Err(TypeMismatch)`.
- `min()` / `max()` — supported on every dtype; empty / all-null returns
  `Ok(Scalar::Null)`. `Float` NaN is treated as missing (skipped),
  matching `@ops.sort_by` and pandas, so an all-NaN / all-null series
  returns `Ok(Scalar::Null)`. `String` uses lexicographic order
  (`@types.compare_string_lex`, by UTF-16 code unit), **not** the
  built-in shortlex `<`. `Bool` order is `false < true`.
- `unique_count()` — distinct non-null values, keyed by
  `Scalar::to_string`. Within a fixed-dtype series this is a precise
  equality test; all `Float` `NaN` cells collapse into a single bucket
  (matching pandas' `nunique` on NaN).

- `describe()` — one-row summary `DataFrame`. Every series gets
  `count` / `null_count` / `unique_count` (`Int`). Numeric series add
  `mean` (`Double`, `Null` for empty / all-null). All dtypes add `min`
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

### Sort (P8)

Row reordering by one or more sort keys. The sort routes its result
through `DataFrame::take`, so the schema (names, dtypes, order) is
preserved verbatim and every output passes `check_invariants()`.

- `enum SortOrder` — `Asc` (smaller first) / `Desc` (larger first).
  The direction applies to every dtype: `Int` / `Float` use numeric
  ordering, `Bool` uses `false < true`, `String` uses lexicographic
  comparison by UTF-16 code unit. MoonBit's built-in `<` on `String`
  is *shortlex* (length first), which would surprise callers used to
  pandas / polars / SQL ordering; the sort intentionally bypasses it.
- `enum NullOrder` — `NullsFirst` / `NullsLast`. Governs where
  "missing" cells go relative to non-missing ones. For `Float`
  columns, `NaN` is treated identically to `Null` for ordering
  (IEEE 754 would otherwise scatter NaNs unpredictably since `<` /
  `>` against NaN return `false`); the validity bit on a NaN cell is
  unchanged, so reading the cell back still yields `Scalar::Float`.
- `struct SortSpec` — a single sort key. Fields are private; build via
  the constructors below.
  - `SortSpec::asc(column)` — ascending order, `NullsLast` default
    (matching pandas / polars).
  - `SortSpec::desc(column)` — descending order, `NullsLast` default
    (the dimension that flips is value ordering, not null placement).
  - `SortSpec::with_null_order(null_order)` — override the null
    placement; chainable, last call wins.
- `sort_by(df, spec) -> Result[DataFrame, DataError]` — single-key
  convenience over `sort_by_many(df, [spec])`.
- `sort_by_many(df, specs) -> Result[DataFrame, DataError]` —
  lexicographic multi-key sort. Earlier specs dominate; later specs
  only break ties between rows that compare equal under all earlier
  keys. The implementation is a bottom-up **stable mergesort** on row
  indices, so rows that tie under every key keep their original
  relative order. Empty `specs` is the identity sort. The only error
  path is `Err(ColumnNotFound(name))` for an unknown spec column —
  every column in a `DataFrame` is `Int` / `Float` / `Bool` / `String`
  by construction, so a successful lookup always yields a sortable
  column.

### Null handling (P9)

DataFrame-level null operations. Per-cell null logic delegates to
`Series::drop_nulls` / `Series::fill_null` / `Series::null_count`; the
ops here lift those into row-coordinated transforms (a row that fails
the null gate in *any* column drops as a whole) and into a summary
table for inspection.

- `drop_nulls(df) -> Result[DataFrame, DataError]` — drop every row in
  which **any** column carries a null. Routes through
  `drop_nulls_in(df, df.columns())` so the gating logic is single-sourced.
  A 0-column frame has no columns to gate on and stays structurally
  identical to the input; a 0-row frame is a no-op that preserves the
  schema. The `Result` shape is preserved for parity with other ops —
  `drop_nulls` itself cannot fail on a well-formed input.
- `drop_nulls_in(df, names) -> Result[DataFrame, DataError]` — drop
  rows whose nulls fall in any of the listed columns. Other columns
  are not consulted, so a row with a null in an *unlisted* column can
  still survive (and its cell still reads back as `Scalar::Null` — no
  cell rewriting). Duplicates in `names` are tolerated (idempotent
  gating); an empty `names` list is a no-op identity.
  `Err(ColumnNotFound(name))` on the first unknown entry.
- `fill_null(df, column, value : Scalar) -> Result[DataFrame, DataError]`
  — replace every null cell in the named column with `value`. The
  column's dtype is preserved — `value`'s dtype must match. Errors:
  `Err(ColumnNotFound(column))` for unknown names;
  `Err(TypeMismatch(...))` for `Scalar::Null` fills or for a
  dtype-mismatched scalar (both bubble unchanged from
  `Series::fill_null`, so the diagnostic text matches the Series API).
  Column-lookup runs before the fill so a missing name is surfaced
  ahead of a type-mismatch error. Other columns and the schema's
  column order are untouched.
- `null_count(df) -> DataFrame` — per-column summary as a `1 × ncols`
  frame. Column names mirror `df.columns()` in order; every cell is
  an `Int` count of nulls in the source column. The 0-column case
  collapses to `0 × 0` — `DataFrame::new`'s "empty column list ⇒
  nrows = 0" rule kicks in and there's no anchor column to set `nrows`
  on. A 0-row source produces a `(1, ncols)` summary of all zeros.
  Total — cannot fail (column names from `df.columns()` are unique
  and every output column has length 1).

### Column statistics + describe (P10)

Free-function reductions on a single column and a per-frame summary
table. The reductions delegate to the matching `Series` stats via a
shared `dispatch_stat` helper, so per-dtype semantics (null skipping,
empty / all-null fallbacks, `Float` NaN handling, `Bool` / `String`
rejection for numeric ops) match the Series API exactly. `describe`
materialises one row per source column into a fixed-shape result so
the summary itself is a regular `DataFrame` callers can chain through
further ops or IO.

- `count(df, column) -> Result[Int, DataError]` — non-null cell count.
  `Series::count` is total, so the only failure path is
  `Err(ColumnNotFound(column))`.
- `sum(df, column) -> Result[Scalar, DataError]` — additive reduction.
  `Int` / `Float` columns return `Scalar::Int` / `Scalar::Float`;
  empty / all-null numeric is the additive identity (`0` / `0.0`).
  Errors: `Err(ColumnNotFound(column))` for unknown names,
  `Err(TypeMismatch(...))` for `Bool` / `String` columns.
- `mean(df, column) -> Result[Double, DataError]` — arithmetic mean,
  `Double`-typed (`Int` sums promoted). Errors:
  `Err(ColumnNotFound(column))` for unknown names,
  `Err(InvalidOperation(...))` for empty / all-null numeric columns,
  `Err(TypeMismatch(...))` for non-numeric columns.
- `min(df, column) -> Result[Scalar, DataError]` /
  `max(df, column) -> Result[Scalar, DataError]` — supported on every
  dtype; delegate to `Series::min` / `max`. Empty / all-null columns
  return `Ok(Scalar::Null)`. `Float` NaN is skipped (treated as missing,
  matching `sort_by`); `String` uses lexicographic order; `Bool` order
  is `false < true`. The only failure path is
  `Err(ColumnNotFound(column))`.
- `describe(df) -> DataFrame` — per-column summary, one row per source
  column. Fixed `N × 8` schema (`N == df.ncols()`); column dtypes are
  pinned regardless of the source frame:
  - `column` (`String`) — source column name, in declaration order
  - `dtype` (`String`) — source column dtype rendered via `Show`
  - `count` (`Int`) — non-null cell count
  - `null_count` (`Int`) — null cell count
  - `unique_count` (`Int`) — distinct non-null values
    (`Scalar::to_string` keying, so `Float` NaN collapses to one bucket)
  - `mean` (`Double`, nullable) — arithmetic mean for numeric columns;
    `Null` for non-numeric or empty / all-null numeric (both `mean`
    error modes collapse into the same null cell — the diagnostic
    distinction stays at the per-column API)
  - `min` (`String`, nullable) — minimum rendered via
    `Scalar::to_string`; `Null` for empty / all-null columns
  - `max` (`String`, nullable) — maximum rendered via
    `Scalar::to_string`; `Null` for empty / all-null columns

  `min` / `max` are stored as `String` so the summary can carry
  extrema for every source dtype in a single column without forcing
  a uniform value type. Callers that need a typed extremum should use
  `@ops.min` / `@ops.max` directly. `describe` is total — every
  well-formed `df` produces a well-formed result; a 0-column frame
  collapses to a `0 × 8` result so downstream code can still rely on
  the schema.

---

## `io` — Serialization

> Implemented in **P11** (CSV) and **P12** (Markdown, JSON).

### CSV (P11)

Read and write CSV text against a `DataFrame`. Two layers ship: a
string-in / string-out core (`parse_csv_str`, `format_csv_str`) so
callers that already hold the bytes can stay off the file system, plus
file-backed wrappers (`read_csv*`, `write_csv*`) that delegate to
`moonbitlang/x/fs` and surface its `IOError` as
`Err(DataError::IoError(message))`. The tokeniser is
`moonbit-community/NyaCSV`;
v0.1's contribution is type inference, null mapping, header
toggling, and quoting.

- `struct CsvReadOptions` — `has_header` / `delimiter` /
  `infer_schema_rows` / `null_values`.
  - `has_header` — when `true` (default), the first row supplies
    column names. When `false`, every row is data and column names
    are synthesised as `"column1"`, `"column2"`, … in declaration
    order.
  - `delimiter` — field separator passed straight through to NyaCSV.
    Default `','`.
  - `infer_schema_rows` — number of leading rows scanned when
    inferring each column's dtype (default `100`). Cells past the
    limit are parsed under the chosen dtype, so a cell that doesn't
    fit surfaces as `ParseError` rather than silently dropping the
    column to `String`.
  - `null_values` — raw strings to treat as null (default `[""]`).
    Null cells are skipped during inference and become `None` in
    the typed column.
  - `CsvReadOptions::default()` — the defaults above.
- `struct CsvWriteOptions` — `header` / `delimiter` / `null_value`.
  - `header` — when `true` (default), the first emitted row is the
    column names. When `false`, only data rows are written.
  - `delimiter` — field separator written between cells. Default
    `','`.
  - `null_value` — literal string for null cells (default `""`).
    Round-trips with the reader's default `null_values`.
  - `CsvWriteOptions::default()` — the defaults above.
- `parse_csv_str(content, options) -> Result[DataFrame, DataError]`
  — string entry point. The pipeline is:
  1. NyaCSV tokenises the text. NyaCSV always lifts the first row
     into the header position; when `has_header = false`, we fold
     it back into the data section and synthesise column names.
  2. Per-column inference walks the first `infer_schema_rows`
     non-null cells in order `Int → Float → Bool → String`. The
     first dtype that accepts every probed cell wins; a column with
     no non-null probes lands on `String`. `Int` / `Float` accept
     only plain base-10 numbers: `0x` / `0o` / `0b` prefixes and
     underscore grouping (`1_000`) are **rejected** and kept as
     `String` (matching pandas / polars), while the `Float` literals
     `inf` / `-inf` / `nan` are accepted as ±Infinity / NaN values.
     A decimal integer that overflows `Int64` falls through to
     `Float`.
  3. Null mapping replaces any cell whose raw text sits in
     `null_values` with `None`. Both quoted empty cells (`""`) and
     bare empty cells are honoured.
  4. Each column is wrapped as a `Series` and assembled through
     `DataFrame::new`.
  - Errors:
    - `Err(DuplicateColumn(name))` — two headers share a name.
    - `Err(ParseError(...))` — a non-null cell does not parse under
      its column's inferred dtype (typically because a later cell
      contradicts the inference window).
    - `Err(DataError::IoError(_))` is **not** produced by
      `parse_csv_str` — it's reserved for the file-backed wrappers.
- `format_csv_str(df, options) -> String` — string exit point. Cells
  render via `Scalar::to_string`; null cells use `options.null_value`.
  Cells / headers that contain `options.delimiter`, a double quote,
  CR, or LF are wrapped in double quotes, with interior `"` doubled
  per RFC 4180. Lines are terminated with LF (`\n`).
- `read_csv(path)` / `read_csv_with_options(path, options)` — file
  wrappers around `parse_csv_str`. Read errors from the underlying
  `moonbitlang/x/fs` surface as `Err(DataError::IoError(message))`.
- `write_csv(path, df)` / `write_csv_with_options(path, df, options)`
  — file wrappers around `format_csv_str`. Write errors surface as
  `Err(DataError::IoError(message))`. `write_csv*` returns
  `Result[Unit, DataError]`.

### Markdown (P12)

Render a `DataFrame` as a GitHub-flavored pipe-table. The renderer is
in-tree (no third-party Markdown library) and produces deterministic
bytes for a given frame, so callers can pin output via exact-string
assertions. Null cells render as the empty string, matching
`Scalar::to_string`. Cell values and column names are GFM-escaped: a
literal backslash is doubled (`\` → `\\`), a literal `|` becomes `\|`,
and CR / LF collapse to a single space, so data containing backslashes,
pipes, or newlines can't corrupt the table structure (column widths are
measured on the escaped text).

- `to_markdown(df) -> String` — three blocks of pipe-bounded rows:
  header (column names), separator (dashes), and one row per record
  in declaration order. Column widths are
  `max(header, every rendered cell)` with a 3-character minimum so
  the separator never collapses below the GFM-required floor.
  An empty 0-column frame returns the empty string; a 0-row frame
  with N columns returns header + separator only.
- `to_markdown_with_limit(df, limit) -> String` — same renderer but
  capped at the first `limit` rows. If `df.nrows() > limit`, the
  output appends `... (N more rows)` after the table. Negative
  `limit` is clamped to 0 (header + separator + banner).

### JSON (P12)

Records-shape JSON (`[{...}, ...]`) round-trips a `DataFrame` against
the builtin `@json` package, so string escaping / `NaN` / `Infinity`
rendering / number formatting follow the standard library. The
reader's dtype inference mirrors `parse_csv_str`
(`Int → Float → Bool → String`) — the same CSV→JSON pipeline lands on
the same dtypes.

- `struct JsonReadOptions` — `infer_schema_rows` (default `100`).
  - `JsonReadOptions::default()` — the defaults above.
- `parse_json_records_str(content, options) -> Result[DataFrame, DataError]`
  — string entry point. Pipeline:
  1. `@json.parse` produces a `Json` AST. Anything other than a
     top-level array surfaces as `Err(ParseError(...))`.
  2. Every element must be a `Json::Object`; the underlying map is
     extracted once so downstream passes can index by name without
     re-matching the variant.
  3. Headers are collected in first-seen order across **all** records
     (not just the first), so a sparse record set still produces
     every column the data contains. Missing fields on a record
     become null cells.
  4. Per-column dtype inference walks the first `infer_schema_rows`
     non-null cells in priority order `Int → Float → Bool → String`.
     `Number` cells lock to Int when `n == n.trunc()` and the value
     fits `[Int::MIN, Int::MAX]`, otherwise Float — the same `1.0e2`
     handling pandas uses. The Bool candidate accepts only JSON
     `true` / `false` (numeric `0` / `1` round-trip as Int, matching
     `parse_csv_str`). Mixed dtype within a single column collapses
     to the String fallback, with numeric / boolean cells
     re-serialised via `Double::to_string` / `"true"` / `"false"`
     and nested arrays / objects round-tripped through
     `@json.stringify`. An all-null probe window defaults to String
     (same rule as the CSV reader).
  5. Each column is wrapped as a `Series` and assembled through
     `DataFrame::new`.
  - Errors:
    - `Err(ParseError(...))` — malformed JSON, top-level not an
      array, a record that is not an object, or a non-null cell that
      contradicts the column's inferred dtype (typed mismatch past
      the inference window).
    - `Err(DataError::IoError(_))` is **not** produced by
      `parse_json_records_str` — it's reserved for the file wrappers.
- `format_json_records(df) -> String` — string exit point. Each row
  becomes a JSON object whose keys appear in `df.columns()` order
  (preserved by the builtin linked-hash-map `Map`). Per cell:
  `Null → null`; `Int` / `Float → number` (`Int64` widened to `Double`;
  `Float` is already `Double`); `Bool → true` / `false`; `String → JSON
  string`
  with escaping delegated to the stringifier. Output is the compact
  form `@json.stringify` produces by default (no spaces between
  tokens).
- `read_json(path)` / `read_json_with_options(path, options)` — file
  wrappers around `parse_json_records_str`. Filesystem errors from
  `moonbitlang/x/fs` surface as `Err(DataError::IoError(message))`.
- `write_json_records(path, df)` — file wrapper around
  `format_json_records`. Returns `Result[Unit, DataError]`; write
  errors surface as `Err(DataError::IoError(message))`.

---

## `moonframe` — Facade package

> Implemented in **P13** (`moonframe.mbt`). Every symbol listed
> above is re-exported from this package via `pub using` so callers
> can reach the whole v0.1 surface through one import; the facade
> adds no symbols of its own. Sub-package imports remain supported.

### From `@types`

`type DataError` · `type DataType` · `type Scalar` · `type Field` ·
`type Schema`

### From `@column`

`type Bitmap` · `type BuiltinColumn` · `type ColumnData`

### From `@frame`

`type Series` · `type DataFrame` · `type RowView`

### From `@ops`

`type SortOrder` · `type NullOrder` · `type SortSpec` ·
`count` · `describe` · `drop` · `drop_nulls` · `drop_nulls_in` ·
`fill_null` · `filter` · `filter_try` · `max` · `mean` · `min` ·
`null_count` · `rename` · `replace_column` · `select` · `sort_by` ·
`sort_by_many` · `sum` · `with_column`

### From `@io`

`type CsvReadOptions` · `type CsvWriteOptions` ·
`type JsonReadOptions` · `format_csv_str` · `format_json_records` ·
`parse_csv_str` · `parse_json_records_str` · `read_csv` ·
`read_csv_with_options` · `read_json` · `read_json_with_options` ·
`to_markdown` · `to_markdown_with_limit` · `write_csv` ·
`write_csv_with_options` · `write_json_records`

> `using @pkg { type T }` automatically creates constructor aliases,
> so `@moonframe.Scalar::Int(42)`, `@moonframe.SortSpec::desc("x")`,
> `@moonframe.DataError::ColumnNotFound("y")` etc. all resolve
> through the facade without an additional re-export entry.

---

## Out of scope for v0.1

- `GroupBy`, aggregation specs, free `AggKind` / `AggSpec` constructors
  (the `count` / `sum` / `mean` / `min` / `max` AggSpec variants — the
  free reduction functions land in P10 above) — deferred to v0.2
- `JoinType`, `JoinOptions`, `inner_join`, `left_join` — deferred to v0.2
- `NumericColumn`, `ColumnStorage` abstraction — deferred to v0.2
- HTML output, chart-data export — deferred to v0.3
- Expression / lazy query API — deferred to v0.4
