///|
/// Blackbox battery for the optimizer rewrites `collect` runs in front
/// of the executor — the predicate pass that sinks filters toward the
/// scan, and the projection pushdown that narrows scans to the columns
/// actually read. Two halves. The *equivalence* tests pin the
/// optimizer's contract — `collect` stays bitwise-equal to the eager
/// chain, with error parity, exactly on the pipelines where a rewrite
/// fires and on the fences where it must not (several fences guard real
/// divergences: a broadcast aggregation's scope, a `mean`'s
/// backend-flipping null cell, a `cast`'s value-dependent rejection).
/// The *structural* tests pin what the rewrites did to the tree — which
/// filters sank below which stages, which scans narrowed, in which
/// column order, and which arms must stay no-ops — by snapshotting
/// `explain(optimized=true)` against the as-built `explain()`: the
/// before/after pair. The shared fixture frames live in `lazy_test.mbt`.

///|
test "narrowed scan: a single-column selection still collects equal" {
  let df = sales_df()
  // Only `qty` is read; `bonus` / `region` are pruned at the scan.
  let exprs = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let out = lazy_frame(df).select(exprs).collect()
  assert_eq(out, df.select(exprs))
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
    lazy_frame(df).filter_where(predicate).select(projection).collect(),
    df.filter_where(predicate).select(projection),
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
  assert_eq(lazy_frame(df).select([label]).collect(), df.select([label]))
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
    lazy_frame(df).with_columns(redefine).select(projection).collect(),
    df.with_columns(redefine).select(projection),
  )
}

///|
test "with_columns: a brand-new derived name needs nothing from the scan" {
  let df = sales_df()
  let fresh = [(@expr.col("qty") + @expr.lit_int(1)).with_alias("next")]
  let projection = [@expr.col("next")]
  assert_eq(
    lazy_frame(df).with_columns(fresh).select(projection).collect(),
    df.with_columns(fresh).select(projection),
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
    df.group_by(["region"]).agg(aggs),
  )
}

///|
test "sort keys stay alive through the pushdown" {
  let df = sales_df()
  let keys = [("bonus", @frame.SortOrder::Asc, @frame.NullOrder::NullsLast)]
  let projection = [@expr.col("region")]
  assert_eq(
    lazy_frame(df).sort_by(keys).select(projection).collect(),
    df.sort_by(keys).select(projection),
  )
}

///|
test "row windows pass the requirement through to the scan" {
  let df = sales_df()
  let projection = [@expr.col("qty")]
  assert_eq(
    lazy_frame(df).head(2).select(projection).collect(),
    df.head(2).select(projection),
  )
  assert_eq(
    lazy_frame(df).tail(2).select(projection).collect(),
    df.tail(2).select(projection),
  )
  assert_eq(
    lazy_frame(df).slice(1, 3).select(projection).collect(),
    df.slice(1, 3).select(projection),
  )
}

///|
test "join sides narrow independently below the barrier" {
  let l = orders_df()
  let r = cities_df()
  let opts = @frame.JoinOptions::on(["id"])
  // The left side's own selection prunes `amount` before the join.
  assert_eq(
    lazy_frame(l).select([@expr.col("id")]).join(lazy_frame(r), opts).collect(),
    l.select([@expr.col("id")]).join(r, opts),
  )
  // A selection *above* the join must not narrow either side.
  assert_eq(
    lazy_frame(l)
    .join(lazy_frame(r), opts)
    .select([@expr.col("city")])
    .collect(),
    l.join(r, opts).select([@expr.col("city")]),
  )
}

///|
test "guard: an all-literal selection inserts nothing and still collapses to one row" {
  let df = sales_df()
  let one = [@expr.lit_int(1).with_alias("one")]
  let out = lazy_frame(df).select(one).collect()
  assert_eq(out, df.select(one))
  assert_eq(out.nrows(), 1)
}

