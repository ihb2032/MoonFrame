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

Then import it with the `@moonframe` alias in the `moon.pkg` of the package
that uses it:

```moonbit
import {
  "ihb2032/MoonFrame" @moonframe,
}
```

Now `@moonframe.read_csv`, the `DataFrame` / `Series` types, and every operator
method are available in that package.

> MoonBit v0.10.4 deprecates the legacy JSON package manifest. New and migrated
> projects should use `moon.mod` / `moon.pkg`, as this repository does.

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
  [type inference](docs/type-inference.md), opt-in strict CSV quote validation,
  and formula neutralisation for spreadsheet-facing exports.
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
- **Defer & optimize** — `LazyFrame::LazyFrame(df)`, or `scan_csv` / `scan_ndjson` for a
  lazy file source (deferred execution with projection *and* predicate pushdown
  into the reader, not streaming — the file still tokenizes at `collect()`),
  builds a query plan you can `explain()`; `collect()` runs it through the
  optimizer, producing an equal frame for the cells it reads. What a
  push-down does *not* read, it does not parse — so a parse error confined to a
  pruned column, or to a row the pushed-down predicate drops (in a column that
  predicate does not itself read), never surfaces. `docs/api.md` states the
  contract in full.
- **Join** — the full `inner` / `left` / `right` / `outer` / `cross` matrix on
  expression keys, e.g.
  `orders.join(customers, JoinOptions::on([col("customer_id")]))` — or, for
  differently-named or derived keys,
  `JoinOptions::left_on([col("customer_id")], right_on=[col("id")])`.
- **Summarize** — `describe()` for a per-column summary, or single statistics
  (`sum` / `mean` / `min` / `max` / …).
- **Export** — `to_markdown()`, `to_html()`, `format_json`,
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
`summary.to_html(options=HtmlOptions::HtmlOptions(caption="Summary"))`, or as a
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

- [`quickstart.mbt.md`](quickstart.mbt.md) — a runnable tour; every snippet and
  its expected output is executed by `moon test`, and by CI across all four
  backends, so a code block cannot drift from the API. The prose around them is
  reviewed, not executed
- [`docs/api.md`](docs/api.md) — API concepts & the compatibility model; the
  per-symbol reference is generated from the docstrings on
  [mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame)
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
[`docs/comparison.md`](docs/comparison.md) for the full alignment and the
deliberate differences, and [`docs/performance.md`](docs/performance.md) for the
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
internal/column/   Arrow-style storage — validity bitmap + Builtin/Numeric backends; wrapped by Series and read by internal/kernel, and named by no other package
internal/kernel/   the vectorized expression kernels — Series broadcasting, arithmetic / logic / comparison / string ops, ternary, map, and the dtype inference behind a computed column; called by frame's evaluator
internal/text/     shared text primitives — lexicographic compare, debug escaping, decimal literal parsing
internal/literal/  the one scalar-literal renderer, shared by expr / lazy plan rendering
internal/ir/       module-internal expression AST — ExprNode + the operator tags, walked by the engine
series/     Series + column-level stats + the shared reduction / rebuild / key-cell kernels
expr/       opaque Expr handle — constructors, operators, when/then/otherwise builders, to_string rendering
frame/      DataFrame + every operator (one per file) + group_by + join + the expression evaluator (with_columns / select / filter / agg) + to_markdown / to_html
io/         CSV (NyaCSV-backed), JSON, NDJSON read / write + Vega-Lite export
lazy/       deferred query plan — LazyFrame builders, collect / explain, predicate + projection pushdown
moonframe.mbt   the root package — facade over the public API (fluent-chain intermediates stay in their sub-packages)
```

The `internal/` packages are MoonBit `internal` packages: importable inside
this module only, so they carry no compatibility promise. Where a new piece of
engine work belongs is decided by one rule, written as the import it allows —
**`internal/column` is imported by `series` and `internal/kernel`, and by
nothing else**:

```
internal/column   how a column is laid out: data buffers + validity bitmap
series            what a column is: dtype, validity, backend convergence
internal/kernel   how a column is computed: one vectorized pass per operator
frame and above   what a verb means: row sets, scheduling, schema, errors
```

Two different relations are stacked there, and it helps to keep them apart:
`internal/kernel` **depends on** `series` (it takes columns and hands columns
back), while being its **peer in storage access** — both may name the physical
column, because a vectorized pass needs the representation to keep the numeric
fast paths. So a new vectorized operator goes in `internal/kernel` — where
naming the physical column is the point — a new column-level primitive goes in
`series`, and `frame` reads a column only through `Series`. `frame`'s
production build does not import `internal/column` at all; its test build does,
to assert which backend an operator's output lands on.

The dependency graph is a DAG, not a chain — `expr` and `internal/ir` sit off
to one side of it — and `.github/scripts/check_layering.sh` enforces the rule
above against the manifests rather than trusting this paragraph.

The data model is an Apache Arrow-style column layout — a data buffer beside a
byte-packed validity bitmap (`1 = valid`), except on the `Numeric` fast path,
where an all-valid `Int` / `Float` column carries no bitmap at all — with an
`O(1)` name→index cache;
`DataFrame::check_invariants()` is a formal structural spec (INV1–INV7); every
operator's test suite asserts it over that operator's representative outputs.
The usual loop:

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
