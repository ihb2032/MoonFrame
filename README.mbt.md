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

It covers CSV / JSON / NDJSON / Parquet / Arrow IPC / Avro / Excel / Stata /
XML / HTML / SAS / SPSS / ORC I/O and SQL through the moondb contract, filtering,
sorting, null handling, group-by, joins, summary statistics, a composable
expression engine, and a lazy query layer, and exports to Markdown, HTML,
LaTeX, JSON, NDJSON, and Vega-Lite charts — a focused foundation for everyday
tabular work, not a full pandas clone.

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
`@expr`, `@frame`, `@io`, `@chart`) stay directly importable for a
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
  formula neutralisation for spreadsheet-facing exports, and transparent
  gzip (`.gz` sources decompress on read; `write_*` compresses a `.gz`
  path).
- **Interchange with Arrow** — `read_ipc` / `write_ipc` (`parse_ipc` for
  bytes already in memory) over the Arrow IPC file and stream framings:
  lists, structs, and dictionary-encoded columns among what reads, LZ4 /
  Zstandard buffer compression optional on a write, and a type with no
  dtype to read as refusing by its column's name. `read_ipc`'s docstring
  states the mapping and the refusals.
- **Read and write Avro** — `read_avro` reads a file's record as a frame
  (`parse_avro` for bytes already in memory) and `write_avro` writes one,
  its blocks stored as encoded or compressed by `AvroCodec` (deflate,
  snappy, zstandard). A date, a timestamp, and a decimal ride the
  format's logical types, an enum reads as its symbol, and a list or a
  struct as the `List` / `Struct` dtypes. `parse_avro`'s docstring states
  the mapping and the refusals.
- **Read SPSS system files** — `read_spss` reads a `.sav` system file, or
  its zlib-compressed `.zsav` form, as a frame (`parse_spss` for bytes
  already in memory), over a codec inside the module: plain,
  bytecode-compressed and zlib-compressed cases in either byte order. A
  numeric variable reads as `Float`, one under a date, datetime or time
  format as a `Date` or a `Timestamp`, a string variable as `String`, and
  the system-missing value and the declared missing values as null.
  `parse_spss`'s docstring states the mapping and the refusals.
- **Read and write Excel** — `read_excel` reads one sheet of a workbook
  (the first, or the one `ExcelReadOptions` names; `excel_sheets` lists
  them) and `write_excel` writes a frame as one (`parse_excel` for bytes
  already in memory). A file opens as whichever spreadsheet its bytes
  name: an Excel workbook (`.xlsx`, or the macro-enabled `.xlsm`), an
  OpenDocument spreadsheet (`.ods`), or an Excel 97–2003 workbook
  (`.xls`) — all three into the same frame, by the same rules; only the
  Excel workbook is written. Each column takes the narrowest dtype
  holding its values, a number under a date format reads as a `Date` or
  a `Timestamp`, and a `Date` or a `Timestamp` is written as a date a
  spreadsheet shows as one. `read_excel`'s docstring states the rules
  and the refusals.
- **Read and write Stata** — `read_stata` reads a dataset of releases 113
  to 119, in either byte order, as a frame (`parse_stata` for bytes
  already in memory) and `write_stata` writes one as release 118. A
  variable under a date format reads as a `Date` or a `Timestamp` and the
  27 missing codes as nulls; value labels are not applied.
  `parse_stata`'s docstring states the mapping and the refusals.
