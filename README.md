# MoonFrame

**A small, friendly DataFrame library for MoonBit.** Read a CSV, reshape it with
a few chained methods, and print or export the result. If you have used pandas or
polars, the shape of the API will feel familiar:

```moonbit
// API shape (illustrative; see "Quick start" below for a runnable,
// `@moonframe`-prefixed version)
read_csv("sales.csv")
  .filter(col("product").eq(lit_str("widget")))
  .group_by([col("region")])
  .agg([col("revenue").sum()])
  .to_markdown()
```

It covers CSV / JSON / NDJSON I/O, filtering, sorting, null handling, group-by,
joins, summary statistics, a composable expression engine, and a lazy query
layer, and exports to Markdown, HTML, JSON, NDJSON, and Vega-Lite charts — a
focused foundation for everyday tabular work, not a full pandas clone.

## Install

MoonFrame is published on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame). Add it to your
module's dependencies:

```sh
moon add ihb2032/MoonFrame
```

Then import it (with the `@moonframe` alias) in the `moon.pkg.json` of the
package that uses it:

```json
{
  "import": [
    { "path": "ihb2032/MoonFrame", "alias": "moonframe" }
  ]
}
```

Now `@moonframe.read_csv`, the `DataFrame` / `Series` types, and every operator
method are available in that package.

> The `moon.pkg.json` snippet above uses the JSON manifest form. MoonBit also
> accepts the newer `moon.mod` / `moon.pkg` files (which is what this repository
> itself uses); the two forms are equivalent.

## Quick start

Suppose you have a `sales.csv`:

```
region,product,revenue,quantity
west,widget,100,10
east,gadget,50,5
west,gadget,70,7
east,widget,30,3
north,widget,40,4
north,gadget,60,6
west,gizmo,90,9
east,gizmo,20,2
```

Keep the widget rows, pick a few columns, and sort by quantity:

```moonbit
fn widgets(path : String) -> String raise @moonframe.DataError {
  @moonframe.read_csv(path)
  .filter(@moonframe.col("product").eq(@moonframe.lit_str("widget")))
  .select(@moonframe.cols(["region", "revenue", "quantity"]))
  .sort([
    (
      @moonframe.col("quantity"),
      @moonframe.SortOrder::Desc,
      @moonframe.NullOrder::NullsLast,
    ),
  ])
  .to_markdown()
}
```

`widgets("sales.csv")` returns a ready-to-print table:

```
| region | revenue | quantity |
| ------ | ------- | -------- |
| west   | 100     | 10       |
| north  | 40      | 4        |
| east   | 30      | 3        |
```

