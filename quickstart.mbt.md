# MoonFrame quickstart (runnable)

Every code block below is a **doc test**: `moon test` compiles and runs it on
all four backends (wasm / wasm-gc / js / native), so these examples cannot
silently rot — if the public API or its output changes, CI fails here until the
example (and its expected output) is updated with `moon test --update`.

These blocks use the sub-package aliases (`Series`, `DataFrame`, `AggSpec`, …)
re-exported by the facade. In application code you would
`import "ihb2032/MoonFrame" @moonframe` and prefix the same names with
`@moonframe.` (see [`README.md`](README.md)), or import a single sub-package
(`@frame`, `@io`, …) for a slice of the surface.

## Build a frame, then group and aggregate

`group_by(keys).agg([...])` returns one row per group. `with_alias` renames an
aggregated column; `sort_by` orders the summary. (Means are chosen here to be
exact so the rendered table is identical on every backend.)

```moonbit check
///|
test "quickstart: group_by + agg" {
  let sales = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west", "east"]),
    Series::from_ints("quantity", [10, 5, 7, 3]),
    Series::from_floats("revenue", [100.0, 50.0, 70.0, 30.0]),
  ])
  let summary = sales
    .group_by(["region"])
    .agg([
      AggSpec::sum("quantity").with_alias("total_quantity"),
      AggSpec::mean("revenue").with_alias("avg_revenue"),
    ])
    .sort_by([("total_quantity", SortOrder::Desc, NullOrder::NullsLast)])
  inspect(
    summary.to_markdown(),
    content=(
      #|| region | total_quantity | avg_revenue |
      #|| ------ | -------------- | ----------- |
      #|| west   | 17             | 85          |
      #|| east   | 8              | 40          |
      #|
    ),
  )
}
```

## Filter, select, sort, render

The operator verbs are methods on `DataFrame`, so a pipeline reads
top-to-bottom. A fallible accessor inside the `filter` predicate (here
`get_string`) simply raises.

```moonbit check
///|
test "quickstart: filter + select + sort" {
  let df = DataFrame::new([
    Series::from_strings("product", ["widget", "gadget", "widget"]),
    Series::from_strings("region", ["west", "east", "east"]),
    Series::from_ints("quantity", [10, 5, 7]),
  ])
  let out = df
    .filter(row => row.get_string("product") == "widget")
    .select(["region", "quantity"])
    .sort_by([("quantity", SortOrder::Desc, NullOrder::NullsLast)])
  inspect(
    out.to_markdown(),
    content=(
      #|| region | quantity |
      #|| ------ | -------- |
      #|| west   | 10       |
      #|| east   | 7        |
      #|
    ),
  )
}
```

## Render to HTML

`to_html()` renders a plain `<table>`; `to_html_with_options` adds a CSS
`class`, a `<caption>`, and an optional row cap (a `<tfoot>` banner reports the
remainder). Header and cell text is HTML-escaped by default, so untrusted data
can't inject markup.

```moonbit check
///|
test "quickstart: render to HTML" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east"]),
    Series::from_ints("quantity", [10, 5]),
  ])
  let opts = HtmlOptions::default()
    .with_table_class("dataframe")
    .with_caption("Quantities by region")
  inspect(
    df.to_html_with_options(opts),
    content=(
      #|<table class="dataframe">
      #|<caption>Quantities by region</caption>
      #|<thead>
      #|<tr><th>region</th><th>quantity</th></tr>
      #|</thead>
      #|<tbody>
      #|<tr><td>west</td><td>10</td></tr>
      #|<tr><td>east</td><td>5</td></tr>
      #|</tbody>
      #|</table>
      #|
    ),
  )
}
```

## Export a Vega-Lite chart spec

`format_vega_lite(df, spec)` produces a complete Vega-Lite v5 specification — a
JSON string you can paste into the [Vega editor](https://vega.github.io/editor/)
or hand to any Vega-Lite runtime. `ChartSpec::bar` / `line` / `point` / `area`
choose the mark; each channel's field `type` is inferred from the column dtype
(numeric → `quantitative`, else `nominal`). A spec that names a missing column
raises `ColumnNotFound`.

```moonbit check
///|
test "quickstart: export a Vega-Lite chart spec" {
  let sales = DataFrame::new([
    Series::from_strings("region", ["west", "east"]),
    Series::from_ints("revenue", [100, 50]),
  ])
  let spec = format_vega_lite(
    sales,
    ChartSpec::bar("region", "revenue").with_title("Revenue by region"),
  )
  inspect(
    spec,
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","title":"Revenue by region","mark":"bar","encoding":{"x":{"field":"region","type":"nominal"},"y":{"field":"revenue","type":"quantitative"}},"data":{"values":[{"region":"west","revenue":100},{"region":"east","revenue":50}]}}
    ),
  )
}
```

## Join two frames

`inner_join` keeps only rows whose key matches on both sides; the result is the
left columns followed by the right columns.

```moonbit check
///|
test "quickstart: inner_join" {
  let orders = DataFrame::new([
    Series::from_ints("customer_id", [1, 2, 1]),
    Series::from_ints("amount", [100, 50, 70]),
  ])
  let customers = DataFrame::new([
    Series::from_ints("customer_id", [1, 2]),
    Series::from_strings("region", ["west", "east"]),
  ])
  inspect(
    orders.inner_join(customers, ["customer_id"]).to_markdown(),
    content=(
      #|| customer_id | amount | region |
      #|| ----------- | ------ | ------ |
      #|| 1           | 100    | west   |
      #|| 2           | 50     | east   |
      #|| 1           | 70     | west   |
      #|
    ),
  )
}
```

## CSV round-trip without touching the filesystem

`format_csv_str` / `parse_csv_str` are the string-level serialisers (the
file-backed `read_csv` / `write_csv` wrap them). Round-tripping is faithful for
inferable dtypes — the property tests assert this over random input.

```moonbit check
///|
test "quickstart: csv round-trip" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east"]),
    Series::from_ints("quantity", [10, 5]),
  ])
  let csv = format_csv_str(df, CsvWriteOptions::default())
  inspect(
    csv,
    content=(
      #|region,quantity
      #|west,10
      #|east,5
      #|
    ),
  )
  let parsed = parse_csv_str(csv, CsvReadOptions::default())
  inspect(
    parsed.to_markdown(),
    content=(
      #|| region | quantity |
      #|| ------ | -------- |
      #|| west   | 10       |
      #|| east   | 5        |
      #|
    ),
  )
}
```

## NDJSON (JSON Lines) round-trip

`format_ndjson` / `parse_ndjson_str` are the string-level NDJSON serialisers
(the file-backed `read_ndjson` / `write_ndjson` wrap them). Each row is one JSON
object on its own line, terminated by `\n`; reading infers dtypes exactly as the
JSON-records reader does.

```moonbit check
///|
test "quickstart: ndjson round-trip" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east"]),
    Series::from_ints("quantity", [10, 5]),
  ])
  let ndjson = format_ndjson(df)
  inspect(
    ndjson,
    content=(
      #|{"region":"west","quantity":10}
      #|{"region":"east","quantity":5}
      #|
    ),
  )
  let parsed = parse_ndjson_str(ndjson, NdjsonReadOptions::default())
  inspect(
    parsed.to_markdown(),
    content=(
      #|| region | quantity |
      #|| ------ | -------- |
      #|| west   | 10       |
      #|| east   | 5        |
      #|
    ),
  )
}
```
