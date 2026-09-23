# MoonFrame

**A small, friendly DataFrame library for MoonBit.** Read a CSV, reshape it with
a few chained methods, and print or export the result. If you have used pandas or
polars, the shape of the API will feel familiar:

```moonbit nocheck
// API shape (illustrative — the "Quick start" below runs this same
// pipeline as a doc test)
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

```moonbit nocheck
///|
import {
  "ihb2032/MoonFrame" @moonframe,
}
```

Now `@moonframe.read_csv`, the `DataFrame` / `Series` types, and every operator
method are available in that package.

> MoonBit v0.10.4 deprecates the legacy JSON package manifest. New and migrated
> projects should use `moon.mod` / `moon.pkg`, as this repository does.

## Compatibility

The facade package — what `import "ihb2032/MoonFrame" @moonframe` re-exports —
is the supported surface; the public sub-packages (`@types`, `@series`,
`@expr`, `@frame`, `@io`, `@chart`, `@lazy`) stay directly importable for a
slice of it. Two families are deliberately off the facade: the fluent-chain
intermediates (`WhenThen` / `GroupedDataFrame` / … — chain through them without
naming them), and the string-level serialisers, reached through `@io` by name.

Pre-1.0, additions and fixes ride a patch version and a change to that surface
rides the minor one. One case reads as additive but is not: adding a variant to
a `pub(all)` enum (`DataType`, `Scalar`, `DataError`, …) is source-breaking
under MoonBit's exhaustive `match` — only a caller whose match carries a
wildcard arm stays compatible. The two error-detail enums
(`TypeMismatchDetail`, `ParseErrorDetail`) are the exception: they are
`#non_exhaustive`, so a match over them ends in a `..` arm and a new diagnostic
shape is a recompile, not a break. The upgrade steps for each release are in
[`docs/migration.md`](docs/migration.md).

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

Keep the widget rows, pick a few columns, and sort by quantity. The block
below is a **doc test**: `moon test` compiles and runs it, so the example
cannot drift from the API. It stages `sales.csv` itself through the public
`write_csv` (the test suites stage fixtures the same way), uses the names the
facade re-exports, and expects the rendered table inline — in your own module
you write the same pipeline with the `@moonframe.` prefix from the import
above:

```moonbit check
///|
test "readme: keep the widget rows, sort by quantity" {
  let path = "_build/readme_sales.csv"
  write_csv(
    path,
    DataFrame::DataFrame([
      Series::from_strings("region", [
        "west", "east", "west", "east", "north", "north", "west", "east",
      ]),
      Series::from_strings("product", [
        "widget", "gadget", "gadget", "widget", "widget", "gadget", "gizmo", "gizmo",
      ]),
      Series::from_ints("revenue", [100, 50, 70, 30, 40, 60, 90, 20]),
      Series::from_ints("quantity", [10, 5, 7, 3, 4, 6, 9, 2]),
    ]),
  )
  fn widgets(p : String) -> String raise DataError {
    read_csv(p)
    .filter(col("product").eq(lit_str("widget")))
    .select(cols(["region", "revenue", "quantity"]))
    // each key is (key, descending, nulls_last)
    .sort([(col("quantity"), true, true)])
    .to_markdown()
  }
  inspect(
    widgets(path),
    content=(
      #|| region | revenue | quantity |
      #|| ------ | ------- | -------- |
      #|| west   | 100     | 10       |
      #|| north  | 40      | 4        |
      #|| east   | 30      | 3        |
      #|
    ),
  )
}
```

