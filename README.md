# MoonFrame

A lightweight DataFrame and tabular-data library for the MoonBit ecosystem.

MoonFrame provides column-oriented `DataFrame` / `Series` types together with
CSV reading, filtering, sorting, null handling, summary statistics, and
Markdown / JSON export. The goal is not to clone every pandas feature, but
to give MoonBit a small, well-tested, extensible foundation for data
analysis.

**Method-chain API (v0.2).** Transformations are methods on `DataFrame`, so
pipelines read top-to-bottom like pandas / polars:

```moonbit
read_csv(path)
  .filter(row => row.get_string("product") == "widget")
  .select(["region", "quantity", "revenue"])
  .sort_by([("quantity", SortOrder::Desc, NullOrder::NullsLast)])
  .describe()
  .to_markdown()
```

**Error model.** Anything that can fail on bad input or I/O is an effectful
function that `raise DataError`; the library never aborts the host process on
a recoverable error, and there are no `unwrap` panic paths hidden behind
total-looking signatures. Use `try?` to bridge a chain back to a
`Result[_, DataError]` when you need a value (`let r = try? read_csv(path)`).
Operations that are provably total (`head` / `tail` / `Series::min_value` /
`drop_nulls` / `to_markdown` / …) return their value directly and read through
total accessors (`Bitmap::to_bools`, `BuiltinColumn::data`,
`DataFrame::column_series`) rather than catching an "impossible" raise.
`DataError` is a `pub(all) suberror`, so callers can both construct its
variants and match on them after a `try?`.

## Status

**v0.2 (method-chain migration) — shipped.** The whole v0.1 surface moved to
the method-chain + `raise` form described in [`docs/api.md`](docs/api.md), the
authoritative public-API reference:

- The operator verbs (`select` / `drop` / `rename` / `with_column` /
  `replace_column` / `filter` / `sort_by` / `drop_nulls` / `drop_nulls_in` /
  `fill_null` / `null_count` / `count` / `sum` / `mean` / `min` / `max` /
  `describe`) are now **methods on `DataFrame`**; the old `ops` package is
  folded into `frame`.
- Every fallible operation returns `T raise DataError` instead of
  `Result[T, DataError]`.
- `filter` takes a single `(RowView) -> Bool raise DataError` predicate (the
  v0.1 `filter` / `filter_try` split is gone — a fallible accessor in the
  predicate just raises).
- `sort_by` takes an `Array[(column, SortOrder, NullOrder)]`; multi-key sort
  falls out of listing several tuples (`sort_by_many`, the `SortSpec` struct,
  and the `IntoSortSpecs` trait are all gone).
- `to_markdown` / `to_markdown_with_limit` are `DataFrame` methods; the
  CSV / JSON string serialisers (`format_csv_str` / `format_json_records`)
  stay as `io` free functions.

The data model is unchanged: an Apache Arrow-style column layout (byte-packed
validity `Bitmap`, `1 = valid`) under `Series` / `DataFrame`, an `O(1)`
`name_to_index` cache, and `DataFrame::check_invariants()` as a formal
structural spec (INV1–INV7) asserted by every operator test.

