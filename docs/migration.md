# Migration guide

Source-level breaking changes between MoonFrame releases. Pre-1.0, breaking
changes ride the minor version. For the feature history behind each release see
[`changelog.md`](changelog.md); for the current public surface see
[`api.md`](api.md).

## v0.2 → v0.3

v0.3 is a pre-1.0 breaking release. The source-level breaks:

| v0.2 | v0.3 |
|---|---|
| `Series::storage() -> @column.BuiltinColumn` | `-> @column.ColumnStorage`; the `.data()` / `.validity()` reading surface is unchanged, so column-reading call sites still compile. Use `.to_builtin()` when you need the concrete `BuiltinColumn` |
| `Series::new(name, BuiltinColumn)` | `Series::new(name, ColumnStorage)`; pass `ColumnStorage::from_builtin(col)`, or keep `Series::from_builtin(name, col)` (signature unchanged) |
| `pub(all) enum JoinType { Inner; Left; Cross }` | gained `Right` / `Outer`; an exhaustive `match` over `JoinType` must now handle the two new variants |

The CSV / JSON / NDJSON `*ReadOptions` structs also gained `pub(all)` fields
(read resilience — `on_parse_error`, plus CSV's `allow_nonfinite_floats`): a
full struct literal must add them or switch to `::default()`. The defaults
reproduce the prior behaviour exactly.

## v0.1 → v0.2

| v0.1 | v0.2 |
|---|---|
| `@ops.select(df, names)` (free function) | `df.select(names)` (method) |
| `op(df, ...) -> Result[T, DataError]` + `.bind` / `.map` / `.unwrap` | `df.op(...) -> T raise DataError`, chained directly |
| pattern-match `Ok(x)` / `Err(e)` on the result | call directly in a `raise` context, or `try? expr` for a `Result` |
| `filter_try(df, row => row.get_int("x").map(v => v > 0))` | `df.filter(row => row.get_int("x") > 0)` |
| `sort_by(df, spec)` / `sort_by_many(df, specs)` | `df.sort_by([(col, order, nulls), ...])` |
| `Series::min()` / `max()` (`Result`-wrapped) | `Series::min_value()` / `max_value()` (total) |
| `@io.to_markdown(df)` | `df.to_markdown()` |
| `import ... @ops` | gone — verbs live on `DataFrame` in `@frame` |

`format_csv_str` / `format_json_records` / `parse_csv_str` / `read_csv` /
`write_csv` and the JSON / NDJSON equivalents are still `io` free functions (the
`read_*` / `write_*` / `parse_*` ones now `raise`; the `format_*` ones are total
and return a `String`).
