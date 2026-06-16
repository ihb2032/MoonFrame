# MoonFrame quickstart (runnable)

Every code block below is a **doc test**: `moon test` compiles and runs it on
all four backends (wasm / wasm-gc / js / native), so these examples cannot
silently rot — if the public API or its output changes, CI fails here until the
example (and its expected output) is updated with `moon test --update`.

These blocks use the sub-package aliases (`Series`, `DataFrame`, `col`, …)
re-exported by the facade. In application code you would
`import "ihb2032/MoonFrame" @moonframe` and prefix the same names with
`@moonframe.` (see [`README.md`](README.md)), or import a single sub-package
(`@frame`, `@io`, …) for a slice of the surface.

## Build a frame, then group and aggregate

`group_by(keys).agg([...])` returns one row per group; each aggregation is a
reduction expression such as `col(c).sum()`, and `with_alias` names its column.
`sort_by` orders the summary. (Means are chosen here to be exact so the rendered
table is identical on every backend.)

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
      col("quantity").sum().with_alias("total_quantity"),
      col("revenue").mean().with_alias("avg_revenue"),
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
top-to-bottom. `filter` keeps the rows where an `Expr` predicate is
`true` (see the next section); `select` takes expressions too, and
`cols([...])` is the shorthand that turns a list of names into a plain
column projection.