Every transformation is a method on `DataFrame`, so pipelines read
top-to-bottom; anything that can fail raises `DataError` rather than crashing
(see [Error handling](#error-handling)). For a fuller tour — group-by, joins,
round-trips — see [`quickstart.mbt.md`](quickstart.mbt.md), which runs the
same way.

## What you can do

- **Read & write** CSV, JSON, and NDJSON — `read_csv` / `read_json` /
  `read_ndjson` and their `write_*` counterparts, with tunable
  [type inference](docs/type-inference.md), opt-in strict CSV quote validation,
  and formula neutralisation for spreadsheet-facing exports.
- **Reshape** — `filter`, `select`, `drop`, `rename`, `with_columns`, multi-key
  `sort`, row dedup (`unique`), and null handling (`drop_nulls`, `fill_null`).
  Brackets read Polars-style: `df["qty"]` a column, `df[1:3]` / `df[:-1]` a
  row window, `s[0]` a cell.
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
  predicate does not itself read), never surfaces. `LazyFrame::collect`'s
  docstring states the contract in full.
- **Join** — the full `inner` / `left` / `right` / `outer` / `cross` matrix on
  expression keys, e.g.
  `orders.join(customers, JoinOptions::on([col("customer_id")]))` — or, for
  differently-named or derived keys,
  `JoinOptions::left_on([col("customer_id")], right_on=[col("id")])`.
- **Summarize** — `describe()` for a per-column summary, or single statistics
  (`sum` / `mean` / `min` / `max` / …).
- **Export** — `to_markdown()` / `to_html()`, `format_vega_lite` (a Vega-Lite
  v5 chart spec), and — through the `io` package — the string-level
  `format_csv` / `format_json` / `format_ndjson`.

For example, summarise the same data by region (another doc test, in-memory
this time — `group_by` starts from any frame):

```moonbit check
///|
test "readme: summarise by region" {
  let sales = DataFrame::DataFrame([
    Series::from_strings("region", [
      "west", "east", "west", "east", "north", "north", "west", "east",
    ]),
    Series::from_ints("revenue", [100, 50, 70, 30, 40, 60, 90, 20]),
    Series::from_ints("quantity", [10, 5, 7, 3, 4, 6, 9, 2]),
  ])
  let summary = sales
    .group_by([col("region")])
    .agg([
      col("revenue").sum().with_alias("revenue"),
      col("quantity").sum().with_alias("quantity"),
    ])
  inspect(
    summary.to_markdown(),
    content=(
      #|| region | revenue | quantity |
      #|| ------ | ------- | -------- |
      #|| west   | 260     | 26       |
      #|| east   | 100     | 10       |
      #|| north  | 100     | 10       |
      #|
    ),
  )
}
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

```moonbit check
///|
test "readme: bridging a raise back to a Result" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2])])
  let result : Result[DataFrame, DataError] = Ok(df.select([col("missing")])) catch {
    e => Err(e)
  }
  assert_true(result is Err(ColumnNotFound(_)))
}
```

Operations that are provably total (`head`, `to_markdown`, …) just
return their value. `DataError` is a `pub(all) suberror`, so you can match its
variants (`ColumnNotFound`, `ParseError`, …) on the `Err`.

## Documentation

- The generated API reference — built from the docstrings, deployed to
  [GitHub Pages](https://ihb2032.github.io/MoonFrame/) on every merge to
  `main`, and published on
  [mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame); one source, two
  hosts. Per-symbol contracts live in the docstrings, and that reference is
  where they are read.
- [`quickstart.mbt.md`](quickstart.mbt.md) — a runnable tour; every snippet and
  its expected output is executed by `moon test`, and by CI across all four
  backends, so a code block cannot drift from the API. The prose around them is
  reviewed, not executed
- [`docs/comparison.md`](docs/comparison.md) — how MoonFrame aligns with, and
  deliberately differs from, Polars / pandas
- [`docs/performance.md`](docs/performance.md) — columnar layout, the `Numeric`
  fast path, and per-operation complexity
- [`docs/type-inference.md`](docs/type-inference.md) — how CSV / JSON / NDJSON
  columns get their dtypes
- [`docs/migration.md`](docs/migration.md) — upgrading across breaking releases
- The [release notes](https://github.com/ihb2032/MoonFrame/releases) — what
  each release changed, written when it is cut

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
- **`to_x` never fails; `as_x` raises.** `Scalar::to_string` renders any cell
  for display (a null cell gives `""`); `Scalar::as_string` is a typed read
  that raises `TypeMismatch` on a wrong dtype. The wrong one does not fail —
  it silently stringifies — so reach for `as_*` when a wrong dtype is a bug
  you want reported, and `to_*` only for display text whatever the cell holds.
- **`null` and `NaN` are different.** `null` is missing and propagates; `NaN`
  is a value (`sum` / `mean` / `median` propagate it, `min` / `max` skip it),
  and `sort` orders it by the IEEE total order — larger than every other
  value, so it trails an ascending sort and leads a descending one.
- **Comparisons are methods** (`col("a").gt(lit_int(0))`), not `>`, and
  `&` / `|` are Kleene-logical, not bitwise — both are MoonBit constraints.

## Contributing

The codebase is a small, layered stack of packages; each has its own sources and
a `pkg.generated.mbti` interface snapshot. Which kind of test a thing gets
follows from what is under test rather than from which directory it sits in: a
contract a caller can reach is tested from outside, through `*_test.mbt`, and a
representation is tested from within, through `*_wbtest.mbt`, so that asserting
it does not require making it public. Public packages are therefore mostly
blackbox and `internal/` ones mostly whitebox — an internal package with a
contract of its own (a parser, a renderer, a comparison) has blackbox tests too,
and one whose whole surface is driven from a single caller has none of its own
(`internal/kernel` is covered through `frame`'s expression evaluator, which is
what exercises every kernel a caller can reach):

```
types/      value types, errors (DataError), schemas
internal/buffer/   the raw buffer primitives — the Arrow validity bitmap and the UTF-8 (bytes + offsets) string buffer every columnar layout flattens from
internal/scan/     the scan-driver seam — what one readable source (CSV, NDJSON, a future Parquet) implements so the lazy engine executes, narrows, and renders it format-agnostically
internal/column/   Arrow-style storage — validity bitmap + Builtin/Numeric backends; wrapped by Series and read by internal/kernel (which packages may name it is enforced by check_layering.sh)
internal/kernel/   the vectorized expression kernels — Series broadcasting, arithmetic / logic / comparison / string ops, ternary, map, and the dtype inference behind a computed column; called by frame's evaluator
internal/text/     shared text primitives — lexicographic compare, debug escaping, decimal literal parsing
internal/numeric/  shared numeric primitives — exact Int64/Double comparison and the extremum fold, used from types up through the kernels
internal/order/    shared position primitives — the stable index sort behind every sort, and the row-count clamp behind every head / tail / limit
internal/ir/       module-internal expression AST — ExprNode + the operator tags, walked by the engine
series/     Series + column-level stats + the shared reduction / rebuild / key-cell kernels
expr/       opaque Expr handle — constructors, operators, when/then/otherwise builders, to_string rendering
frame/      DataFrame + the operators (usually one per file) + group_by + join + the expression evaluator (with_columns / select / filter / agg) + to_markdown / to_html
io/         CSV (NyaCSV-backed), JSON, NDJSON read / write + their options types
chart/      Vega-Lite export — ChartSpec / ChartKind / VegaType builders, format_vega_lite / write_vega_lite (shares io's JSON cell conventions)
lazy/       deferred query plan — LazyFrame builders, collect / explain, predicate + projection pushdown
moonframe.mbt   the root package — facade over the public API (fluent-chain intermediates stay in their sub-packages)
```

The `internal/` packages are MoonBit `internal` packages: importable inside
this module only, so they carry no compatibility promise. Where a new piece of
engine work belongs follows from what each layer owns:

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
to one side of it. Which package may import which is not restated here on
purpose: `.github/scripts/check_layering.sh` holds that rule and enforces it
against the manifests, so there is one copy of it and it cannot quietly stop
being true.

The data model is an Apache Arrow-style column layout — a data buffer beside a
byte-packed validity bitmap (`1 = valid`), except on the `Numeric` fast path,
where an all-valid `Int` / `Float` column carries no bitmap at all — with an
`O(1)` name→index cache;
`DataFrame::check_invariants()` is a formal structural spec (INV1–INV5), and the
operator test suites assert it over representative outputs.
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
