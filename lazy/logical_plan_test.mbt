///|
/// Blackbox snapshots for the plan tree `LazyFrame::explain` renders:
/// every node form, root-at-top with two more spaces per input level,
/// compact `SCAN [rows×cols]` / `SCAN_CSV "path"` leaves, and the label
/// helpers across every `JoinType` / `SortOrder` / `NullOrder`. Execution
/// semantics (collect ≡ eager) live in `lazy_test.mbt`, which also defines
/// the shared fixture frames; the expression rendering itself is pinned by
/// `expr`'s own `explain` tests.

///|
test "explain: a bare scan prints only the frame's shape" {
  assert_eq(lazy_frame(sales_df()).explain(), "SCAN [4×3]")
}

///|
test "explain: a linear pipeline reads top-down from the last verb" {
  let plan = lazy_frame(sales_df())
    .filter(@expr.col("qty").gt(@expr.lit_int(50)))
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")])
    .select([@expr.col("dbl"), @expr.col("region")])
  assert_eq(
    plan.explain(),
    "SELECT [col(dbl), col(region)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as dbl]\n" +
    "    FILTER (col(qty) > 50)\n" +
    "      SCAN [4×3]",
  )
}

///|
test "explain: sort keys carry their order and null placement" {
  let plan = lazy_frame(sales_df()).sort([
    (@expr.col("qty"), @frame.SortOrder::Asc, @frame.NullOrder::NullsFirst),
    (@expr.col("region"), @frame.SortOrder::Desc, @frame.NullOrder::NullsLast),
  ])
  assert_eq(
    plan.explain(),
    "SORT [col(qty) Asc NullsFirst, col(region) Desc NullsLast]\n  SCAN [4×3]",
  )
}

///|
test "explain: the row-window nodes" {
  let base = lazy_frame(sales_df())
  assert_eq(base.head(2).explain(), "HEAD 2\n  SCAN [4×3]")
  assert_eq(base.tail(1).explain(), "TAIL 1\n  SCAN [4×3]")
  assert_eq(base.slice(1, 3).explain(), "SLICE [1, 3)\n  SCAN [4×3]")
  // limit defers the same node as head, so it explains as HEAD.
  assert_eq(base.limit(2).explain(), base.head(2).explain())
}

///|
test "explain: every join type's label, with and without keys" {
  let l = lazy_frame(orders_df())
  let r = lazy_frame(cities_df())
  let scans = "\n  SCAN [3×2]\n  SCAN [3×2]"
  let on_id = @frame.JoinOptions::on([@expr.col("id")])
  assert_eq(l.join(r, on_id).explain(), "JOIN Inner on [col(id)]" + scans)
  assert_eq(
    l.join(r, on_id.with_how(@frame.JoinType::Left)).explain(),
    "JOIN Left on [col(id)]" + scans,
  )
  assert_eq(
    l.join(r, on_id.with_how(@frame.JoinType::Right)).explain(),
    "JOIN Right on [col(id)]" + scans,
  )
  assert_eq(
    l.join(r, on_id.with_how(@frame.JoinType::Outer)).explain(),
    "JOIN Outer on [col(id)]" + scans,
  )
  // The keyless Cartesian product renders without an `on` list…
  assert_eq(
    l.join(r, @frame.JoinOptions::cross()).explain(),
    "JOIN Cross" + scans,
  )
  // …and a multi-key list renders comma-separated. Rendering is faithful
  // to the stored options and total — whether the keys resolve is purely
  // collect's business.
  assert_eq(
    l
    .join(r, @frame.JoinOptions::on([@expr.col("id"), @expr.col("city")]))
    .explain(),
    "JOIN Inner on [col(id), col(city)]" + scans,
  )
  // Paired keys render as `left_on … right_on …` (faithful to the stored
  // options; whether the keys resolve is collect's business).
  assert_eq(
    l
    .join(
      r,
      @frame.JoinOptions::left_on([@expr.col("id")]).with_right_on([
        @expr.col("city"),
      ]),
    )
    .explain(),
    "JOIN Inner left_on [col(id)] right_on [col(city)]" + scans,
  )
}