- **Read and write XML** — `read_xml` reads the elements a path names as
  the rows of a frame (`parse_xml` for a document already in memory) and
  `write_xml` writes one back (`format_xml` for the document's text). A
  row's columns are its attributes, its own text, and its direct child
  elements, and each takes the narrowest dtype holding its values.
  `parse_xml`'s docstring states the paths it takes and the cells' rules.
- **Read HTML tables** — `read_html` reads every table a page holds, one
  frame a table in the order the page opens them (`parse_html` for the
  page's text). The rows in a `thead`, or the leading rows of `th` cells,
  name the columns, a cell's `rowspan` and `colspan` say how far it
  reaches, and each column takes the narrowest dtype holding its values.
  `parse_html`'s docstring states the rules.
- **Read SAS files, write transport files** — `read_sas` reads a SAS
  transport file (XPORT, Version 5) or a SAS data set (`sas7bdat`),
  whichever the file opens as (`parse_sas` for bytes already in memory),
  and `write_sas` writes a transport file, over codecs inside the module.
  A file's numbers read as `Float`, a variable under a date format as a
  `Date` or a `Timestamp`, and the 28 missing spellings as nulls.
  `parse_sas`'s docstring states the mappings and the refusals.
- **Read ORC files** — `read_orc` reads a file's top-level fields as a frame
  (`parse_orc` for bytes already in memory), over a codec inside the module:
  the format's versions 0.11 and 0.12 under none, zlib, snappy, LZ4 or
  zstandard compression. Lists and structs read as the `List` / `Struct`
  dtypes, a decimal as `Decimal`, and a projection leaves a column it does
  not name undecoded, and `scan_orc` reads lazily, a stripe a batch, a
  pushed-down window skipping the stripes outside it. `parse_orc`'s
  docstring states the mapping and the refusals.
- **Read and write a database** — `read_sql(driver, sql, params~)` runs a
  query through any moondb driver and answers a frame, `read_sql_table`
  reads one table whole, `write_sql(df, driver, table, if_exists~)`
  writes a frame into a table created from the frame's columns and
  spelled for the driver's dialect, and `scan_sql` is the lazy source
  over a query, read through the driver's cursor in batches. MoonFrame
  takes the moondb contract and no database backend: the driver is the
  caller's.
- **Read fixed-width files** — `read_fwf` reads a file of fixed-width
  lines as a frame (`parse_fwf` for text already in memory): each line a
  row, its fields laid out by `FwfReadOptions` — inferred from the first
  lines, or named by `widths` or `colspecs` — the first line the header,
  a blank line skipped, and each column typed by the CSV reader's rule.
  `parse_fwf`'s docstring states the rules and the refusals.
- **Hold lists and structs** — a column of lists (`DataType::List`) or of
  records (`DataType::Struct`), built with `Series::from_scalars` or read
  from a JSON field of arrays / objects, and carried whole through the
  row verbs, the comparisons, `sort`, `group_by`, `join`, and `unique`;
  arithmetic, the statistics, and casts refuse one. The dtype's
  docstring states which verbs read a nested column.
- **Reshape** — `filter`, `select`, `drop`, `rename`, `with_columns`, multi-key
  `sort`, row dedup (`unique`), seeded row draws (`sample`, `shuffle`), and
  null handling (`drop_nulls`, `fill_null`).
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
- **Defer & optimize** — `df.to_lazy()` (or `LazyFrame::LazyFrame(df)`), or
  `scan_csv` / `scan_ndjson` / `scan_json` / `scan_parquet` / `scan_ipc` /
  `scan_orc` for a lazy file source and `scan_sql` for a query (deferred
  execution
  with projection *and* predicate pushdown into the reader — the text
  formats still tokenise at `collect()`, the columnar sources decode only
  the columns and batches they need, and a SQL query stops at a sunk
  window's end),
  builds a query plan you can `explain()`; `collect()` runs it through the
  optimizer, producing an equal frame for the cells it reads. What a
  push-down does *not* read, it does not parse — so a parse error confined to a
  pruned column, or to a row the pushed-down predicate drops (in a column that
  predicate does not itself read), never surfaces. `LazyFrame::collect`'s
  docstring states the contract in full. The `sink_*` entries —
  `sink_csv` / `sink_json` / `sink_ndjson` to the text formats,
  `sink_parquet` / `sink_ipc` to the columnar ones — write a plan's result
  straight from its batches without building the collected frame; a text
  sink's file is byte-for-byte its `format_*` rendering of `collect()`.
  `PartitionBy` turns a sink's target into a directory instead: a
  directory a distinct value of the key columns (`region=Americas/`),
  and a file per so many rows.
- **Join** — the full `inner` / `left` / `right` / `outer` / `cross` matrix on
  expression keys, e.g.
  `orders.join(customers, JoinOptions::on([col("customer_id")]))` — or, for
  differently-named or derived keys,
  `JoinOptions::left_on([col("customer_id")], right_on=[col("id")])`.
- **Summarize** — `describe()` for a per-column summary, or single statistics
  (`sum` / `mean` / `min` / `max` / …).
- **Export** — `to_markdown()` / `to_html()` / `to_latex()`, and charts: `plot(df)`
  chains to a finished chart over plain column names
  (`plot(df).bar(x="region", y="revenue").write_html("out.html")`),
  backed by `format_vega_lite` (a
  full typed mirror of Vega-Lite v6: seventeen marks, thirty-eight
  encoding channels, the nineteen transforms with the filter-predicate
  union, layer / concat / facet / repeat compositions, interactive
  parameters and conditional encodings, and the theme tree — every
  emission held to the vendored schema of the mirrored Vega-Lite release by a CI-walked golden
  corpus), and — through the `io` package — the string-level
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
[Vega-Lite](https://vega.github.io/vega-lite/) chart via
`plot(summary).bar(x="region", y="revenue").to_json()` — a v6 spec ready to
paste into the [Vega editor](https://vega.github.io/editor/), or written as a
self-contained page with `.write_html("out.html")`.

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

Four runnable end-to-end programs live in [`examples/`](examples/) (a fifth
directory, `readme_install`, is not one of them — it is the README install
snippet's compile probe):

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

- **`Int` / `Float` division is always `Float`** (integer operands promote);
  a `Decimal` pair stays `Decimal` (see `Expr::div`). Dividing by zero gives
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
and an internal package whose surface is driven from a single caller is
exercised through that caller — but its coverage still lives in package-local
tests: a cross-package call is not counted by `moon coverage analyze`
(`internal/kernel` pairs `frame`'s expression path with its own `_wbtest` /
`_test` pins):

```
types/      value types, errors (DataError), schemas
internal/buffer/   the raw buffer primitives — the Arrow validity bitmap and the UTF-8 (bytes + offsets) string buffer every columnar layout flattens from
internal/scan/     the scan-driver seam — what one readable source (CSV, NDJSON, Parquet, Arrow IPC) implements so the lazy engine executes, narrows, and renders it format-agnostically
internal/column/   Arrow-style storage — validity bitmap + Builtin/Numeric backends; wrapped by Series and read by internal/kernel (which packages may name it is enforced by check_layering.sh)
internal/kernel/   the vectorized expression kernels — Series broadcasting, arithmetic / logic / comparison / string ops, ternary, map, and the dtype inference behind a computed column; called by frame's evaluator
internal/text/     shared text primitives — lexicographic compare, debug escaping, decimal literal parsing
internal/numeric/  shared numeric primitives — exact Int64/Double comparison and the extremum fold, used from types up through the kernels
internal/order/    shared position primitives — the stable index sort behind every sort, and the row-count clamp behind every head / tail / limit
internal/ir/       module-internal expression AST — ExprNode + the operator tags, walked by the engine
internal/parquet/  the native parquet codec — thrift compact metadata, RLE definition levels, PLAIN and dictionary values, snappy / gzip page bodies; wrapped by io's read / write / scan_parquet
internal/ipc/      the native Arrow IPC codec — hand-written FlatBuffers metadata, the stream and file framings, dictionary batches, LZ4 / Zstandard buffer compression; wrapped by io's read / write / scan_ipc
internal/avro/     the native Avro codec — the JSON schema with its logical types, the zigzag binary encoding, and the file's blocks under null / deflate / snappy / zstandard; wrapped by io's read / write_avro
internal/stata/    the native Stata codec — the binary and tagged headers of releases 113 to 119, the row-major data block, and the long-string table; wrapped by io's read / write_stata
internal/xport/   the native SAS transport codec — the Version 5 header records, the NAMESTR descriptors, the row-major observations, and the IBM floating point a numeric cell spells; wrapped by io's read / write_sas
internal/sas7bdat/ the native SAS data-set codec — the paged layout of Versions 7, 8 and 9 with its subheaders, either byte order and word size, the two row compressions, and the single-byte character sets; wrapped by io's read_sas
internal/orc/     the native ORC codec — the file tail with its PostScript and Footer, each stripe's footer and streams under none / zlib / snappy / LZ4 / zstandard, and the run length encodings of the 0.11 and 0.12 formats; wrapped by io's read / scan_orc
internal/spss/     the native SPSS system-file codec — the file header, the dictionary's records with the variables' print formats and declared missing values, and the cases plain, bytecode-compressed or inside a zlib stream; wrapped by io's read_spss
internal/fwf/     the fixed-width column logic — where each line's fields start and end, inferred from the lines or named by widths and positions, and how a line is cut into them; wrapped by io's read_fwf
internal/ods/      the native OpenDocument spreadsheet codec — the ZIP package with the mimetype and the root element that judge it, the content.xml event walk over tables, rows and cells, a cell's typed values (text, number, boolean, date, instant, time of day), and the repetition counts the desktop writers spell; read by io's read_excel
internal/xls/      the native Excel 97–2003 codec — the compound file's sectors, FAT and mini stream, the BIFF8 records from the workbook globals to each sheet's cells, the shared string table across its continuations, and the number format a date is read by; read by io's read_excel
series/     Series + column-level stats + the shared reduction / rebuild / key-cell kernels
expr/       opaque Expr handle — constructors, operators, when/then/otherwise builders, to_string rendering
frame/      DataFrame + the operators (usually one per file) + group_by + join + the expression evaluator (with_columns / select / filter / agg) + to_markdown / to_html + the deferred query plan (LazyFrame builders, collect / explain, predicate + projection pushdown)
io/         CSV (NyaCSV-backed), fixed-width, JSON, NDJSON, Parquet, Arrow IPC, Avro, Excel (.xlsx read / write, .xlsm / .ods / .xls read), Stata read / write, XML read / write, HTML read, SAS transport read / write, SAS data-set read, SPSS read, ORC read / scan + SQL over the moondb contract (read, write, scan) + their options types + the lazy scan sources (scan_csv / scan_ndjson / scan_json / scan_parquet / scan_ipc / scan_sql)
chart/      Vega-Lite v6 typed mirror — the plot(df) fluent chain over plain column names, ChartSpec mark-named builders over VegaChannel (field / constant / datum), the Chart composition layer, the guide trees (scale / axis / legend / header / projection / title), transforms, parameters, and the VegaConfig theme, format_vega_lite / write_vega_lite, a golden corpus schema-walked in CI (shares io's JSON cell conventions)
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
