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
