# MoonFrame

A lightweight DataFrame and tabular-data library for the MoonBit ecosystem.

MoonFrame provides column-oriented `DataFrame` / `Series` types together with
CSV reading, filtering, sorting, null handling, summary statistics, and
Markdown / JSON export. The goal is not to clone every pandas feature, but
to give MoonBit a small, well-tested, extensible foundation for data
analysis.

## Status

Under active development toward **v0.1**. The current focus is the
`types` / `column` / `frame` / `ops` / `io` layering described in
[`docs/api.md`](docs/api.md). See that document for the authoritative
public-API surface.

v0.1 progress:

- [x] P0 — project skeleton
- [x] P1 — `types/` core (`DataError`, `DataType`, `Scalar`)
- [x] P2 — `column/` `BuiltinColumn` (initial Option-based draft;
      rewritten in P3.5)
- [x] P3 — `types/` `Field` + `Schema` (duplicate-name detection,
      select, rename, index_of)
- [x] P3.5 — `column/` Apache Arrow layout: byte-packed `Bitmap`
      (1 = valid) plus `BuiltinColumn { data, validity }`; typed
      accessors return `(Array[T], Bitmap)` for zero-boxing ops
- [x] P4 — `frame/` `Series` core + stats: 10 constructors,
      inspection / transforms / casts / null handling, plus reductions
      (`count` / `sum` / `mean` / `min` / `max` / `unique_count`).
      `Series::describe` deferred to P5 because it returns a `DataFrame`
- [x] P5 — `frame/` `DataFrame` + `RowView` + `Series::describe`:
      `DataFrame` with an `O(1)` `name_to_index` cache, three
      constructors (`new` / `empty` / `from_rows`), `shape` /
      `schema` / `columns` / `get_column` / `get` / `head` / `tail` /
      `slice` / `take`; `RowView` with `get` / `is_null` /
      `get_int` / `get_float` / `get_bool` / `get_string`
- [x] P6 — `ops/` column ops: `select` / `drop` / `rename` /
      `with_column` / `replace_column` as free functions in `@ops`.
      Ships alongside `DataFrame::check_invariants()` — a formal
      structural specification (INV1–INV6) of a well-formed DataFrame,
      asserted by every op test as the practical equivalent of formal
      verification in MoonBit v0.1
- [x] P7 — `ops/` row filter: `filter` (`(RowView) -> Bool`) and
      `filter_try` (`(RowView) -> Result[Bool, DataError]`). Both
      preserve the input schema verbatim and route the kept rows
      through `DataFrame::take`; `filter_try` short-circuits on the
      first predicate error so a misspelled column or dtype mismatch
      surfaces instead of silently excluding the row
- [ ] P8 – P10 — `ops/`
- [ ] P11 – P12 — `io/` CSV / Markdown / JSON
- [ ] P13 — facade re-exports, integration, examples

GroupBy and Join land in v0.2; NDJSON also v0.2; HTML and chart-data
export in v0.3; an expression / lazy query layer in v0.4.

## Layout

```
moonframe/      facade package — re-exports the public API
types/          value types, errors, schemas
column/         column storage backends
frame/          Series, DataFrame, RowView
ops/            select / filter / sort / null / stats / describe
io/             CSV (NyaCSV-backed), Markdown, JSON
docs/api.md     public API reference (source of truth)
```

Each subpackage carries its sources, its `*_test.mbt` blackbox tests, and
its `pkg.generated.mbti` interface snapshot.

## Building

```sh
moon check     # type-check the workspace
moon test      # run all blackbox tests
moon info      # regenerate per-package .mbti interfaces
moon fmt       # format sources
```

## Dependencies

- [`xunyoyo/NyaCSV`](https://mooncakes.io/docs/xunyoyo/NyaCSV) — CSV parser
- [`moonbitlang/x`](https://mooncakes.io/docs/moonbitlang/x) — extra
  standard-library utilities (`@fs` for filesystem I/O)

## License

Apache-2.0 — see [LICENSE](LICENSE).
