// Pure expression / lazy-query logic for the `expressions` example.
// Living in its own library package keeps `main` thin (so it can be
// `#coverage.skip` without losing real coverage) and lets the blackbox
// tests next to this file drive every branch through the facade —
// exactly the way a downstream user would call them.
//
// Each function showcases one slice of the v0.4 surface: `with_columns`
// derived columns, an `Expr` predicate for `filter_where`, composite
// `agg_exprs`, a `when / then / otherwise` conditional, and a deferred
// `LazyFrame` pipeline you can `explain` before you `collect`.

///|
/// Derive two columns with `with_columns`, using the `Expr` operators:
/// `profit = revenue - cost` (integer subtraction) and
/// `unit_price = revenue / quantity` (MoonFrame's `/` is always `Float`,
/// promoting the integer operands). Every existing column is kept; the
/// two derived columns are appended in expression order. Raises if a
/// referenced column is missing or non-numeric.
pub fn enrich(
  df : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  df.with_columns([
    (@moonframe.col("revenue") - @moonframe.col("cost")).with_alias("profit"),
    (@moonframe.col("revenue") / @moonframe.col("quantity")).with_alias(
      "unit_price",
    ),
  ])
}

///|
/// Keep the profitable western rows: `enrich`, then `filter_where` with a
/// composite predicate. Comparisons are methods (`gt` / `eq`) and the
/// logical *and* is the `&` operator — methods bind tighter than `&`, so
/// no parentheses are needed. A `false` / null cell drops the row, just
/// like the closure `filter`.
pub fn top_west(
  df : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  enrich(df).filter_where(
    @moonframe.col("profit").gt(@moonframe.lit_int(0)) &
    @moonframe.col("region").eq(@moonframe.lit_str("west")),
  )
}

///|
/// Summarise per region with `agg_exprs` — the expression generalisation
/// of `AggSpec`. `total_profit` is a *composite* aggregation,
/// `(revenue - cost).sum()`, which a single `AggSpec` cannot express;
/// `avg_revenue` and `n` are the familiar `mean` / `count` reductions.
/// One row per region, in first-appearance order.
pub fn margins(
  df : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  df
  .group_by(["region"])
  .agg_exprs([
    (@moonframe.col("revenue") - @moonframe.col("cost"))
    .sum()
    .with_alias("total_profit"),
    @moonframe.col("revenue").mean().with_alias("avg_revenue"),
    @moonframe.col("product").count().with_alias("n"),
  ])
}

///|
/// Tag each row with a `when / then / otherwise` conditional: revenue at
/// or above 60 is `"high"`, otherwise `"low"`. The conditional lowers to
/// a single derived column appended by `with_columns`.
pub fn graded(
  df : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  df.with_columns([
    @moonframe.when(@moonframe.col("revenue").ge(@moonframe.lit_int(60)))
    .then(@moonframe.lit_str("high"))
    .otherwise(@moonframe.lit_str("low"))
    .with_alias("tier"),
  ])
}

///|
/// Build a deferred query plan over `df` without running it. Building a
/// `LazyFrame` is **total** — every builder just wraps the plan in one
/// more node — so this never raises; the work (and any error) happens in
/// `collect`. The pipeline filters to the west, scales revenue, and
/// projects two columns; `explain` prints the plan and
/// `explain(optimized=true)` prints the plan `collect` actually runs,
/// with the filter sunk below the projection and the scan narrowed to the
/// columns the query reads.
pub fn report_plan(df : @moonframe.DataFrame) -> @moonframe.LazyFrame {
  @moonframe.lazy_frame(df)
  .with_columns([
    (@moonframe.col("revenue") * @moonframe.lit_float(1.5)).with_alias(
      "revenue_adj",
    ),
  ])
  .filter_where(@moonframe.col("region").eq(@moonframe.lit_str("west")))
  .select_exprs([@moonframe.col("region"), @moonframe.col("revenue_adj")])
}
