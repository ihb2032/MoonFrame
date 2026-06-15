///|
/// Blackbox behavior tests for the lazy layer's contract: builders are
/// total and only defer; `collect` is a faithful deferred executor —
/// bitwise-equal to the eager chain, node by node and composed; the two
/// entry points agree; and every failure surfaces at collect time as the
/// underlying eager operator's error. Plan-rendering snapshots live in
/// `logical_plan_test.mbt`; the shared fixture frames live here.

///|
/// 4×3 mixed frame: a plain Int column, a nullable Int column, and a
/// String key column — enough surface for every deferred verb.
fn sales_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_ints("qty", [5, 120, 80, 200]),
    @series.Series::from_int_options("bonus", [Some(1), None, Some(3), None]),
    @series.Series::from_strings("region", ["west", "east", "west", "east"]),
  ])
}

///|
/// Join left side: order ids and amounts (3×2).
fn orders_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_ints("id", [1, 2, 3]),
    @series.Series::from_ints("amount", [10, 20, 30]),
  ])
}

///|
/// Join right side: partially overlapping ids (3×2) — id 1 is only on the
/// left, id 4 only here, so Inner / Left / Right / Outer all differ.
fn cities_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_ints("id", [2, 3, 4]),
    @series.Series::from_strings("city", ["bern", "cork", "delft"]),
  ])
}

///|
test "an unmodified plan collects back to the source frame" {
  let df = sales_df()
  let out = lazy_frame(df).collect()
  assert_eq(out, df)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "the static constructor and the free-function alias build the same plan" {
  let df = sales_df()
  assert_eq(LazyFrame::from(df).explain(), lazy_frame(df).explain())
  assert_eq(LazyFrame::from(df).collect(), lazy_frame(df).collect())
}

///|
test "each deferred verb collects to its eager equivalent" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  assert_eq(
    lazy_frame(df).filter_where(predicate).collect(),
    df.filter_where(predicate),
  )
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  assert_eq(
    lazy_frame(df).with_columns(derived).collect(),
    df.with_columns(derived),
  )
  let projection = [
    @expr.col("region"),
    @expr.col("qty").sum().with_alias("total"),
  ]
  assert_eq(
    lazy_frame(df).select_exprs(projection).collect(),
    df.select_exprs(projection),
  )
  let keys = [
    ("bonus", @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
    ("qty", @frame.SortOrder::Desc, @frame.NullOrder::NullsFirst),
  ]
  assert_eq(lazy_frame(df).sort_by(keys).collect(), df.sort_by(keys))
  assert_eq(lazy_frame(df).head(2).collect(), df.head(2))
  assert_eq(lazy_frame(df).tail(2).collect(), df.tail(2))
  assert_eq(lazy_frame(df).slice(1, 3).collect(), df.slice(1, 3))
}

///|
test "head, tail, and limit inherit the eager total clamp" {
  let df = sales_df()
  // Beyond the frame: every row survives, nothing raises.
  assert_eq(lazy_frame(df).head(100).collect(), df)
  assert_eq(lazy_frame(df).tail(100).collect(), df)
  // Negative n clamps to zero rows, mirroring eager head.
  assert_eq(lazy_frame(df).head(-1).collect(), df.head(-1))
  assert_eq(lazy_frame(df).head(-1).collect().nrows(), 0)
  // limit is head under its SQL name.
  assert_eq(lazy_frame(df).limit(2).collect(), df.head(2))
}

///|
test "every join type collects to its eager equivalent" {
  let l = orders_df()
  let r = cities_df()
  let on_id = @frame.JoinOptions::on(["id"])
  for
    how in [
      @frame.JoinType::Inner,
      @frame.JoinType::Left,
      @frame.JoinType::Right,
      @frame.JoinType::Outer,
    ] {
    let opts = on_id.with_how(how)
    assert_eq(
      lazy_frame(l).join(lazy_frame(r), opts).collect(),
      l.join(r, opts),
    )
  }
  let cross = @frame.JoinOptions::cross()
  assert_eq(
    lazy_frame(l).join(lazy_frame(r), cross).collect(),
    l.join(r, cross),
  )
}

///|
test "a composite pipeline collects bitwise-equal to the eager chain" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(10))
  let derived = [(@expr.col("qty") - @expr.col("bonus")).with_alias("net")]
  let keys = [("net", @frame.SortOrder::Desc, @frame.NullOrder::NullsLast)]
  let projection = [@expr.col("region"), @expr.col("net")]
  let lazy_out = lazy_frame(df)
    .filter_where(predicate)
    .with_columns(derived)
    .sort_by(keys)
    .select_exprs(projection)
    .head(2)
    .collect()
  let eager_out = df
    .filter_where(predicate)
    .with_columns(derived)
    .sort_by(keys)
    .select_exprs(projection)
    .head(2)
  assert_eq(lazy_out, eager_out)
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "join inputs run their own deferred sub-pipelines" {
  let l = orders_df()
  let r = cities_df()
  let amount_gate = @expr.col("amount").ge(@expr.lit_int(20))
  let opts = @frame.JoinOptions::on(["id"]).with_how(@frame.JoinType::Left)
  let lazy_out = lazy_frame(l)
    .filter_where(amount_gate)
    .join(lazy_frame(r).head(2), opts)
    .collect()
  assert_eq(lazy_out, l.filter_where(amount_gate).join(r.head(2), opts))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "builders share structure: extending a plan leaves the base intact" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(10))
  let base = lazy_frame(df).filter_where(predicate)
  let eager = df.filter_where(predicate)
  // Two diverging extensions of the same base…
  let first = base.head(2)
  let last = base.tail(1)
  assert_not_eq(first.collect(), last.collect())
  assert_eq(first.collect(), eager.head(2))
  assert_eq(last.collect(), eager.tail(1))
  // …and the base plan itself is untouched by either.
  assert_eq(base.collect(), eager)
}

