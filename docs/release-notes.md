# MoonFrame v0.3.0 — Release Notes

_2026-06-08_

MoonFrame v0.3.0 grows the library's user-facing **output surface**, completes
the **join matrix**, and adds engineering depth with a **pluggable
column-storage backend** — all on top of the v0.2 method-chain core. Pre-1.0,
breaking changes ride the minor version (see [Breaking changes](#breaking-changes)).

## Highlights

- **HTML & Vega-Lite export** — render a frame as a styled `<table>` or a
  Vega-Lite v5 chart spec you can paste straight into the Vega editor.
- **Full join matrix** — `right` / `outer` complete the
  `inner` / `left` / `right` / `outer` / `cross` set.
- **Read resilience** — the CSV / JSON / NDJSON readers gained escape hatches
  for messy, real-world data.
- **Pluggable column storage** — an all-valid `Numeric` fast path alongside the
  general-purpose Arrow `Builtin` column, behind a closed `ColumnStorage` seam.
- **Faster group-by / join and O(1) slicing** under the hood.

## What's new

### Output formats

- **`DataFrame::to_html()` / `to_html_with_options(...)`** — a pure,
  dependency-free renderer (CSS `class`, `<caption>`, a `max_rows` cap, and
  HTML escaping by default), parallel to `to_markdown`.
- **`format_vega_lite(df, spec)` / `write_vega_lite(...)`** — a complete
  Vega-Lite v5 spec (`$schema` + `mark` + `encoding` + inline `data.values`).
  `ChartSpec::bar` / `line` / `point` / `area`, with `with_color` / `with_title`.

### Join — Right / Outer

`JoinType` gained `Right` and `Outer`, completing the matrix, with `right_join`
/ `outer_join` convenience methods and Polars-aligned semantics (null keys match
nothing; `NaN` keys match; per-`how` coalesce defaults, overridable with
`with_coalesce`).

### Read resilience

`infer_schema_rows = 0` scans *every* row instead of a leading window;
`on_parse_error` (`Raise` / `Null`) chooses whether an off-type cell past the
window fails the read or downgrades to null; CSV's `allow_nonfinite_floats`
controls whether `nan` / `inf` tokens infer as `Float` or fall back to `String`.

### Pluggable column storage

A `Series` now holds a `ColumnStorage` — a closed `{ Builtin; Numeric }` seam.
`Numeric` is an all-valid, unboxed `Int64` / `Double` column with **no validity
bitmap** (the `null_count == 0` fast path); `from_ints` / `from_floats` pick it
automatically, and structural transforms keep a column on the fast path.
`storage_kind()` / `to_numeric()` / `to_builtin()` inspect and convert.

## Performance

- **group-by / join keys** are now hashed on native cell values — no per-row
  string key, and no decimal-string round-trip for numeric keys.
- **Bitmap slicing is `O(1)`** — `head` / `tail` / `slice` share the parent's
  validity buffer (a zero-copy view) instead of repacking it.

## Breaking changes

Pre-1.0, breaking changes ride the minor version. The source-level breaks:

- `Series::storage()` now returns `@column.ColumnStorage` (was
  `@column.BuiltinColumn`). The `.data()` / `.validity()` reading surface is
  unchanged, so column-reading call sites still compile; use `.to_builtin()`
  for the concrete `BuiltinColumn`.
- `Series::new(name, ...)` takes a `ColumnStorage` (pass
  `ColumnStorage::from_builtin(col)`, or use the unchanged
  `Series::from_builtin`).
- `JoinType` gained `Right` / `Outer` — an exhaustive `match` over it must now
  handle the two new variants.
- The CSV / JSON / NDJSON `*ReadOptions` structs gained `pub(all)` fields; a
  full struct literal must add them or switch to `::default()` (the defaults
  reproduce the prior behaviour exactly).

Step-by-step upgrade notes are in [`migration.md`](migration.md).

## Upgrade

MoonFrame isn't on mooncakes.io yet, so update your local clone and rebuild:

```sh
git -C path/to/MoonFrame pull
```

(or re-point your `moon.mod.json` local-path dependency at the v0.3 sources),
then apply the [migration steps](migration.md).

## Quality

This release holds the project's bar: **100% line coverage**, a warning-free
`moon check --deny-warn`, and the full test suite green on all four backends
(wasm / wasm-gc / js / native).

## What's next

v0.4: an expression / lazy query layer.

---

Full per-feature detail is in the [changelog](changelog.md); the complete public
surface is in [`api.md`](api.md).