Every transformation is a method on `DataFrame`, so pipelines read
top-to-bottom; anything that can fail raises `DataError` rather than crashing
(see [Error handling](#error-handling)). For a fuller tour — group-by, joins,
round-trips — see [`quickstart.mbt.md`](quickstart.mbt.md), whose snippets all
run as doc tests on every backend.

## What you can do

- **Read & write** CSV, JSON, and NDJSON — `read_csv` / `read_json` /
  `read_ndjson` and their `write_*` counterparts, with tunable
  [type inference](docs/type-inference.md) and opt-in CSV formula
  neutralisation for spreadsheet-facing exports.
- **Reshape** — `filter`, `select`, `drop`, `rename`, `with_columns`, multi-key
  `sort`, row dedup (`unique`), and null handling (`drop_nulls`, `fill_null`).
- **Group & aggregate** — `group_by(keys).agg([...])` with `sum` / `mean` /
  `min` / `max` / `count` / `std` / `variance` / `median` / `n_unique` /
  `first` / `last`.
- **Express** — composable column expressions (`col("revenue") - col("cost")`,
  `&` / `|` logic, `when / then / otherwise`, a `str_*` string namespace) feed
  `with_columns` / `filter` / `agg`, including compound reductions like
  `(col("revenue") - col("cost")).sum()`; `map_elements` / `map_many` drop to a
  host closure for anything past the built-in algebra.
- **Defer & optimize** — `lazy_frame(df)`, or `scan_csv` / `scan_ndjson` for a
  lazy file source (deferred execution with projection pushdown, not streaming —
  the file still materializes at `collect()`), builds a query plan you can
  `explain()`; `collect()` runs it through a predicate- and projection-pushdown
  optimizer, bitwise-equal to the eager pipeline for the columns it reads (a
  pruned column is never parsed, so a parse error confined to it isn't observed).
- **Join** — the full `inner` / `left` / `right` / `outer` / `cross` matrix on
  expression keys, e.g.
  `orders.join(customers, JoinOptions::on([col("customer_id")]))` (or
  `left_on` / `right_on` for differently-named or derived keys).
- **Summarize** — `describe()` for a per-column summary, or single statistics
  (`sum` / `mean` / `min` / `max` / …).
- **Export** — `to_markdown()`, `to_html()`, `format_json_records`,
  `format_ndjson`, and `format_vega_lite` (a Vega-Lite v5 chart spec).

For example, summarise the same data by region:

```moonbit
let summary = @moonframe.read_csv("sales.csv")
  .group_by([@moonframe.col("region")])
  .agg([
    @moonframe.col("revenue").sum().with_alias("revenue"),
    @moonframe.col("quantity").sum().with_alias("quantity"),
  ])
```

`summary.to_markdown()` renders a pipe table:

```
| region | revenue | quantity |
| ------ | ------- | -------- |
| west   | 260     | 26       |
| east   | 100     | 10       |
| north  | 100     | 10       |
```

The same frame also exports as a styled HTML `<table>` via
`summary.to_html_with_options(...)`, or as a
[Vega-Lite v5](https://vega.github.io/vega-lite/) chart spec via
`format_vega_lite(summary, ChartSpec::bar("region", "revenue"))` — ready to
paste into the [Vega editor](https://vega.github.io/editor/).

## Error handling

Anything that can fail on bad input or I/O raises `DataError`; the library never
aborts your program on a recoverable error. Call such functions inside a `raise`
context (as the examples above do), or bridge back to a `Result` with a
`catch` that re-wraps the error:

```moonbit
let result : Result[String, @moonframe.DataError] = Ok(widgets("sales.csv")) catch {
  e => Err(e)
}
```

Operations that are provably total (`head`, `to_markdown`, …) just
return their value. `DataError` is a `pub(all) suberror`, so you can match its
variants (`ColumnNotFound`, `ParseError`, …) on the `Err`. The full model is in
[`docs/api.md`](docs/api.md).

## Documentation

- [`quickstart.mbt.md`](quickstart.mbt.md) — a runnable tour; every snippet is
  executed by `moon test` on all four backends, so it never goes stale
- [`docs/api.md`](docs/api.md) — the complete public-API reference
- [`docs/comparison.md`](docs/comparison.md) — how MoonFrame aligns with, and
  deliberately differs from, Polars / pandas
- [`docs/performance.md`](docs/performance.md) — columnar layout, the `Numeric`
  fast path, and per-operation complexity
- [`docs/type-inference.md`](docs/type-inference.md) — how CSV / JSON / NDJSON
  columns get their dtypes
- [`docs/migration.md`](docs/migration.md) — upgrading across breaking releases
- [`docs/changelog.md`](docs/changelog.md) — version-by-version feature history

Four runnable end-to-end programs live in [`examples/`](examples):

```sh
moon run examples/sales_analysis    # filter → select → sort → describe → markdown
moon run examples/data_cleaning     # drop_nulls → fill_null → CSV round-trip
moon run examples/reporting         # group_by → to_html + Vega-Lite spec
moon run examples/expressions       # with_columns → filter → agg → lazy + explain
```

## Design notes

MoonFrame's API and column semantics are modeled on Polars — see
[`docs/comparison.md`](docs/comparison.md) for the full alignment and the one
deliberate difference, and [`docs/performance.md`](docs/performance.md) for the
columnar layout and per-operation complexity. A few things that surprise
newcomers:

- **`/` is always `Float`** (integer operands promote); dividing by zero gives
  IEEE `±inf` / `NaN`, never a trap.
- **`null` and `NaN` are different.** `null` is missing and propagates; `NaN`
  is a value (`sum` / `mean` propagate it, `min` / `max` skip it) — except in
  `sort`, which orders `NaN` as missing.
- **Comparisons are methods** (`col("a").gt(lit_int(0))`), not `>`, and
  `&` / `|` are Kleene-logical, not bitwise — both are MoonBit constraints.

## Contributing

The codebase is a small, layered stack of packages; each has its own sources,
blackbox `*_test.mbt` tests, and a `pkg.generated.mbti` interface snapshot:

```
types/      value types, errors (DataError), schemas
internal/column/  Arrow-style storage (internal) — validity bitmap + Builtin/Numeric backends behind Series
series/     Series + column-level stats + the shared reduction / rebuild / key-cell kernels
expr/       composable column expressions — Expr AST, operators / methods, when/then/otherwise, explain
frame/      DataFrame + every operator (one per file) + group_by + join + the expression evaluator (with_columns / select / filter / agg) + to_markdown / to_html
io/         CSV (NyaCSV-backed), JSON, NDJSON read / write + Vega-Lite export
lazy/       deferred query plan — LazyFrame builders, collect / explain, predicate + projection pushdown
moonframe/  facade — re-exports the whole public API
```

The data model is an Apache Arrow-style column layout (a byte-packed validity
bitmap, `1 = valid`) with an `O(1)` name→index cache;
`DataFrame::check_invariants()` is a formal structural spec (INV1–INV7) asserted
by every operator test. The usual loop:

```sh
moon check     # type-check the workspace
moon test      # run all tests (add --target all for every backend)
moon fmt       # format sources
moon info      # regenerate .mbti interface snapshots
```

Contributions keep every source file fully covered (`moon coverage analyze`)
and a warning-free `moon check`; CI also runs the `moon bench` suite, so keep
it green too.

## Acknowledgements

MoonFrame is an original MoonBit implementation whose API and semantics are
modeled on [Polars](https://pola.rs) (MIT) — the primary reference — with a few
I/O conventions from [pandas](https://pandas.pydata.org) (BSD-3-Clause). No
Polars or pandas source was translated; see
[`docs/comparison.md`](docs/comparison.md) for what is aligned, what
deliberately differs, and what is out of scope.

## License

Apache-2.0 — see [LICENSE](LICENSE).