///|
test "building a doomed plan succeeds; the error waits for collect" {
  let plan = lazy_frame(sales_df()).filter_where(
    @expr.col("zzz").gt(@expr.lit_int(0)),
  )
  // Building and introspecting are total even though collecting will fail
  // — inspect first, compute later.
  assert_eq(plan.explain(), "FILTER (col(zzz) > 0)\n  SCAN [4×3]")
  assert_eq(try? plan.collect(), Err(@types.DataError::ColumnNotFound("zzz")))
}

///|
test "collect surfaces the eager operators' errors unchanged" {
  let df = sales_df()
  // Non-Bool predicate → the eager filter_where TypeMismatch.
  assert_eq(
    try? lazy_frame(df).filter_where(@expr.col("qty")).collect(),
    Err(
      @types.DataError::TypeMismatch(
        "filter_where predicate must be Bool, got Int",
      ),
    ),
  )
  // Out-of-range slice bound → IndexOutOfBounds(end), as in eager slice.
  assert_eq(
    try? lazy_frame(df).slice(2, 99).collect(),
    Err(@types.DataError::IndexOutOfBounds(99)),
  )
  // Inverted slice window and a missing sort column: equal to the eager
  // errors, message for message.
  assert_eq(try? lazy_frame(df).slice(3, 1).collect(), try? df.slice(3, 1))
  let bad_keys = [("zzz", @frame.SortOrder::Asc, @frame.NullOrder::NullsFirst)]
  assert_eq(
    try? lazy_frame(df).sort_by(bad_keys).collect(),
    try? df.sort_by(bad_keys),
  )
}