**GroupBy has landed** — the first of the v0.2 split-apply-combine features.
`df.group_by(keys).agg([AggSpec::sum("x"), AggSpec::mean("y"), ...])` returns a
one-row-per-group summary with `Count` / `Sum` / `Mean` / `Min` / `Max`
reductions (reusing the `Series` statistics, with Polars-aligned `NaN` rules: a
`NaN` propagates through `Sum` / `Mean` but is skipped by `Min` / `Max`),
optional per-column aliases via `with_alias`, deterministic first-appearance
group order (Polars' `maintain_order=True`), and null keys kept as their own
group.

**Join has landed too.** `left.inner_join(right, ["id"])` /
`left.left_join(right, ["id"])` (or the configurable
`left.join(right, JoinOptions::on(["id"]).with_how(Left).with_coalesce(true))`)
do a hash equi-join with Polars-aligned semantics: a **null** key matches
nothing (`null != null`, as in SQL / Polars), a `NaN` key matches other NaNs,
the right-column collision suffix defaults to `"_right"`, and key columns are
coalesced on an inner join but kept (the right as `id_right`) on a left join —
`coalesce` defaults to Polars' per-`how` rule and is overridable via
`with_coalesce`. Output is the left columns then the right columns, rows in
deterministic left-then-right-match order. `left.cross_join(right)`
(`JoinType::Cross`) gives the keyless Cartesian product.

Roadmap: NDJSON in the rest of v0.2; a
`ColumnStorage` / `NumericColumn` storage abstraction in v0.3 alongside HTML
and chart-data export; an expression / lazy query layer in v0.4.

## v0.1 → v0.2 migration

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
`write_csv` and the JSON equivalents are still `io` free functions (the
`read_*` / `write_*` / `parse_*` ones now `raise`; the `format_*` ones are
total and return a `String`).

## Layout

```
moonframe/      facade package — re-exports the public API
types/          value types, errors (DataError suberror), schemas
column/         column storage backends (Arrow-style Bitmap + BuiltinColumn)
frame/          Series, DataFrame, RowView + all DataFrame operators + group_by + join + to_markdown
io/             CSV (NyaCSV-backed) and JSON read / write
docs/api.md     public API reference (source of truth)
```

Each subpackage carries its sources, its `*_test.mbt` blackbox tests, and
its `pkg.generated.mbti` interface snapshot. (`frame` follows a
one-operator-one-file layout — `frame/select.mbt`, `frame/sort.mbt`, … — even
though they share the package.)

## Usage

```moonbit
// One import covers the whole surface — the facade re-exports every
// public symbol from types / column / frame / io. The operator verbs and
// `to_markdown` are methods on `DataFrame`, reached automatically through
// the re-exported `type DataFrame`.
import "ihb2032/MoonFrame" @moonframe

fn report(path : String) -> String raise @moonframe.DataError {
  @moonframe.read_csv(path)
  .filter(row => row.get_string("product") == "widget")
  .select(["region", "quantity", "revenue"])
  .sort_by([("quantity", @moonframe.SortOrder::Desc, @moonframe.NullOrder::NullsLast)])
  .describe()
  .to_markdown()
}

// GroupBy: one row per region with a total and an average, sorted by the
// total quantity descending. `with_alias` renames the aggregated columns.
fn sales_by_region(path : String) -> String raise @moonframe.DataError {
  @moonframe.read_csv(path)
  .group_by(["region"])
  .agg([
    @moonframe.AggSpec::sum("quantity").with_alias("total_quantity"),
    @moonframe.AggSpec::mean("revenue").with_alias("avg_revenue"),
  ])
  .sort_by([
    ("total_quantity", @moonframe.SortOrder::Desc, @moonframe.NullOrder::NullsLast),
  ])
  .to_markdown()
}

// Join: enrich an orders frame with its customers' regions. Inner join
// keeps only orders whose customer_id matches; a colliding right column
// would gain the "_right" suffix (here there is none).
fn orders_with_region(
  orders : @moonframe.DataFrame,
  customers : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  orders.inner_join(customers, ["customer_id"])
}

// Bridge back to a Result at the call site when you want a value rather
// than to propagate the effect:
fn report_or_error(path : String) -> Result[String, @moonframe.DataError] {
  try? report(path)
}
```

Sub-package imports (`@types`, `@column`, `@frame`, `@io`) remain supported
for callers who only need a slice.

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
moon run examples/sales_analysis    # read_csv → filter → select → sort_by → describe → markdown
moon run examples/data_cleaning     # read_csv → drop_nulls_in → fill_null → write_csv round-trip
```

Each example splits its pipeline logic into a library sub-package
(`examples/<name>/<logic>/`) tested via blackbox `*_test.mbt`,
while the top-level `main.mbt` is a thin `read → run → println`
orchestrator (`#coverage.skip`-marked, with a single top-level
`try` / `catch` that prints a diagnostic on any `DataError`).

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
