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
- [x] P8 — `ops/` sort: `SortOrder` / `NullOrder` / `SortSpec` plus
      `sort_by` (single key) and `sort_by_many` (lexicographic
      multi-key). Stable bottom-up mergesort on row indices, then a
      single `DataFrame::take` to reorder — so the schema is preserved
      verbatim and `check_invariants()` holds on every result. NaN in
      `Float` columns is treated identically to `Null` for ordering,
      and `String` keys sort lexicographically by UTF-16 code unit
      (not MoonBit's built-in shortlex `<`)
- [x] P9 — `ops/` null handling: `drop_nulls` (drop rows with any
      null) / `drop_nulls_in` (gate on a column subset) /
      `fill_null(df, column, value)` (per-column, dtype-preserving) /
      `null_count(df)` (per-column summary as a `1 × ncols` `Int`
      frame). Row-coordinated ops route through `DataFrame::take`;
      `fill_null` reuses the underlying `Series::fill_null` so dtype
      mismatches surface the same diagnostic
- [x] P10 — `ops/` column statistics + describe:
      `count` / `sum` / `mean` / `min` / `max` as free functions taking
      `(df, column)` and delegating to the matching `Series` reduction
      via a shared `dispatch_stat` helper, so per-dtype semantics
      (null skipping, empty-series fallbacks, `Float` NaN handling,
      `Bool` / `String` rejection for numeric ops) stay in lock-step
      with the Series API. `describe(df)` returns a fixed `N × 8`
      summary — one row per source column with `column` / `dtype` /
      `count` / `null_count` / `unique_count` / `mean` / `min` / `max`;
      `min` and `max` render via `Scalar::to_string` so the summary
      can carry extrema for any dtype in a single column
- [x] P11 — `io/` CSV: `parse_csv_str` / `format_csv_str` as the
      string-in / string-out core, plus file wrappers `read_csv` /
      `read_csv_with_options` / `write_csv` / `write_csv_with_options`
      around `moonbitlang/x/fs`. Tokenisation delegates to
      `moonbit-community/NyaCSV`; v0.1's contribution is per-column type
      inference (`Int → Float → Bool → String`), configurable null
      mapping via `CsvReadOptions::null_values`, header on/off
      handling, and RFC 4180 quoting on the writer. Filesystem errors
      surface as `Err(DataError::IoError(_))`
- [x] P12 — `io/` Markdown + JSON: `to_markdown` /
      `to_markdown_with_limit` render a GFM pipe-table (column-width
      aligned, 3-char dash minimum, null as the empty string, optional
      `... (N more rows)` truncation banner). `format_json_records` /
      `write_json_records` emit records-shape JSON
      (`[{...}, ...]`) via the builtin `@json` package, so escaping
      and `NaN` / `Infinity` rendering follow the standard library.
      `parse_json_records_str` / `read_json` /
      `read_json_with_options` + `JsonReadOptions` parse records back
      with the same `Int → Float → Bool → String` inference the CSV
      reader uses; sparse records are tolerated (missing fields →
      null, late-appearing columns still surface)
- [x] P13 — facade re-exports + integration tests + runnable
      examples: `moonframe.mbt` re-exports every v0.1 public symbol
      from the five sub-packages via `pub using`, so callers can
      `import "ihb2032/MoonFrame" @moonframe` and reach the whole
      surface as `@moonframe.DataFrame` / `@moonframe.parse_csv_str`
      / `@moonframe.SortSpec::desc(...)` / etc. Sub-package imports
      (`@types` / `@column` / `@frame` / `@ops` / `@io`) remain
      supported for callers who only need a slice. A
      `pipeline_test.mbt` exercises every layer through the facade
      (read → filter → select → sort → describe → markdown) so a
      missing re-export surfaces as a compile error instead of a
      silent gap. Two runnable examples ship under `examples/`:
      `sales_analysis` (widgets-only filter + sort + describe) and
      `data_cleaning` (null gating + fill + CSV round-trip). Each
      example splits its logic into a library sub-package with full
      blackbox tests; the `main.mbt` orchestrator is
      `#coverage.skip`-marked since the meaningful behaviour lives
      in the tested helpers

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

## Usage

```moonbit
// One import covers the whole v0.1 surface — the facade re-exports
// every public symbol from types / column / frame / ops / io.
import "ihb2032/MoonFrame" @moonframe

fn run(
  path : String,
) -> Result[String, @moonframe.DataError] {
  @moonframe.read_csv(path)
    .bind(df => @moonframe.filter_try(df, row =>
      row.get_string("product").map(name => name == "widget")))
    .bind(widgets => @moonframe.sort_by(
      widgets,
      @moonframe.SortSpec::desc("quantity"),
    ))
    .map(sorted => @moonframe.to_markdown(@moonframe.describe(sorted)))
}
```

Sub-package imports (`@types`, `@column`, `@frame`, `@ops`, `@io`)
remain supported for callers who only need a slice.

## Type inference (CSV / JSON)

`read_csv` / `read_json` infer each column's dtype from the first
`infer_schema_rows` rows (default `100`), in the order
`Int → Float → Bool → String`. **A non-null cell *beyond* that window
that does not fit the inferred dtype is a hard `ParseError` — not a
silent fallback to `String`.** A column that looks numeric in its first
rows but holds text later fails loudly rather than being quietly
retyped; raise `infer_schema_rows` (or build the column with an explicit
dtype) for inputs whose type only becomes clear further down. Numeric
forms follow pandas / polars conventions: `0x` / `0o` / `0b` prefixes
and `1_000` underscore grouping stay `String`; integers up to the
`Int64` range stay `Int` and overflow into `Float` only beyond it.

## Examples

Run the bundled examples from the project root:

```sh
moon run examples/sales_analysis    # read_csv → filter → select → sort → describe → markdown
moon run examples/data_cleaning     # read_csv → drop_nulls_in → fill_null → write_csv round-trip
```

Each example splits its pipeline logic into a library sub-package
(`examples/<name>/<logic>/`) tested via blackbox `*_test.mbt`,
while the top-level `main.mbt` is a thin `read → run → println`
orchestrator (`#coverage.skip`-marked).

## Building

```sh
moon check     # type-check the workspace
moon test      # run all blackbox tests
moon info      # regenerate per-package .mbti interfaces
moon fmt       # format sources
```

## Dependencies

- [`moonbit-community/NyaCSV`](https://mooncakes.io/docs/moonbit-community/NyaCSV) —
  CSV parser
- [`moonbitlang/x`](https://mooncakes.io/docs/moonbitlang/x) — extra
  standard-library utilities (`@fs` for filesystem I/O)

## License

Apache-2.0 — see [LICENSE](LICENSE).