///|
test "guard: a selection reading every column leaves the scan whole" {
  let df = sales_df()
  let all = [@expr.col("qty"), @expr.col("bonus"), @expr.col("region")]
  assert_eq(lazy_frame(df).select(all).collect(), df.select(all))
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
    .select(projection)
    .collect()
  assert_eq(
    out,
    df.filter_where(predicate).with_columns(derived).select(projection),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a zero-row frame narrows and collects equal" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("a", []),
    @series.Series::from_strings("b", []),
  ])
  let projection = [@expr.col("a")]
  let out = lazy_frame(df).select(projection).collect()
  assert_eq(out, df.select(projection))
  assert_eq(out.nrows(), 0)
}

///|
test "errors keep surfacing at collect time, unchanged by the rewrite" {
  let df = sales_df()
  // A missing column in the selection: the inserted narrowing select
  // keeps only existing columns, so the user's expression still reports
  // the same `ColumnNotFound`.
  assert_eq(
    try? lazy_frame(df).select([@expr.col("ghost")]).collect(),
    Err(@types.DataError::ColumnNotFound("ghost")),
  )
  // A missing column in a filter under a selection: parity with eager.
  let predicate = @expr.col("ghost").is_null()
  let projection = [@expr.col("qty")]
  assert_eq(
    try? lazy_frame(df).filter_where(predicate).select(projection).collect(),
    try? df.filter_where(predicate).select(projection),
  )
}

///|
test "explain defaults to the plan as built; optimized=true is the before/after pair" {
  let plan = lazy_frame(sales_df()).select([@expr.col("qty")])
  // Before: the chain verbatim — and the default is pinned to
  // `optimized=false` explicitly.
  assert_eq(plan.explain(), "SELECT [col(qty)]\n  SCAN [4×3]")
  assert_eq(plan.explain(), plan.explain(optimized=false))
  // After: the narrowing select `collect` actually runs is visible.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty)]\n" + "  SELECT [col(qty)]\n" + "    SCAN [4×3]",
  )
}

///|
test "explain(optimized=true) rewrites a copy: the plan itself is unperturbed" {
  let df = sales_df()
  let plan = lazy_frame(df).select([@expr.col("region")])
  let optimized = plan.explain(optimized=true)
  // Rendering the optimized form is stable across calls, and it perturbs
  // neither the as-built rendering nor what collect returns.
  assert_eq(plan.explain(optimized=true), optimized)
  assert_eq(plan.explain(), "SELECT [col(region)]\n  SCAN [4×3]")
  assert_eq(plan.collect(), df.select([@expr.col("region")]))
}

///|
test "a bare scan is untouched (no requirement at the root)" {
  assert_eq(lazy_frame(sales_df()).explain(optimized=true), "SCAN [4×3]")
}