```moonbit check
///|
test "quickstart: filter + select + sort" {
  let df = DataFrame::new([
    Series::from_strings("product", ["widget", "gadget", "widget"]),
    Series::from_strings("region", ["west", "east", "east"]),
    Series::from_ints("quantity", [10, 5, 7]),
  ])
  let out = df
    .filter(col("product").eq(lit_str("widget")))
    .select(cols(["region", "quantity"]))
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

## Derive columns with expressions

An `Expr` is a composable, inspectable column computation. `with_columns`
evaluates a list of them against the frame and appends (or, on a name clash,
replaces) the result. Arithmetic is the overloaded operators (`+` `-` `*` `/`);
`with_alias` names the output. Division is always `Float` (the integer operands
are promoted), matching Polars.

```moonbit check
///|
test "quickstart: derive columns with with_columns" {
  let sales = DataFrame::new([
    Series::from_strings("region", ["west", "east", "north"]),
    Series::from_ints("revenue", [100, 80, 40]),
    Series::from_ints("cost", [60, 30, 20]),
  ])
  let enriched = sales.with_columns([
    (col("revenue") - col("cost")).with_alias("profit"),
  ])
  inspect(
    enriched.to_markdown(),
    content=(
      #|| region | revenue | cost | profit |
      #|| ------ | ------- | ---- | ------ |
      #|| west   | 100     | 60   | 40     |
      #|| east   | 80      | 30   | 50     |
      #|| north  | 40      | 20   | 20     |
      #|
    ),
  )
}
```

## Filter with an expression predicate

`filter` keeps the rows where an `Expr` evaluates to `true` (a `false` or
null cell drops the row). Comparisons are methods
(`eq` / `ne` / `lt` / `le` / `gt` / `ge`), and the logical connectives are the
`&` (and) / `|` (or) operators — methods bind tighter than `&`, so the two
comparisons below need no parentheses. Because the predicate is *data*
rather than a closure, the lazy layer can inspect and push it down.

```moonbit check
///|
test "quickstart: filter with an expression predicate" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west", "west"]),
    Series::from_ints("revenue", [100, 80, 30, 70]),
  ])
  let out = df.filter(
    col("region").eq(lit_str("west")) & col("revenue").gt(lit_int(50)),
  )
  inspect(
    out.to_markdown(),
    content=(
      #|| region | revenue |
      #|| ------ | ------- |
      #|| west   | 100     |
      #|| west   | 70      |
      #|
    ),
  )
}
```

## Composite aggregation

Each aggregation passed to `agg` is a full `Expr`, so beyond the bare-column
reductions above it can reduce a *derived* column — here `(revenue - cost)
.sum()`, the per-group total profit.

```moonbit check
///|
test "quickstart: composite aggregation" {
  let sales = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west", "east"]),
    Series::from_ints("revenue", [100, 50, 70, 30]),
    Series::from_ints("cost", [60, 20, 40, 25]),
  ])
  let summary = sales
    .group_by(["region"])
    .agg([
      (col("revenue") - col("cost")).sum().with_alias("total_profit"),
      col("revenue").mean().with_alias("avg_revenue"),
    ])
  inspect(
    summary.to_markdown(),
    content=(
      #|| region | total_profit | avg_revenue |
      #|| ------ | ------------ | ----------- |
      #|| west   | 70           | 85          |
      #|| east   | 35           | 40          |
      #|
    ),
  )
}
```

## Conditional columns with `when` / `then` / `otherwise`

`when(cond).then(a).otherwise(b)` builds a row-wise conditional expression —
the value is `a` where `cond` is `true`, `b` otherwise.

```moonbit check
///|
test "quickstart: conditional column with when/then/otherwise" {
  let df = DataFrame::new([
    Series::from_strings("product", ["widget", "gadget", "gizmo"]),
    Series::from_ints("score", [80, 55, 60]),
  ])
  let graded = df.with_columns([
    when(col("score").ge(lit_int(60)))
    .then(lit_str("pass"))
    .otherwise(lit_str("fail"))
    .with_alias("grade"),
  ])
  inspect(
    graded.to_markdown(),
    content=(
      #|| product | score | grade |
      #|| ------- | ----- | ----- |
      #|| widget  | 80    | pass  |
      #|| gadget  | 55    | fail  |
      #|| gizmo   | 60    | pass  |
      #|
    ),
  )
}
```

## Build a lazy plan, explain it, then collect

`lazy_frame(df)` starts a deferred query: the builder methods grow a logical
plan instead of computing anything, and `collect()` is the single step that
runs it. `explain()` prints the plan as built; `explain(optimized=true)` prints
the plan `collect` actually runs — here the optimizer has inserted a narrowing
`SELECT` over the scan, pruning the `product` column the query never reads.
Collecting is bitwise-equal to the same verbs run eagerly.

```moonbit check
///|
test "quickstart: build a lazy plan, explain it, then collect" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west"]),
    Series::from_strings("product", ["widget", "gadget", "gizmo"]),
    Series::from_ints("revenue", [100, 50, 70]),
  ])
  let plan = lazy_frame(df)
    .filter(col("region").eq(lit_str("west")))
    .select([col("region"), col("revenue")])
  // The plan as built — a faithful mirror of the chained verbs.
  inspect(
    plan.explain(),
    content=(
      #|SELECT [col(region), col(revenue)]
      #|  FILTER (col(region) == "west")
      #|    SCAN [3×3]
    ),
  )
  // The optimized plan: a narrowing SELECT prunes `product` at the scan.
  inspect(
    plan.explain(optimized=true),
    content=(
      #|SELECT [col(region), col(revenue)]
      #|  FILTER (col(region) == "west")
      #|    SELECT [col(region), col(revenue)]
      #|      SCAN [3×3]
    ),
  )
  // collect runs the query (and is the only step that can fail).
  inspect(
    plan.collect().to_markdown(),
    content=(
      #|| region | revenue |
      #|| ------ | ------- |
      #|| west   | 100     |
      #|| west   | 70      |
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

The matrix also has `right_join` and `outer_join`. A full **outer** join keeps
the unmatched rows from *both* sides; coalescing the key
(`with_coalesce(true)`) merges it into one column, taking each row's value from
whichever side is present — so the order with no customer and the customer with
no order both survive.

```moonbit check
///|
test "quickstart: outer_join" {
  let orders = DataFrame::new([
    Series::from_ints("customer_id", [1, 2, 3]),
    Series::from_ints("amount", [100, 50, 70]),
  ])
  let customers = DataFrame::new([
    Series::from_ints("customer_id", [1, 2, 4]),
    Series::from_strings("region", ["west", "east", "north"]),
  ])
  inspect(
    orders
    .join(
      customers,
      JoinOptions::on(["customer_id"])
      .with_how(JoinType::Outer)
      .with_coalesce(true),
    )
    .to_markdown(),
    content=(
      #|| customer_id | amount | region |
      #|| ----------- | ------ | ------ |
      #|| 1           | 100    | west   |
      #|| 2           | 50     | east   |
      #|| 3           | 70     |        |
      #|| 4           |        | north  |
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

## Choose a column-storage backend

A `Series` holds a pluggable `ColumnStorage` — either the general-purpose
`Builtin` Arrow column or the all-valid, unboxed `Numeric` fast path (no
validity bitmap). The no-null `from_ints` / `from_floats` pick `Numeric`
automatically; nullable columns stay `Builtin`. `to_numeric()` /
`to_builtin()` move a column (or, on a `DataFrame`, every eligible column)
between backends without changing any value.

```moonbit check
///|
test "quickstart: pluggable column storage" {
  let df = DataFrame::new([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_int_options("score", [Some(10), None, Some(30)]),
  ])
  // A no-null numeric column lands on the unboxed Numeric fast path; a
  // nullable column stays on the general-purpose Builtin backend.
  inspect(
    df.get_column("id").storage_kind() == StorageKind::Numeric,
    content="true",
  )
  inspect(
    df.get_column("score").storage_kind() == StorageKind::Builtin,
    content="true",
  )
  // `to_builtin()` materialises every column onto Builtin; the values are
  // untouched (only the backing representation changes).
  let widened = df.to_builtin()
  inspect(
    widened.get_column("id").storage_kind() == StorageKind::Builtin,
    content="true",
  )
  inspect(
    widened.get_column("id").to_scalars() == df.get_column("id").to_scalars(),
    content="true",
  )
  // `to_numeric()` moves the eligible (all-valid, numeric) columns back.
  inspect(
    widened.to_numeric().get_column("id").storage_kind() == StorageKind::Numeric,
    content="true",
  )
}
```
