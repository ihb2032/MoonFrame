# MoonFrame

**A small, friendly DataFrame library for MoonBit.** Read a CSV, reshape it with
a few chained methods, and print or export the result. If you have used pandas or
polars, the shape of the API will feel familiar:

```moonbit
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

MoonFrame isn't published to [mooncakes.io](https://mooncakes.io) yet, so add it
as a **local dependency** from a clone of this repo:

```sh
git clone https://github.com/ihb2032/MoonFrame
```

Point your module's `moon.mod.json` at the clone (adjust the path to wherever
you cloned it):

```json
{
  "deps": {
    "ihb2032/MoonFrame": { "path": "../MoonFrame" }
  }
}
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
top-to-bottom. Anything that can fail — a missing file, an unknown column —
raises `DataError` rather than crashing (see [Error handling](#error-handling)).

For a fuller hands-on tour — group-by, joins, CSV round-trips, and more — see
[`quickstart.mbt.md`](quickstart.mbt.md): every snippet there runs as a doc test
on all four backends, so it always matches the current API.

## What you can do

- **Read & write** CSV, JSON, and NDJSON — `read_csv` / `read_json` /
  `read_ndjson` and their `write_*` counterparts, with tunable
  [type inference](docs/type-inference.md).
- **Reshape** — `filter`, `select`, `drop`, `rename`, `with_columns`, multi-key
  `sort`, and null handling (`drop_nulls`, `fill_null`).
- **Group & aggregate** — `group_by(keys).agg([...])` with `sum` / `mean` /
  `min` / `max` / `count` / `std` / `variance` / `median` / `n_unique` /
  `first` / `last`.
- **Express** — build composable column expressions
  (`col("revenue") - col("cost")`, `&` / `|` logic, `when / then / otherwise`)
  and feed them to `with_columns`, `filter`, or
  `group_by(...).agg([...])`, including compound aggregations like
  `(col("revenue") - col("cost")).sum()`. For logic past the built-in
  algebra, the `map_elements` / `map_many` escape hatch applies a host
  closure row by row.
- **Defer & optimize** — `lazy_frame(df)` builds a query plan you can
  `explain()`; `collect()` runs it through a predicate- and
  projection-pushdown optimizer, bitwise-equal to the eager pipeline.
- **Join** — the full `inner` / `left` / `right` / `outer` / `cross` matrix on
  expression keys, e.g.
  `orders.join(customers, JoinOptions::on([col("customer_id")]))` (or
  `left_on` / `right_on` for differently-named or derived keys).
- **Summarize** — `describe()` for a per-column summary, or single statistics
  (`sum` / `mean` / `min` / `max` / …).
- **Export** — `to_markdown()`, `to_html()`, `format_json_records`,
  `format_ndjson`, and `format_vega_lite` (a Vega-Lite v5 chart spec).

For example, group the same data by region and render it three ways:

```moonbit
let summary = @moonframe.read_csv("sales.csv")
  .group_by([@moonframe.col("region")])
  .agg([
    @moonframe.col("revenue").sum().with_alias("revenue"),
    @moonframe.col("quantity").sum().with_alias("quantity"),
  ])
  .sort([
    (
      @moonframe.col("revenue"),
      @moonframe.SortOrder::Desc,
      @moonframe.NullOrder::NullsLast,
    ),
  ])
```

A Markdown table for a report or notebook — `summary.to_markdown()`:

```
| region | revenue | quantity |
| ------ | ------- | -------- |
| west   | 260     | 26       |
| east   | 100     | 10       |
| north  | 100     | 10       |
```

A styled HTML table for a web page —
`summary.to_html_with_options(HtmlOptions::default().with_table_class("dataframe").with_caption("Revenue by region"))`:

```html
<table class="dataframe">
<caption>Revenue by region</caption>
<thead>
<tr><th>region</th><th>revenue</th><th>quantity</th></tr>
</thead>
<tbody>
<tr><td>west</td><td>260</td><td>26</td></tr>
<tr><td>east</td><td>100</td><td>10</td></tr>
<tr><td>north</td><td>100</td><td>10</td></tr>
</tbody>
</table>
```

Or a chart — `format_vega_lite(summary, ChartSpec::bar("region", "revenue"))`
emits a complete [Vega-Lite v5](https://vega.github.io/vega-lite/) spec you can
paste straight into the [Vega editor](https://vega.github.io/editor/) to get a
real bar chart.

## Error handling

Anything that can fail on bad input or I/O raises `DataError`; the library never
aborts your program on a recoverable error. Call such functions inside a `raise`
context (as the examples above do), or bridge back to a `Result` with `try?`:

```moonbit
let result : Result[String, @moonframe.DataError] = try? widgets("sales.csv")
```

Operations that are provably total (`head`, `drop_nulls`, `to_markdown`, …) just
return their value. `DataError` is a `pub(all) suberror`, so you can match its
variants (`ColumnNotFound`, `ParseError`, …) after a `try?`. The full model is in
[`docs/api.md`](docs/api.md).

## Documentation

- [`quickstart.mbt.md`](quickstart.mbt.md) — a runnable tour; every snippet is
  executed by `moon test` on all four backends, so it never goes stale
- [`docs/api.md`](docs/api.md) — the complete public-API reference
- [`docs/type-inference.md`](docs/type-inference.md) — how CSV / JSON / NDJSON
  columns get their dtypes
- [`docs/migration.md`](docs/migration.md) — upgrading across breaking releases
- [`docs/changelog.md`](docs/changelog.md) — version-by-version feature history

Three runnable end-to-end programs live in [`examples/`](examples):

```sh
moon run examples/sales_analysis    # filter → select → sort → describe → markdown
moon run examples/data_cleaning     # drop_nulls → fill_null → CSV round-trip
moon run examples/reporting         # group_by → to_html + Vega-Lite spec
moon run examples/expressions       # with_columns → filter → agg → lazy + explain
```

## Status

**v0.4 — shipped:** a Polars-style expression engine (`Expr` with operators,
methods, and `when / then / otherwise`) feeding `with_columns` / `filter`
/ `agg`, plus a lazy query layer (`lazy_frame(df)` → `explain` →
`collect`) with a predicate- and projection-pushdown optimizer — all purely
additive on top of v0.3's output formats, full join matrix, read resilience,
and pluggable column storage. **Next (v0.5):** splitting `Series` into its own
package, lazy CSV scanning, and more expression families (window / string /
datetime). See the [changelog](docs/changelog.md) for the full version history
and [`docs/migration.md`](docs/migration.md) for upgrade steps (v0.3 → v0.4 is
additive — nothing to change).

## Contributing

The codebase is a small, layered stack of packages; each has its own sources,
blackbox `*_test.mbt` tests, and a `pkg.generated.mbti` interface snapshot:

```
types/      value types, errors (DataError), schemas
column/     Arrow-style storage — validity Bitmap, BuiltinColumn, Numeric fast path, ColumnStorage seam
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

Contributions keep 100% line coverage and a warning-free `moon check`.

## Dependencies

- [`moonbit-community/NyaCSV`](https://mooncakes.io/docs/moonbit-community/NyaCSV) — CSV parser
- [`moonbitlang/x`](https://mooncakes.io/docs/moonbitlang/x) — `@fs` filesystem I/O

## License

Apache-2.0 — see [LICENSE](LICENSE).
