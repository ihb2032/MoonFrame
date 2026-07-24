///|
/// Optimizer interaction with the string namespace. A `Str` node is per-cell
/// and total (it raises only the dtype-level `TypeMismatch` of a non-String
/// operand), so it is `row_stable` — a filter sinks past a `with_columns`
/// that derives a string column, exactly as it does past arithmetic. And a
/// `Str` wrapping an aggregation inherits that aggregation's
/// group-cell-stability, so an `str_*` over `first` keeps a group filter
/// above the aggregate. Both pin the `Str` arms added to `row_stable` /
/// `group_cell_stable`; the shared fixtures live in `lazy_test.mbt`.

///|
test "a trailing filter sinks below a string-namespace with_columns stage" {
  let df = sales_df()
  // `upper` is derived from `region` by a row-stable `str_*` op, but the
  // predicate reads `qty`, so the filter crosses the stage with no
  // string-specific rule — the same swap arithmetic earns.
  let derived = [@expr.col("region").str_to_uppercase().with_alias("upper")]
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [col(region).str_to_uppercase() as upper]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "a string predicate sinks below a selection passing its bare column" {
  let df = sales_df()
  // The predicate `region.str_starts_with("w")` is row-stable and reads only
  // the bare `region` the selection passes through, so it crosses the SELECT;
  // the projection pass then narrows the scan below the sunk filter (`bonus`
  // is dead).
  let projection = [@expr.col("region"), @expr.col("qty")]
  let predicate = @expr.col("region").str_starts_with("w")
  let plan = LazyFrame::LazyFrame(df).select(projection).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region), col(qty)]\n" +
    "  FILTER col(region).str_starts_with(\"w\")\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter(predicate))
}

///|
test "fence: a string op over an aggregation keeps a group filter above" {
  let df = sales_df()
  // The predicate reads the bare key `region` and is row-stable, so
  // group-cell-stability decides: `first(region)` can be null for an all-null
  // group, and the `str_*` wrapper inherits that — its cell is not
  // group-cell-stable, so the filter stays above the aggregate (the scan
  // still narrows below it, `bonus` being dead).
  let aggs = [
    @expr.col("qty").sum().with_alias("total"),
    @expr.col("region").first().str_to_uppercase().with_alias("u"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(qty).sum() as total, col(region).first().str_to_uppercase() as u] BY [col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
  )
}
