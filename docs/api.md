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

> **Deferred:** `Series::describe` is listed in the plan but returns a
> 1×N `DataFrame`, so it lands together with the DataFrame surface in
> P5.

### DataFrame / RowView

- `struct DataFrame` — (pending, P5) collection of `Series` with shared `Schema`
- `struct RowView` — (pending, P5) lightweight per-row accessor used by `filter`

---

## `ops` — Operations

> Implemented in **P6 – P10**. One operator per file.

- `select` / `drop` / `rename` / `with_column` / `replace_column` — (pending, P6)
- `filter` / `filter_try` — (pending, P7)
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
