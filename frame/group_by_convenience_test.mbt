// Blackbox tests for the `group_by` convenience verbs — `GroupedDataFrame`
// methods sugar over `agg` with the op applied to every non-key column. The
// aggregation kernel's own dtype / null / `NaN` rules are pinned by the
// cross-surface suite; what is pinned here is the *expansion*: which columns
// a verb aggregates (every non-key one, in source order), what the key
// columns head, the dtype-total ops on a mixed frame, `len`'s column-blind
// row counts against `count`'s per-column non-null counts, and the
// numeric-only ops surfacing `agg`'s `TypeMismatch` on a non-numeric column.

///|
/// Numeric fixture: one key column, an `Int` value column with a null, and a
/// `Float` value column with a null — the "a" group holds [3, 1, 2] / [1.0,
/// 2.0, null], the all-null-in-`v` group "b" holds [None] / [4.0].
fn conv_nums_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_int_options("v", [Some(3), Some(1), Some(2), None]),
    Series::from_float_options("f", [Some(1.0), Some(2.0), None, Some(4.0)]),
  ])
}

///|
/// Mixed fixture: a `String` non-key column, for the dtype-total ops and the
/// numeric-only ops' `TypeMismatch`.
fn conv_mixed_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_int_options("v", [Some(3), Some(1), Some(2), None]),
    Series::from_strings("tag", ["x", "x", "y", "z"]),
  ])
}

///|
test "sum aggregates every non-key column; an all-null group is the identity" {
  let r = conv_nums_df().group_by([@expr.col("k")]).sum()
  assert_eq(r.columns(), ["k", "v", "f"])
  assert_eq(r.get_column("v").to_scalars(), [
    @types.Scalar::Int(6),
    @types.Scalar::Int(0),
  ])
  // 1.0 + 2.0 and 4.0 — group "a"'s null skipped, "b" reduced to its own
  // column's cells.
  assert_eq(r.get_column("f").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(4.0),
  ])
  assert_eq(r.check_invariants(), Ok(()))
}

///|
test "mean / median / quantile take every non-key column" {
  let g = conv_nums_df().group_by([@expr.col("k")])
  let mean = g.mean()
  assert_eq(mean.get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  assert_eq(mean.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(4.0),
  ])
  let median = g.median()
  assert_eq(median.get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  // The default interpolation is Nearest: over [1, 2, 3] the 0.5 quantile
  // names position 1.0 — the middle cell; Linear agrees there, and differs
  // from Nearest on the "f" group's two present values [1.0, 2.0] (position
  // 0.5: Linear averages, Nearest rounds up).
  let q = g.quantile(0.5)
  assert_eq(q.get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  assert_eq(q.get_column("f").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(4.0),
  ])
  let ql = g.quantile(0.5, interpolation=@series.QuantileInterpolation::Linear)
  assert_eq(ql.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(4.0),
  ])
}

///|
test "std and variance are exact on a whole-middle fixture, null on sparse" {
  // [2, 4, 6]: every Welford mean is whole, so variance 4 / std 2 exactly;
  // group "b" has one non-null cell — no sample denominator, a Null cell.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_ints("v", [2, 4, 6, 5]),
  ])
  let g = df.group_by([@expr.col("k")])
  assert_eq(g.variance().get_column("v").to_scalars(), [
    @types.Scalar::Float(4.0),
    @types.Scalar::Null,
  ])
  assert_eq(g.std().get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
}

///|
test "min / max are dtype-total: String columns reduce, all-null a Null cell" {
  let g = conv_mixed_df().group_by([@expr.col("k")])
  assert_eq(g.min().get_column("v").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  // Lexicographic: min("x", "x", "y") = "x"; max = "y".
  assert_eq(g.min().get_column("tag").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("z"),
  ])
  assert_eq(g.max().get_column("tag").to_scalars(), [
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
}

///|
test "first / last are positional per group" {
  let g = conv_mixed_df().group_by([@expr.col("k")])
  assert_eq(g.first().get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Null,
  ])
  assert_eq(g.last().get_column("tag").to_scalars(), [
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
}

///|
test "count counts non-null cells per column; len counts rows, one column" {
  let g = conv_mixed_df().group_by([@expr.col("k")])
  let c = g.count()
  assert_eq(c.columns(), ["k", "v", "tag"])
  assert_eq(c.get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
  ])
  assert_eq(c.get_column("tag").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(1),
  ])
  let l = g.len()
  // One Int column named "len", after the key columns — nulls included
  // ("b"'s single null row counts).
  assert_eq(l.columns(), ["k", "len"])
  assert_eq(l.get_column("len").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(1),
  ])
  assert_eq(l.get_column("len").dtype(), @types.DataType::Int)
}

///|
test "n_unique counts distinct cells per column, a null among them" {
  let r = conv_mixed_df().group_by([@expr.col("k")]).n_unique()
  // The second group's v is all null — the null bucket is its one
  // distinct value.
  assert_eq(r.get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(1),
  ])
  assert_eq(r.get_column("tag").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
}

///|
test "a numeric-only verb raises TypeMismatch on a non-numeric column" {
  // `sum` over the String "tag" column is the aggregation kernel's
  // `TypeMismatch`, exactly as an explicit `agg([col("tag").sum()])` raises.
  assert_true(
    (Ok(conv_mixed_df().group_by([@expr.col("k")]).sum()) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "a frame whose every column is a key reduces to the distinct keys" {
  // A two-column frame grouped by both columns leaves no non-key column:
  // the convenience degenerates to `agg([])`, the distinct key tuples —
  // (a, x), (a, y), (b, z) in first-appearance order.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_strings("tag", ["x", "y", "z"]),
  ])
  let r = df.group_by([@expr.col("k"), @expr.col("tag")]).sum()
  assert_eq(r.columns(), ["k", "tag"])
  assert_eq(r.nrows(), 3)
  assert_eq(r.get_column("tag").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
}

///|
test "a 0-row frame yields zero groups for every convenience" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", []),
    Series::from_ints("v", []),
  ])
  let g = df.group_by([@expr.col("k")])
  assert_eq(g.sum().shape(), (0, 2))
  assert_eq(g.len().shape(), (0, 2))
  assert_eq(g.n_unique().shape(), (0, 2))
}

///|
test "an empty-keys group_by aggregates every column as one grand total" {
  let r = conv_nums_df().group_by([]).len()
  assert_eq(r.shape(), (1, 1))
  assert_eq(r.get_column("len").to_scalars(), [@types.Scalar::Int(4)])
}

///|
test "an all-keys group_by still validates the quantile q" {
  // Every column is a key, so no expression is built — the entry check is
  // the only place the q is seen, and a bad one must not pass silently.
  let df = DataFrame::DataFrame([Series::from_strings("k", ["a", "b"])])
  assert_true(
    (Ok(df.group_by([@expr.col("k")]).quantile(7.0)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

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
fn conv_sales_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
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
  let cases : Array[(String, LazyFrame, DataFrame)] = [
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