///|
test "a deferred group-by collects to the eager agg_exprs equivalent" {
  let df = sales_df()
  let aggs = [
    @expr.col("qty").sum().with_alias("total"),
    @expr.col("bonus").mean().with_alias("avg_bonus"),
    (@expr.col("qty") * @expr.col("bonus")).sum().with_alias("weighted"),
    (@expr.col("qty").max() - @expr.col("qty").min()).with_alias("spread"),
  ]
  let lazy_out = lazy_frame(df).group_by(["region"]).agg(aggs).collect()
  assert_eq(lazy_out, df.group_by(["region"]).agg_exprs(aggs))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "multi-key and empty aggregation lists mirror eager group-by" {
  let df = sales_df()
  let count = [@expr.col("bonus").count().with_alias("n")]
  assert_eq(
    lazy_frame(df).group_by(["region", "qty"]).agg(count).collect(),
    df.group_by(["region", "qty"]).agg_exprs(count),
  )
  // No aggregations: the distinct-over-keys frame, exactly as eager.
  assert_eq(
    lazy_frame(df).group_by(["region"]).agg([]).collect(),
    df.group_by(["region"]).agg_exprs([]),
  )
}

///|
test "a group-by pipeline composes with the other deferred verbs" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(10))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let aggs = [@expr.col("dbl").sum().with_alias("total")]
  let keys = [("total", @frame.SortOrder::Desc, @frame.NullOrder::NullsLast)]
  let lazy_out = lazy_frame(df)
    .filter_where(predicate)
    .with_columns(derived)
    .group_by(["region"])
    .agg(aggs)
    .sort_by(keys)
    .head(1)
    .collect()
  let eager_out = df
    .filter_where(predicate)
    .with_columns(derived)
    .group_by(["region"])
    .agg_exprs(aggs)
    .sort_by(keys)
    .head(1)
  assert_eq(lazy_out, eager_out)
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "one LazyGroupBy serves diverging aggregations" {
  let df = sales_df()
  let grouped = lazy_frame(df).group_by(["region"])
  let total = [@expr.col("qty").sum().with_alias("total")]
  let n = [@expr.col("qty").count().with_alias("n")]
  // Two aggregations off the same LazyGroupBy fork the plan — neither
  // disturbs the other, like every other shared builder.
  assert_eq(
    grouped.agg(total).collect(),
    df.group_by(["region"]).agg_exprs(total),
  )
  assert_eq(grouped.agg(n).collect(), df.group_by(["region"]).agg_exprs(n))
}

///|
test "group-by building is total; the errors wait for collect" {
  let df = sales_df()
  // Missing key: the plan builds and explains, then collect surfaces the
  // eager group_by's ColumnNotFound.
  let missing = lazy_frame(df).group_by(["zzz"]).agg([])
  assert_eq(missing.explain(), "AGGREGATE [] BY [zzz]\n  SCAN [4×3]")
  assert_eq(
    try? missing.collect(),
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
  // Repeated key → the eager group_by DuplicateColumn, at the repeat.
  assert_eq(
    try? lazy_frame(df).group_by(["region", "region"]).agg([]).collect(),
    Err(@types.DataError::DuplicateColumn("region")),
  )
  // A bare column is not reduction-shaped → the eager agg_exprs
  // InvalidOperation, message for message.
  assert_eq(
    try? lazy_frame(df).group_by(["region"]).agg([@expr.col("qty")]).collect(),
    try? df.group_by(["region"]).agg_exprs([@expr.col("qty")]),
  )
  // Summing a String column → the eager agg_exprs TypeMismatch.
  assert_eq(
    try? lazy_frame(df)
    .group_by(["qty"])
    .agg([@expr.col("region").sum()])
    .collect(),
    try? df.group_by(["qty"]).agg_exprs([@expr.col("region").sum()]),
  )
}

///|
test "a zero-row source aggregates to zero groups" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("qty", []),
    @series.Series::from_strings("region", []),
  ])
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let lazy_out = lazy_frame(df).group_by(["region"]).agg(aggs).collect()
  assert_eq(lazy_out, df.group_by(["region"]).agg_exprs(aggs))
  assert_eq(lazy_out.shape(), (0, 2))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "a zero-row source flows through the whole pipeline" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("qty", []),
    @series.Series::from_strings("region", []),
  ])
  let predicate = @expr.col("qty").gt(@expr.lit_int(0))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let lazy_out = lazy_frame(df)
    .filter_where(predicate)
    .with_columns(derived)
    .head(5)
    .collect()
  let eager_out = df.filter_where(predicate).with_columns(derived).head(5)
  assert_eq(lazy_out, eager_out)
  assert_eq(lazy_out.shape(), (0, 3))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}
