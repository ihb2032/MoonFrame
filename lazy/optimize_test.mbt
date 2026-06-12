///|
/// Blackbox equivalence battery for the projection pushdown `collect`
/// runs in front of the executor. Narrowing is invisible by design — the
/// optimizer's whole contract is that `collect` stays bitwise-equal to
/// the eager chain — so these tests pin the contract on exactly the
/// pipelines where the rewrite fires (and on the guards where it must
/// not), plus error parity at collect time. The structural before/after
/// shape of the rewrite itself is pinned in `optimize_wbtest.mbt`; the
/// shared fixture frames live in `lazy_test.mbt`.

///|
test "narrowed scan: a single-column selection still collects equal" {
  let df = sales_df()
  // Only `qty` is read; `bonus` / `region` are pruned at the scan.
  let exprs = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let out = lazy_frame(df).select_exprs(exprs).collect()
  assert_eq(out, df.select_exprs(exprs))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "filter predicate columns stay alive through the pushdown" {
  let df = sales_df()
  // The selection reads `region` only, but the filter needs `qty`: the
  // narrowed scan must keep both (and may drop `bonus`).
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let projection = [@expr.col("region")]
  assert_eq(
    lazy_frame(df).filter_where(predicate).select_exprs(projection).collect(),
    df.filter_where(predicate).select_exprs(projection),
  )
}

///|
test "a ternary's condition columns stay alive through the pushdown" {
  let df = sales_df()
  // The label only *outputs* literal/region values, but its condition
  // reads `qty` — `referenced_columns` must keep it in the scan.
  let label = @expr.when(@expr.col("qty").gt(@expr.lit_int(100)))
    .then(@expr.lit_str("big"))
    .otherwise(@expr.col("region"))
    .with_alias("label")
  assert_eq(
    lazy_frame(df).select_exprs([label]).collect(),
    df.select_exprs([label]),
  )
}

///|
test "with_columns replacement: narrowing turns replace into append, by-name reads agree" {
  let df = sales_df()
  // `bonus` is *redefined* from `qty`, then read by the selection. The
  // pushdown drops the original `bonus` from the scan (a defined name is
  // served by the with_columns stage itself), so the eager side replaces
  // in place while the optimized side appends — and the by-name
  // selection above must make the difference unobservable.
  let redefine = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("bonus")]
  let projection = [@expr.col("bonus"), @expr.col("region")]
  assert_eq(
    lazy_frame(df).with_columns(redefine).select_exprs(projection).collect(),
    df.with_columns(redefine).select_exprs(projection),
  )
}

///|
test "with_columns: a brand-new derived name needs nothing from the scan" {
  let df = sales_df()
  let fresh = [(@expr.col("qty") + @expr.lit_int(1)).with_alias("next")]
  let projection = [@expr.col("next")]
  assert_eq(
    lazy_frame(df).with_columns(fresh).select_exprs(projection).collect(),
    df.with_columns(fresh).select_exprs(projection),
  )
}

///|
test "aggregate prunes columns no key or aggregation reads" {
  let df = sales_df()
  // Keys read `region`, the aggregations read `qty` — `bonus` is dead.
  let aggs = [
    @expr.col("qty").sum().with_alias("total"),
    (@expr.col("qty").max() - @expr.col("qty").min()).with_alias("spread"),
  ]
  assert_eq(
    lazy_frame(df).group_by(["region"]).agg(aggs).collect(),
    df.group_by(["region"]).agg_exprs(aggs),
  )
}

///|
test "sort keys stay alive through the pushdown" {
  let df = sales_df()
  let keys = [("bonus", @frame.SortOrder::Asc, @frame.NullOrder::NullsLast)]
  let projection = [@expr.col("region")]
  assert_eq(
    lazy_frame(df).sort_by(keys).select_exprs(projection).collect(),
    df.sort_by(keys).select_exprs(projection),
  )
}

///|
test "row windows pass the requirement through to the scan" {
  let df = sales_df()
  let projection = [@expr.col("qty")]
  assert_eq(
    lazy_frame(df).head(2).select_exprs(projection).collect(),
    df.head(2).select_exprs(projection),
  )
  assert_eq(
    lazy_frame(df).tail(2).select_exprs(projection).collect(),
    df.tail(2).select_exprs(projection),
  )
  assert_eq(
    lazy_frame(df).slice(1, 3).select_exprs(projection).collect(),
    df.slice(1, 3).select_exprs(projection),
  )
}

///|
test "join sides narrow independently below the barrier" {
  let l = orders_df()
  let r = cities_df()
  let opts = @frame.JoinOptions::on(["id"])
  // The left side's own selection prunes `amount` before the join.
  assert_eq(
    lazy_frame(l)
    .select_exprs([@expr.col("id")])
    .join(lazy_frame(r), opts)
    .collect(),
    l.select_exprs([@expr.col("id")]).join(r, opts),
  )
  // A selection *above* the join must not narrow either side.
  assert_eq(
    lazy_frame(l)
    .join(lazy_frame(r), opts)
    .select_exprs([@expr.col("city")])
    .collect(),
    l.join(r, opts).select_exprs([@expr.col("city")]),
  )
}

///|
test "guard: an all-literal selection inserts nothing and still collapses to one row" {
  let df = sales_df()
  let one = [@expr.lit_int(1).with_alias("one")]
  let out = lazy_frame(df).select_exprs(one).collect()
  assert_eq(out, df.select_exprs(one))
  assert_eq(out.nrows(), 1)
}

///|
test "guard: a selection reading every column leaves the scan whole" {
  let df = sales_df()
  let all = [@expr.col("qty"), @expr.col("bonus"), @expr.col("region")]
  assert_eq(lazy_frame(df).select_exprs(all).collect(), df.select_exprs(all))
}

///|
test "the flagship pipeline narrows through every stage" {
  let df = sales_df()
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let derived = [(@expr.col("qty") * @expr.lit_int(3)).with_alias("adj")]
  let projection = [@expr.col("adj")]
  let out = lazy_frame(df)
    .filter_where(predicate)
    .with_columns(derived)
    .select_exprs(projection)
    .collect()
  assert_eq(
    out,
    df.filter_where(predicate).with_columns(derived).select_exprs(projection),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a zero-row frame narrows and collects equal" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", []),
    @frame.Series::from_strings("b", []),
  ])
  let projection = [@expr.col("a")]
  let out = lazy_frame(df).select_exprs(projection).collect()
  assert_eq(out, df.select_exprs(projection))
  assert_eq(out.nrows(), 0)
}

///|
test "errors keep surfacing at collect time, unchanged by the rewrite" {
  let df = sales_df()
  // A missing column in the selection: the inserted narrowing select
  // keeps only existing columns, so the user's expression still reports
  // the same `ColumnNotFound`.
  assert_eq(
    try? lazy_frame(df).select_exprs([@expr.col("ghost")]).collect(),
    Err(@types.DataError::ColumnNotFound("ghost")),
  )
  // A missing column in a filter under a selection: parity with eager.
  let predicate = @expr.col("ghost").is_null()
  let projection = [@expr.col("qty")]
  assert_eq(
    try? lazy_frame(df)
    .filter_where(predicate)
    .select_exprs(projection)
    .collect(),
    try? df.filter_where(predicate).select_exprs(projection),
  )
}

///|
test "explain still renders the plan as built, not the optimized one" {
  let plan = lazy_frame(sales_df()).select_exprs([@expr.col("qty")])
  // No inserted narrowing select is visible: optimization happens inside
  // collect, on a copy of the plan.
  assert_eq(plan.explain(), "SELECT [col(qty)]\n  SCAN [4×3]")
}
