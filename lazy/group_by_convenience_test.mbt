// Blackbox tests for the lazy `group_by` convenience verbs — each defers an
// `AggregateAll` node whose op tag resolves against the eager
// `GroupedDataFrame` verb at collect. Pinned here: `collect` is bit-for-bit
// the eager verb for every one of the thirteen tags, the explain rendering
// (verb tag per op, the interpolation spellings), the optimizer barrier — a
// projection below an `AggregateAll` is not narrowed where the explicit
// `agg` counterpart's is — and the predicate fence that keeps a filter above
// the node.

///|
/// Fixture: the "a" group holds qty [10, 20, 30], the "b" group [5, None] —
/// an all-valid group, a nullable one, and an extra `Float` column the
/// explicit-`agg` contrast below leaves unread. Numeric-only: the
/// String-column `TypeMismatch` the numeric verbs raise is pinned in
/// `frame`'s suite.
fn conv_sales_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("k", ["a", "a", "a", "b", "b"]),
    @series.Series::from_int_options("qty", [
      Some(10),
      Some(20),
      Some(30),
      Some(5),
      None,
    ]),
    @series.Series::from_float_options("f", [
      Some(1.0),
      Some(2.0),
      None,
      Some(4.0),
      Some(5.0),
    ]),
  ])
}

///|
test "each convenience collects to its eager equivalent" {
  let df = conv_sales_df()
  let keys = [@expr.col("k")]
  let lf = LazyFrame::LazyFrame(df).group_by(keys)
  let eager = df.group_by(keys)
  let cases : Array[(String, LazyFrame, @frame.DataFrame)] = [
    ("sum", lf.sum(), eager.sum()),
    ("mean", lf.mean(), eager.mean()),
    ("median", lf.median(), eager.median()),
    ("quantile", lf.quantile(0.5), eager.quantile(0.5)),
    (
      "quantile-linear",
      lf.quantile(0.5, interpolation=@series.QuantileInterpolation::Linear),
      eager.quantile(0.5, interpolation=@series.QuantileInterpolation::Linear),
    ),
    ("std", lf.std(), eager.std()),
    ("variance", lf.variance(), eager.variance()),
    ("min", lf.min(), eager.min()),
    ("max", lf.max(), eager.max()),
    ("count", lf.count(), eager.count()),
    ("first", lf.first(), eager.first()),
    ("last", lf.last(), eager.last()),
    ("n_unique", lf.n_unique(), eager.n_unique()),
    ("len", lf.len(), eager.len()),
  ]
  for (_, l, want) in cases {
    assert_eq(l.collect(), want)
  }
}

///|
test "explain prints the verb tag, per interpolation" {
  let g = LazyFrame::LazyFrame(conv_sales_df()).group_by([@expr.col("k")])
  let scans = "\n  SCAN [5×3]"
  assert_eq(g.sum().explain(), "AGGREGATE ALL SUM BY [col(k)]\{scans}")
  assert_eq(g.len().explain(), "AGGREGATE ALL LEN BY [col(k)]\{scans}")
  // Every remaining verb's tag renders once, so the label table stays fully
  // pinned alongside the collect parity above.
  let tags : Array[(String, LazyFrame)] = [
    ("MEAN", g.mean()),
    ("MEDIAN", g.median()),
    ("STD", g.std()),
    ("VARIANCE", g.variance()),
    ("MIN", g.min()),
    ("MAX", g.max()),
    ("COUNT", g.count()),
    ("FIRST", g.first()),
    ("LAST", g.last()),
    ("N_UNIQUE", g.n_unique()),
  ]
  for (tag, plan) in tags {
    assert_eq(plan.explain(), "AGGREGATE ALL \{tag} BY [col(k)]\{scans}")
  }
  // The quantile tag rides the q like the `Reduce` render, the `Nearest`
  // default implicit and every other interpolation spelled lowercase.
  assert_eq(
    g.quantile(0.5).explain(),
    "AGGREGATE ALL QUANTILE 0.5 BY [col(k)]\{scans}",
  )
  for
    interp in [
      @series.QuantileInterpolation::Nearest,
      @series.QuantileInterpolation::Linear,
      @series.QuantileInterpolation::Lower,
      @series.QuantileInterpolation::Higher,
      @series.QuantileInterpolation::Midpoint,
    ] {
    let tag = match interp {
      Linear => " linear"
      Lower => " lower"
      Higher => " higher"
      Midpoint => " midpoint"
      Nearest => ""
    }
    assert_eq(
      g.quantile(0.25, interpolation=interp).explain(),
      "AGGREGATE ALL QUANTILE 0.25\{tag} BY [col(k)]\{scans}",
    )
  }
}

///|
test "a projection below an AggregateAll is not narrowed; agg's is" {
  // The convenience reads every non-key column its input produces — a list
  // the plan cannot know — so the projection pass leaves the scan alone:
  // optimized, no `SELECT` appears under the node.
  let df = conv_sales_df()
  let all = LazyFrame::LazyFrame(df).group_by([@expr.col("k")]).sum()
  assert_eq(
    all.explain(optimized=true),
    "AGGREGATE ALL SUM BY [col(k)]\n  SCAN [5×3]",
  )
  // The explicit `agg` counterpart names its columns, so the same pipeline
  // with an explicit aggregation narrows the scan to keys + operand.
  let named = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("k")])
    .agg([@expr.col("qty").sum()])
  assert_eq(
    named.explain(optimized=true),
    "AGGREGATE [col(qty).sum()] BY [col(k)]\n  SELECT [col(k), col(qty)]\n    SCAN [5×3]",
  )
}

///|
test "a filter above an AggregateAll stays above it" {
  // The crossing rules cannot see which cells the convenience produces, so
  // a predicate on the output columns cannot be proven safe to sink — the
  // filter is fenced above the node, and collect still matches the eager
  // chain.
  let df = conv_sales_df()
  let predicate = @expr.col("k").eq(@expr.lit_str("a"))
  let plan = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("k")])
    .len()
    .filter(predicate)
  assert_true(
    plan
    .explain(optimized=true)
    .has_prefix("FILTER (col(k) == \"a\")\n  AGGREGATE ALL LEN BY [col(k)]"),
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("k")]).len().filter(predicate),
  )
}
