# MoonFrame v0.1 — Public API

> Status: **skeleton only.** This document is the source of truth for the
> v0.1 public surface. Each phase fills in its section as it ships.
> When a symbol is published in code, it must appear here.

Re-exported from the facade package `ihb2032/MoonFrame`. Sub-packages
(`types`, `column`, `frame`, `ops`, `io`) are also importable directly.

---

## `types` — Value types and errors

> Implemented in **P1** (`error.mbt`, `dtype.mbt`, `scalar.mbt`) and
> **P3** (`field.mbt`, `schema.mbt`).

- `enum DataError` — variants for column lookup, dtype mismatch,
  length mismatch, bounds, parse errors, I/O errors, unsupported ops
- `enum DataType` — `Int | Float | Bool | String | Null`, with
  `is_numeric` / `is_integer` / `is_float` / `is_string` / `is_bool`
- `enum Scalar` — cell value; `dtype`, `is_null`, `as_*` accessors,
  total/partial comparisons
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

> Implemented in **P2** (`builtin.mbt`).

- `enum BuiltinColumn` — `Int(Array[Int?]) | Float(Array[Double?]) |
  Bool(Array[Bool?]) | String(Array[String?])`. `None` denotes a null
  cell. Single-backend v0.1 storage; v0.2 will add a `ColumnStorage`
  abstraction over this enum.
- Constructors (8): `from_ints` / `from_int_options` /
  `from_floats` / `from_float_options` / `from_bools` /
  `from_bool_options` / `from_strings` / `from_string_options`.
- Inspection: `dtype` / `len` / `is_empty` / `null_count` /
  `is_null(i)` / `get(i)`. Index-based accessors return
  `Err(IndexOutOfBounds(i))` outside `[0, len)`.
- Sub-views: `slice(start, end)` (half-open, copy) / `take(indices)`
  (gather with duplicates allowed; first out-of-bounds index wins).
- Cast: `cast(target)` dispatches to one of
  - `to_int` — identity on Int; Float truncates towards zero; Bool maps
    `true → 1`, `false → 0`; String parses (non-numeric →
    `ParseError`).
  - `to_float` — Int promoted; identity on Float; Bool maps to `1.0` /
    `0.0`; String parses (non-numeric → `ParseError`).
  - `to_string_column` — every dtype rendered with `Scalar::to_string`
    semantics (e.g. `Int(42) → "42"`, `Bool(true) → "true"`).
  - `Bool` / `Null` targets return `Err(Unsupported)`.
- Typed accessors (zero-boxing fast path for ops): `int_values` /
  `float_values` / `bool_values` / `string_values` return
  `Result[Array[T?], DataError]`. Wrong dtype → `Err(TypeMismatch)`.

---

## `frame` — Series, DataFrame, RowView

> Implemented in **P4** (Series) and **P5** (DataFrame, RowView).

- `struct Series` — (pending) named column wrapping `BuiltinColumn`
- `struct DataFrame` — (pending) collection of `Series` with shared `Schema`
- `struct RowView` — (pending) lightweight per-row accessor used by `filter`

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