///|
test "select: a proper-subset requirement narrows the scan, in scan column order" {
  let plan = lazy_frame(sales_df()).select([
    (@expr.col("bonus") + @expr.col("qty")).with_alias("t"),
  ])
  // The inserted projection follows the *frame's* column order
  // (qty before bonus), not the expression's reference order.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [(col(bonus) + col(qty)) as t]\n" +
    "  SELECT [col(qty), col(bonus)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "select guard: reading every column inserts nothing" {
  let plan = lazy_frame(sales_df()).select([
    @expr.col("qty"),
    @expr.col("bonus"),
    @expr.col("region"),
  ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "select guard: an all-literal selection inserts nothing" {
  let plan = lazy_frame(sales_df()).select([@expr.lit_int(1).with_alias("one")])
  assert_eq(plan.explain(optimized=true), "SELECT [1 as one]\n  SCAN [4×3]")
}

///|
test "select: a missing column is not kept alive, the rest narrow as usual" {
  let plan = lazy_frame(sales_df()).select([
    @expr.col("qty"),
    @expr.col("ghost"),
  ])
  // `ghost` exists nowhere, so only `qty` survives at the scan; the
  // user's expression still raises its own `ColumnNotFound` at collect.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty), col(ghost)]\n" +
    "  SELECT [col(qty)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "filter: the requirement passes through, widened by the predicate's columns" {
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = lazy_frame(sales_df())
    .filter_where(predicate)
    .select([@expr.col("region")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  // At the root the requirement is unbounded: a bare filter's layout may
  // be observed in full, so nothing narrows.
  let bare = lazy_frame(sales_df()).filter_where(predicate)
  assert_eq(bare.explain(optimized=true), bare.explain())
}

///|
test "sort: the requirement passes through, widened by the sort keys" {
  let plan = lazy_frame(sales_df())
    .sort_by([("bonus", @frame.SortOrder::Asc, @frame.NullOrder::NullsLast)])
    .select([@expr.col("qty")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  SORT [bonus Asc NullsLast]\n" +
    "    SELECT [col(qty), col(bonus)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "row windows pass the requirement through verbatim" {
  let base = lazy_frame(sales_df())
  let qty = [@expr.col("qty")]
  assert_eq(
    base.head(2).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  HEAD 2\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    base.tail(1).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  TAIL 1\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    base.slice(1, 3).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  SLICE [1, 3)\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns: defined names are subtracted, read names added" {
  let plan = lazy_frame(sales_df())
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")])
    .select([@expr.col("dbl"), @expr.col("region")])
  // `dbl` is served by the with_columns stage itself; the scan only owes
  // `region` (selected) and `qty` (read by the derivation).
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(dbl), col(region)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as dbl]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns: redefining a selected column keeps only what it reads" {
  let plan = lazy_frame(sales_df())
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("bonus")])
    .select([@expr.col("bonus")])
  // The selected `bonus` is a *defined* name: the original scan column
  // is dead, and only the derivation's input `qty` survives.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(bonus)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as bonus]\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns at the root is a no-op (its full layout is the result)" {
  let plan = lazy_frame(sales_df()).with_columns([
    (@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl"),
  ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "join is a barrier, but each side restarts its own pass" {
  let opts = @frame.JoinOptions::on(["id"])
  // A selection *below* the left side narrows that side's scan.
  let narrowed_side = lazy_frame(orders_df())
    .select([@expr.col("id")])
    .join(lazy_frame(cities_df()), opts)
  assert_eq(
    narrowed_side.explain(optimized=true),
    "JOIN Inner on [id]\n" +
    "  SELECT [col(id)]\n" +
    "    SELECT [col(id)]\n" +
    "      SCAN [3×2]\n" +
    "  SCAN [3×2]",
  )
  // A selection *above* the join narrows neither side: splitting a
  // requirement across suffix-renamed sides is O2-grade provenance.
  let above = lazy_frame(orders_df())
    .join(lazy_frame(cities_df()), opts)
    .select([@expr.col("city")])
  assert_eq(above.explain(optimized=true), above.explain())
}

///|
test "aggregate: keys and aggregation reads survive, the rest narrows" {
  let plan = lazy_frame(sales_df())
    .group_by(["region"])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total] BY [region]\n" +
    "  SELECT [col(qty), col(region)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "aggregate guard: reading every column inserts nothing" {
  let plan = lazy_frame(sales_df())
    .group_by(["region"])
    .agg([
      @expr.col("qty").sum().with_alias("a"),
      @expr.col("bonus").max().with_alias("b"),
    ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "nested selects: the outer requirement never prunes the inner expression list" {
  let plan = lazy_frame(sales_df())
    .select([
      (@expr.col("qty") + @expr.col("bonus")).with_alias("t"),
      @expr.col("region"),
    ])
    .select([@expr.col("t")])
  // Dead-expression elimination is deferred: the inner select still
  // evaluates `region`, and — reading every scan column — it also
  // inserts nothing below itself.
  assert_eq(plan.explain(optimized=true), plan.explain())
}

// ── The predicate pass ──────────────────────────────────────────────────

///|
test "a trailing filter sinks below a bare-column selection" {
  let df = sales_df()
  let projection = [@expr.col("qty"), @expr.col("region")]
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = lazy_frame(df).select(projection).filter_where(predicate)
  // The filter lands between the selection and the (narrowed) scan: rows
  // drop before the projection evaluates, columns before the rows load.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty), col(region)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.select(projection).filter_where(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a trailing filter sinks below a derived-column stage" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter_where(predicate)
  // `dbl` is defined by the stage but not read by the predicate, so the
  // filter crosses; at the root nothing requires columns, so no scan
  // narrowing fires.
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [(col(qty) * 2) as dbl]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.with_columns(derived).filter_where(predicate))
}

///|
test "fence: a predicate reading a name the stage defines stays above" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let predicate = @expr.col("dbl").gt(@expr.lit_int(100))
  let plan = lazy_frame(df).with_columns(derived).filter_where(predicate)
  // Below the stage `dbl` does not exist: the filter must wait for it.
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.with_columns(derived).filter_where(predicate))
}

///|
test "fence: a broadcast aggregation inside with_columns pins the filter above" {
  let df = sales_df()
  // `total` broadcasts sum(qty) over *all* rows; filtering first would
  // recompute it over the survivors (85, not 405).
  let derived = [@expr.col("qty").sum().with_alias("total")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter_where(predicate)
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.with_columns(derived).filter_where(predicate))
}

///|
test "fence: a cast inside the stage pins the filter above" {
  let df = sales_df()
  // A cast's parse / range rejection raises on the values it meets:
  // filtering first could drop the very row that raises, so no filter
  // crosses a cast-bearing stage even when (as here) every cast succeeds.
  let derived = [@expr.col("qty").cast(@types.DataType::Float).with_alias("f")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter_where(predicate)
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.with_columns(derived).filter_where(predicate))
}

///|
test "fence: a computed occurrence of the predicate's column is not a bare pass-through" {
  let df = sales_df()
  let projection = [
    (@expr.col("qty") * @expr.lit_int(2)).with_alias("qty2"),
    @expr.col("region"),
  ]
  let predicate = @expr.col("qty2").gt(@expr.lit_int(100))
  let plan = lazy_frame(df).select(projection).filter_where(predicate)
  // `qty2` exists only above the selection, so the filter stays at the
  // root — while the projection pass still narrows the scan below.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(qty2) > 100)\n" +
    "  SELECT [(col(qty) * 2) as qty2, col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter_where(predicate))
}

///|
test "fence: an aggregating selection pins the filter above" {
  let df = sales_df()
  // The selection broadcasts sum(qty) beside `region`: dropping rows
  // first would change the broadcast value, so the filter stays above.
  let projection = [
    @expr.col("region"),
    @expr.col("qty").sum().with_alias("total"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).select(projection).filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  SELECT [col(region), col(qty).sum() as total]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter_where(predicate))
}

///|
test "a scope-dependent predicate still crosses a bare selection" {
  let df = sales_df()
  // The predicate's own mean is computed over the filter's input scope —
  // and a bare selection neither adds nor drops rows, so that scope is
  // identical on both sides of the swap.
  let projection = [@expr.col("qty"), @expr.col("region")]
  let predicate = @expr.col("qty").gt(@expr.col("qty").mean())
  let plan = lazy_frame(df).select(projection).filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty), col(region)]\n" +
    "  FILTER (col(qty) > col(qty).mean())\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter_where(predicate))
}

///|
test "a key predicate sinks below an aggregation" {
  let df = sales_df()
  let aggs = [
    @expr.col("qty").sum().with_alias("total"),
    @expr.col("bonus").count().with_alias("n"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  // Every row of a group shares its key tuple, so filtering rows by key
  // before grouping drops exactly the groups the filter would have
  // dropped after — and sum / count cells can never be null, so the
  // stitched columns' backend cannot flip when groups disappear.
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total, col(bonus).count() as n] BY [region]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.group_by(["region"]).agg(aggs).filter_where(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a key predicate that empties every group still collects equal" {
  let df = sales_df()
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let predicate = @expr.col("region").eq(@expr.lit_str("north"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  // Below the aggregation the filter leaves zero rows, so the executor
  // aggregates zero groups — the empty-scope probe in `agg` pins
  // the output dtype, keeping the 0-row frames bitwise-equal.
  let out = plan.collect()
  assert_eq(out, df.group_by(["region"]).agg(aggs).filter_where(predicate))
  assert_eq(out.nrows(), 0)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a predicate reading an aggregation output stays above" {
  let df = sales_df()
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let predicate = @expr.col("total").gt(@expr.lit_int(100))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  // `total` is not a key: it only exists above the aggregation.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(total) > 100)\n" +
    "  AGGREGATE [col(qty).sum() as total] BY [region]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by(["region"]).agg(aggs).filter_where(predicate),
  )
}

///|
test "fence: a mean aggregation pins the filter above the group stage" {
  let df = sales_df()
  // The east group's bonus cells are all null, so its mean is a null
  // cell and the stitched column stays `Builtin`. Filtering rows first
  // would erase that group, leave only valid cells, and converge the
  // column onto the `Numeric` backend — bitwise-unequal output. The
  // fence is what keeps this assertion true.
  let aggs = [@expr.col("bonus").mean().with_alias("avg")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(bonus).mean() as avg] BY [region]\n" +
    "    SELECT [col(bonus), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by(["region"]).agg(aggs).filter_where(predicate),
  )
}

///|
test "fence: a cast in the aggregation list pins the filter above" {
  let df = sales_df()
  let aggs = [
    @expr.col("qty").sum().cast(@types.DataType::Float).with_alias("totalf"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(qty).sum().cast(Float) as totalf] BY [region]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by(["region"]).agg(aggs).filter_where(predicate),
  )
}

///|
test "fence: a scope-dependent key predicate stays above the aggregation" {
  let df = sales_df()
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  // Reads only the key — but its count runs over the aggregation's
  // output rows (one per group), not the raw rows, so it must not move.
  let predicate = @expr.col("region").count().gt(@expr.lit_int(1))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region).count() > 1)\n" +
    "  AGGREGATE [col(qty).sum() as total] BY [region]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by(["region"]).agg(aggs).filter_where(predicate),
  )
}

///|
test "fence: a non-reduction aggregation keeps its error and its filter in place" {
  let df = sales_df()
  let aggs = [@expr.col("qty")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  // A bare column is not reduction-shaped; the fence holds the filter
  // above, and collect reports the executor's own `InvalidOperation`.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(qty)] BY [region]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    try? plan.collect(),
    try? df.group_by(["region"]).agg(aggs).filter_where(predicate),
  )
}

///|
test "fence: a null literal in the aggregation list pins the filter above" {
  let df = sales_df()
  let aggs = [@expr.lit(@types.Scalar::Null).with_alias("z")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  // A null literal is a null cell by definition — the backend-flip
  // hazard in its purest form — so the filter stays above, and collect
  // behaves exactly as the as-built plan does.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [null as z] BY [region]\n" +
    "    SELECT [col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    try? plan.collect(),
    try? df.group_by(["region"]).agg(aggs).filter_where(predicate),
  )
}

///|
test "reduction combinators pass the aggregation crossing gate" {
  let df = sales_df()
  // Ternary selection, comparisons, literals, and negation over sum
  // cells are all null-free and value-safe, so the key filter crosses.
  let aggs = [
    @expr.when(@expr.col("qty").sum().gt(@expr.lit_int(100)))
    .then(@expr.lit_int(1))
    .otherwise(@expr.lit_int(0))
    .with_alias("flag"),
    (-@expr.col("qty").sum()).with_alias("neg"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by(["region"])
    .agg(aggs)
    .filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [when((col(qty).sum() > 100)).then(1).otherwise(0) as flag, (-col(qty).sum()) as neg] BY [region]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.group_by(["region"]).agg(aggs).filter_where(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "row windows stop the descent" {
  let df = sales_df()
  // Positions are not values: head(2) then filter keeps [120], while
  // filtering first would re-number the rows and keep [120, 200].
  let predicate = @expr.col("qty").gt(@expr.lit_int(100))
  let on_head = lazy_frame(df).head(2).filter_where(predicate)
  assert_eq(on_head.explain(optimized=true), on_head.explain())
  assert_eq(on_head.collect(), df.head(2).filter_where(predicate))
  assert_eq(
    lazy_frame(df).tail(2).filter_where(predicate).collect(),
    df.tail(2).filter_where(predicate),
  )
  assert_eq(
    lazy_frame(df).slice(1, 3).filter_where(predicate).collect(),
    df.slice(1, 3).filter_where(predicate),
  )
}

///|
test "sort stops the descent" {
  let df = sales_df()
  let keys = [("qty", @frame.SortOrder::Asc, @frame.NullOrder::NullsLast)]
  let predicate = @expr.col("qty").gt(@expr.lit_int(100))
  let plan = lazy_frame(df).sort_by(keys).filter_where(predicate)
  // Crossing a sort is deliberately deferred — the filter stays put.
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.sort_by(keys).filter_where(predicate))
}

///|
test "stacked filters sink together and keep their order" {
  let df = sales_df()
  let projection = [@expr.col("qty"), @expr.col("bonus")]
  let first = @expr.col("bonus").is_not_null()
  let second = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = lazy_frame(df)
    .select(projection)
    .filter_where(first)
    .filter_where(second)
  // Both predicates cross the selection; one filter never crosses
  // another, so the earlier one stays the deeper (first-evaluated) one.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty), col(bonus)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    FILTER col(bonus).is_not_null()\n" +
    "      SELECT [col(qty), col(bonus)]\n" +
    "        SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.select(projection).filter_where(first).filter_where(second),
  )
}

///|
test "a filter above a join stays; one inside a side still sinks" {
  let l = orders_df()
  let r = cities_df()
  let opts = @frame.JoinOptions::on(["id"])
  // Above: splitting a predicate across suffix-renamed sides is column
  // provenance, deferred — the join is a barrier.
  let above = lazy_frame(l)
    .join(lazy_frame(r), opts)
    .filter_where(@expr.col("amount").gt(@expr.lit_int(15)))
  assert_eq(above.explain(optimized=true), above.explain())
  assert_eq(
    above.collect(),
    l.join(r, opts).filter_where(@expr.col("amount").gt(@expr.lit_int(15))),
  )
  // Inside: each side restarts its own descent, so a filter built into
  // the left pipeline sinks below that side's selection.
  let gate = @expr.col("amount").gt(@expr.lit_int(15))
  let inside = lazy_frame(l)
    .select([@expr.col("id"), @expr.col("amount")])
    .filter_where(gate)
    .join(lazy_frame(r), opts)
  assert_eq(
    inside.explain(optimized=true),
    "JOIN Inner on [id]\n" +
    "  SELECT [col(id), col(amount)]\n" +
    "    FILTER (col(amount) > 15)\n" +
    "      SCAN [3×2]\n" +
    "  SCAN [3×2]",
  )
  assert_eq(
    inside.collect(),
    l
    .select([@expr.col("id"), @expr.col("amount")])
    .filter_where(gate)
    .join(r, opts),
  )
}

///|
test "a doubly-broken plan may report the sunk filter's error first" {
  let df = sales_df()
  // Both stages are independently broken. As built, the derivation
  // evaluates first and reports `ghost1`; once the filter sinks below
  // it, the filter evaluates first and reports `ghost2`. Which of a
  // plan's several real errors surfaces was an artifact of stage order
  // to begin with — single-fault plans keep their exact error (next
  // test).
  let broken_stage = [(@expr.col("ghost1") + @expr.lit_int(1)).with_alias("g")]
  let broken_predicate = @expr.col("ghost2").is_null()
  let plan = lazy_frame(df)
    .with_columns(broken_stage)
    .filter_where(broken_predicate)
  assert_eq(
    try? plan.collect(),
    Err(@types.DataError::ColumnNotFound("ghost2")),
  )
  assert_eq(
    try? df.with_columns(broken_stage).filter_where(broken_predicate),
    Err(@types.DataError::ColumnNotFound("ghost1")),
  )
}

///|
test "single-fault errors survive the crossing unchanged" {
  let df = sales_df()
  // Broken stage, sound predicate: the sunk filter runs first and
  // passes; the stage still reports its own missing column.
  let broken_stage = [(@expr.col("ghost") + @expr.lit_int(1)).with_alias("g")]
  let key_predicate = @expr.col("region").eq(@expr.lit_str("west"))
  assert_eq(
    try? lazy_frame(df)
    .with_columns(broken_stage)
    .filter_where(key_predicate)
    .collect(),
    try? df.with_columns(broken_stage).filter_where(key_predicate),
  )
  // Sound stage, broken predicate: the predicate's missing column is
  // missing below the stage too — same error, earlier.
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let broken_predicate = @expr.col("ghost").gt(@expr.lit_int(1))
  assert_eq(
    try? lazy_frame(df)
    .with_columns(derived)
    .filter_where(broken_predicate)
    .collect(),
    try? df.with_columns(derived).filter_where(broken_predicate),
  )
}

///|
test "the flagship pipeline sinks its filter and narrows its scan" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(3)).with_alias("adj")]
  let projection = [@expr.col("adj"), @expr.col("region")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .with_columns(derived)
    .select(projection)
    .filter_where(predicate)
  // The trailing filter crosses both stages down to the scan, and the
  // projection pass narrows the scan beneath it: rows and columns both
  // drop before any stage computes.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(adj), col(region)]\n" +
    "  WITH_COLUMNS [(col(qty) * 3) as adj]\n" +
    "    FILTER (col(region) == \"west\")\n" +
    "      SELECT [col(qty), col(region)]\n" +
    "        SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(
    out,
    df.with_columns(derived).select(projection).filter_where(predicate),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "an all-literal predicate crosses vacuously" {
  let df = sales_df()
  let projection = [@expr.col("qty")]
  let predicate = @expr.lit_bool(true)
  let plan = lazy_frame(df).select(projection).filter_where(predicate)
  // No columns read means nothing to fence on: the filter sinks.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  FILTER true\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter_where(predicate))
}

///|
test "a dropping predicate cannot sink past a collapsing constant selection" {
  let df = sales_df()
  // An all-constant selection collapses any input — even zero rows — to a
  // single row, so a column-less predicate must NOT cross it: filtering
  // 4→0 first and then re-materialising the one literal row (1 row) would
  // disagree with the as-built collapse-then-drop (0 rows). The filter
  // stays put; only its harmless `true` counterpart above could sink.
  let one = [@expr.lit_int(1).with_alias("one")]
  let predicate = @expr.lit_bool(false)
  let plan = lazy_frame(df).select(one).filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER false\n" + "  SELECT [1 as one]\n" + "    SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.select(one).filter_where(predicate))
  assert_eq(out.nrows(), 0)
}

///|
test "row-local probes and ternaries cross with their stage" {
  let df = sales_df()
  // A null probe and a when/then/otherwise are row-local (no
  // aggregation, no cast), so the stage lets the key filter through.
  let derived = [
    @expr.col("bonus").is_null().with_alias("nb"),
    @expr.when(@expr.col("qty").gt(@expr.lit_int(100)))
    .then(@expr.lit_str("big"))
    .otherwise(@expr.col("region"))
    .with_alias("size"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter_where(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [col(bonus).is_null() as nb, when((col(qty) > 100)).then(\"big\").otherwise(col(region)) as size]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.with_columns(derived).filter_where(predicate))
}
