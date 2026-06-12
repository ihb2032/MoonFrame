///|
/// Blackbox snapshots for the plan tree `LazyFrame::explain` renders:
/// every node form, root-at-top with two more spaces per input level,
/// compact `SCAN [rows×cols]` leaves, and the label helpers across every
/// `JoinType` / `SortOrder` / `NullOrder`. Execution semantics (collect ≡
/// eager) live in `lazy_test.mbt`, which also defines the shared fixture
/// frames; the expression rendering itself is pinned by `expr`'s own
/// `explain` tests.

///|
test "explain: a bare scan prints only the frame's shape" {
  assert_eq(lazy_frame(sales_df()).explain(), "SCAN [4×3]")
}

///|
test "explain: a linear pipeline reads top-down from the last verb" {
  let plan = lazy_frame(sales_df())
    .filter_where(@expr.col("qty").gt(@expr.lit_int(50)))
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")])
    .select_exprs([@expr.col("dbl"), @expr.col("region")])
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
  let plan = lazy_frame(sales_df()).sort_by([
    ("qty", @frame.SortOrder::Asc, @frame.NullOrder::NullsFirst),
    ("region", @frame.SortOrder::Desc, @frame.NullOrder::NullsLast),
  ])
  assert_eq(
    plan.explain(),
    "SORT [qty Asc NullsFirst, region Desc NullsLast]\n  SCAN [4×3]",
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
  let on_id = @frame.JoinOptions::on(["id"])
  assert_eq(l.join(r, on_id).explain(), "JOIN Inner on [id]" + scans)
  assert_eq(
    l.join(r, on_id.with_how(@frame.JoinType::Left)).explain(),
    "JOIN Left on [id]" + scans,
  )
  assert_eq(
    l.join(r, on_id.with_how(@frame.JoinType::Right)).explain(),
    "JOIN Right on [id]" + scans,
  )
  assert_eq(
    l.join(r, on_id.with_how(@frame.JoinType::Outer)).explain(),
    "JOIN Outer on [id]" + scans,
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
    l.join(r, @frame.JoinOptions::on(["id", "city"])).explain(),
    "JOIN Inner on [id, city]" + scans,
  )
}

///|
test "explain: aggregate prints its expressions and keys" {
  let plan = lazy_frame(sales_df())
    .group_by(["region"])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(),
    "AGGREGATE [col(qty).sum() as total] BY [region]\n  SCAN [4×3]",
  )
}

///|
test "explain: aggregate composes mid-pipeline with multiple keys and expressions" {
  let plan = lazy_frame(sales_df())
    .filter_where(@expr.col("qty").gt(@expr.lit_int(10)))
    .group_by(["region", "bonus"])
    .agg([@expr.col("qty").mean().with_alias("avg"), @expr.col("qty").count()])
    .head(3)
  assert_eq(
    plan.explain(),
    "HEAD 3\n" +
    "  AGGREGATE [col(qty).mean() as avg, col(qty).count()] BY [region, bonus]\n" +
    "    FILTER (col(qty) > 10)\n" +
    "      SCAN [4×3]",
  )
}

///|
test "explain: join inputs stack at the same depth with their own sub-pipelines" {
  let l = lazy_frame(orders_df()).filter_where(
    @expr.col("amount").gt(@expr.lit_int(10)),
  )
  let r = lazy_frame(cities_df()).head(2)
  assert_eq(
    l.join(r, @frame.JoinOptions::on(["id"])).explain(),
    "JOIN Inner on [id]\n" +
    "  FILTER (col(amount) > 10)\n" +
    "    SCAN [3×2]\n" +
    "  HEAD 2\n" +
    "    SCAN [3×2]",
  )
}