///|
test "explain: aggregate prints its expressions and keys" {
  let plan = lazy_frame(sales_df())
    .group_by([@expr.col("region")])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(),
    "AGGREGATE [col(qty).sum() as total] BY [col(region)]\n  SCAN [4×3]",
  )
}

///|
test "explain: aggregate composes mid-pipeline with multiple keys and expressions" {
  let plan = lazy_frame(sales_df())
    .filter(@expr.col("qty").gt(@expr.lit_int(10)))
    .group_by([@expr.col("region"), @expr.col("bonus")])
    .agg([@expr.col("qty").mean().with_alias("avg"), @expr.col("qty").count()])
    .head(3)
  assert_eq(
    plan.explain(),
    "HEAD 3\n" +
    "  AGGREGATE [col(qty).mean() as avg, col(qty).count()] BY [col(region), col(bonus)]\n" +
    "    FILTER (col(qty) > 10)\n" +
    "      SCAN [4×3]",
  )
}

///|
test "explain: a CSV scan prints its quoted, escaped path and no projection until optimized" {
  // The path renders quoted and escaped like a string literal, on one line.
  assert_eq(scan_csv("sales.csv").explain(), "SCAN_CSV \"sales.csv\"")
  // The read options never appear in the plan, only the path.
  assert_eq(
    scan_csv_with_options("sales.csv", @io.CsvReadOptions::default()).explain(),
    "SCAN_CSV \"sales.csv\"",
  )
  // Each special character escapes exactly like `@expr` / `@types` do, so a
  // path stays unambiguous on one line.
  assert_eq(scan_csv("a\"b").explain(), "SCAN_CSV \"a\\\"b\"")
  assert_eq(scan_csv("a\\b").explain(), "SCAN_CSV \"a\\\\b\"")
  assert_eq(scan_csv("a\tb").explain(), "SCAN_CSV \"a\\tb\"")
  assert_eq(scan_csv("a\rb").explain(), "SCAN_CSV \"a\\rb\"")
  assert_eq(scan_csv("a\nb").explain(), "SCAN_CSV \"a\\nb\"")
  // As built, a CSV scan composes under any verb like any other leaf — the
  // projection is empty until the optimizer fills it.
  assert_eq(
    scan_csv("sales.csv").select([@expr.col("region")]).explain(),
    "SELECT [col(region)]\n  SCAN_CSV \"sales.csv\"",
  )
}

///|
test "explain: an NDJSON scan prints SCAN_NDJSON and composes like the CSV source" {
  // Same `render_scan_source` shape as `scan_csv`, only the label differs;
  // path escaping is pinned by the CSV scan test.
  assert_eq(
    scan_ndjson("events.ndjson").explain(),
    "SCAN_NDJSON \"events.ndjson\"",
  )
  assert_eq(
    scan_ndjson_with_options("events.ndjson", @io.NdjsonReadOptions::default()).explain(),
    "SCAN_NDJSON \"events.ndjson\"",
  )
  assert_eq(
    scan_ndjson("events.ndjson").select([@expr.col("region")]).explain(),
    "SELECT [col(region)]\n  SCAN_NDJSON \"events.ndjson\"",
  )
}

///|
test "explain: join inputs stack at the same depth with their own sub-pipelines" {
  let l = lazy_frame(orders_df()).filter(
    @expr.col("amount").gt(@expr.lit_int(10)),
  )
  let r = lazy_frame(cities_df()).head(2)
  assert_eq(
    l.join(r, @frame.JoinOptions::on([@expr.col("id")])).explain(),
    "JOIN Inner on [col(id)]\n" +
    "  FILTER (col(amount) > 10)\n" +
    "    SCAN [3×2]\n" +
    "  HEAD 2\n" +
    "    SCAN [3×2]",
  )
}
