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

- `enum DataError` — (pending) variants for column lookup, dtype mismatch,
  length mismatch, bounds, parse errors, I/O errors, unsupported ops
- `enum DataType` — (pending) `Int | Float | Bool | String | Null`, with
  `is_numeric` / `is_integer` / `is_float` / `is_string` / `is_bool`
- `enum Scalar` — (pending) cell value; `dtype`, `is_null`, `as_*` accessors,
  total/partial comparisons
- `struct Field` — (pending) column metadata: `name`, `dtype`, `nullable`
- `struct Schema` — (pending) ordered list of `Field`s with duplicate-name
  detection

---

## `column` — Column storage backends

> Implemented in **P2** (`builtin.mbt`).

- `enum BuiltinColumn` — (pending) `Int | Float | Bool | String` over
  `Array[Option[T]]`; eight `from_*` constructors, typed accessors for
  zero-boxing iteration

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
