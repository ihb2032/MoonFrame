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
    lazy_frame(df).filter(predicate).select(projection).collect(),
    df.filter(predicate).select(projection),
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
    lazy_frame(df).group_by([@expr.col("region")]).agg(aggs).collect(),
    df.group_by([@expr.col("region")]).agg(aggs),
  )
}

///|
test "sort keys stay alive through the pushdown" {
  let df = sales_df()
  let keys = [
    (@expr.col("bonus"), @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
  ]
  let projection = [@expr.col("region")]
  assert_eq(
    lazy_frame(df).sort(keys).select(projection).collect(),
    df.sort(keys).select(projection),
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
  let opts = @frame.JoinOptions::on([@expr.col("id")])
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
    .filter(predicate)
    .with_columns(derived)
    .select(projection)
    .collect()
  assert_eq(out, df.filter(predicate).with_columns(derived).select(projection))
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
    Ok(lazy_frame(df).select([@expr.col("ghost")]).collect()) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("ghost")),
  )
  // A missing column in a filter under a selection: parity with eager.
  let predicate = @expr.col("ghost").is_null()
  let projection = [@expr.col("qty")]
  assert_eq(
    Ok(lazy_frame(df).filter(predicate).select(projection).collect()) catch {
      e => Err(e)
    },
    Ok(df.filter(predicate).select(projection)) catch {
      e => Err(e)
    },
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
    .filter(predicate)
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
  let bare = lazy_frame(sales_df()).filter(predicate)
  assert_eq(bare.explain(optimized=true), bare.explain())
}

///|
test "sort: the requirement passes through, widened by the sort keys" {
  let plan = lazy_frame(sales_df())
    .sort([
      (@expr.col("bonus"), @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
    ])
    .select([@expr.col("qty")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  SORT [col(bonus) Asc NullsLast]\n" +
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
  let opts = @frame.JoinOptions::on([@expr.col("id")])
  // A selection *below* the left side narrows that side's scan.
  let narrowed_side = lazy_frame(orders_df())
    .select([@expr.col("id")])
    .join(lazy_frame(cities_df()), opts)
  assert_eq(
    narrowed_side.explain(optimized=true),
    "JOIN Inner on [col(id)]\n" +
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
    .group_by([@expr.col("region")])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total] BY [col(region)]\n" +
    "  SELECT [col(qty), col(region)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "aggregate guard: reading every column inserts nothing" {
  let plan = lazy_frame(sales_df())
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("qty").sum().with_alias("a"),
      @expr.col("bonus").max().with_alias("b"),
    ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "drop/rename/unique/drop_nulls/fill_null are predicate barriers" {
  // A filter directly above each of these nodes must not sink through it: they
  // are predicate fences (place_filter stops at them). Were any mistakenly made
  // a pass-through, the predicate pass would push the filter below it and the
  // optimized plan would diverge from the as-built one. Snapshotting
  // optimized == as-built pins the fence (the cross-check to the Join barrier
  // above; collect-equivalence covers the values).
  let df = sales_df()
  let qty_gt = @expr.col("qty").gt(@expr.lit_int(50))
  let drop_plan = lazy_frame(df).drop([@expr.col("bonus")]).filter(qty_gt)
  assert_eq(drop_plan.explain(optimized=true), drop_plan.explain())
  let rename_plan = lazy_frame(df)
    .rename([("qty", "quantity")])
    .filter(@expr.col("quantity").gt(@expr.lit_int(50)))
  assert_eq(rename_plan.explain(optimized=true), rename_plan.explain())
  let unique_plan = lazy_frame(df).unique().filter(qty_gt)
  assert_eq(unique_plan.explain(optimized=true), unique_plan.explain())
  let drop_nulls_plan = lazy_frame(df).drop_nulls().filter(qty_gt)
  assert_eq(drop_nulls_plan.explain(optimized=true), drop_nulls_plan.explain())
  let fill_null_plan = lazy_frame(df)
    .fill_null(@types.Scalar::Int(0))
    .filter(qty_gt)
  assert_eq(fill_null_plan.explain(optimized=true), fill_null_plan.explain())
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
  let plan = lazy_frame(df).select(projection).filter(predicate)
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
  assert_eq(out, df.select(projection).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a trailing filter sinks below a derived-column stage" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  // `dbl` is defined by the stage but not read by the predicate, so the
  // filter crosses; at the root nothing requires columns, so no scan
  // narrowing fires.
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [(col(qty) * 2) as dbl]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "a trailing filter sinks below a fill_null with_columns stage" {
  let df = sales_df()
  // `fill_null` lowers to a row-stable ternary, so the optimizer crosses it
  // with no fill_null-specific rule: the stage replaces `qty` in place but
  // the predicate reads `region`, so the filter sinks below the stage.
  let filled = [@expr.col("qty").fill_null(@expr.lit_int(0))]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(filled).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [when(col(qty).is_not_null()).then(col(qty)).otherwise(0)]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.with_columns(filled).filter(predicate))
}

///|
test "predicate pushdown keeps a derived aggregate key's backend canonical" {
  // `a` is null exactly on the rows the filter (k > 5) drops, so the derived
  // key `a + b` is null there and only there. The filter sinks below the
  // aggregate (k is a bare key). The eager chain computes the key over *all*
  // rows (nullable, so `Builtin`) then filters; the optimized chain filters
  // then computes it over the survivors (all-valid). Both must land on the
  // same backend — the row-gather canonicalises an all-valid numeric result
  // onto `Numeric` — so `collect` stays equal to the eager chain (which
  // `Series` equality, observing the backend, would otherwise reject).
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("k", [3, 4, 7, 9]),
    @series.Series::from_int_options("a", [None, None, Some(10), Some(20)]),
    @series.Series::from_ints("b", [1, 1, 1, 1]),
    @series.Series::from_ints("v", [100, 200, 300, 400]),
  ])
  let keys = [@expr.col("k"), @expr.col("a") + @expr.col("b")]
  let aggs = [@expr.col("v").sum()]
  let predicate = @expr.col("k").gt(@expr.lit_int(5))
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  let out = plan.collect()
  assert_eq(out, df.group_by(keys).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
/// Identity that defeats compile-time constant folding, so a negative-zero
/// key is a genuine runtime `-0.0` rather than a folded `+0.0`.
fn id_double(x : Double) -> Double {
  x
}

///|
test "fence: a sign-sensitive predicate stays above an aggregate on a signed-zero key" {
  // `KeyCell` folds -0.0 and +0.0 into one group, but the group's output row
  // keeps its representative's signed key. A predicate that divides by the key
  // tells the two apart (1/+0.0 = +inf, 1/-0.0 = -inf), so sinking it below the
  // aggregate would filter the group's rows by their individual signs and
  // change the surviving sum. The filter must stay above the aggregate.
  let neg_zero = -1.0 * id_double(0.0)
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("k", [0.0, neg_zero]),
    @series.Series::from_ints("v", [1, 2]),
  ])
  let keys = [@expr.col("k")]
  let aggs = [@expr.col("v").sum()]
  let predicate = (@expr.lit_float(1.0) / @expr.col("k")).gt(
    @expr.lit_float(0.0),
  )
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  // Not pushed: the optimized plan is the as-built plan.
  assert_eq(plan.explain(optimized=true), plan.explain())
  // And `collect` matches the eager chain: +0.0 and -0.0 stay one group whose
  // representative (+0.0) passes the filter, keeping the sum of both rows.
  let out = plan.collect()
  assert_eq(out, df.group_by(keys).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "predicate pushdown still sinks a division-free predicate below an aggregate" {
  // The signed-zero fence is precise — only division reveals a zero's sign — so
  // a comparison predicate on the key still sinks (and must, to keep the
  // optimization for the common case).
  let neg_zero = -1.0 * id_double(0.0)
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("k", [0.0, neg_zero, 5.0]),
    @series.Series::from_ints("v", [1, 2, 3]),
  ])
  let keys = [@expr.col("k")]
  let aggs = [@expr.col("v").sum()]
  let predicate = @expr.col("k").gt(@expr.lit_float(-1.0))
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  // Pushed: the optimized plan differs from the as-built plan.
  assert_true(plan.explain(optimized=true) != plan.explain())
  assert_eq(plan.collect(), df.group_by(keys).agg(aggs).filter(predicate))
}

///|
test "deep optimizer predicates don't overflow: the pushdown walks are iterative" {
  // A key predicate this deep formerly overflowed the native stack and aborted
  // inside row_stable / division_free during optimization — before the executor
  // even ran. The explicit-stack walks analyse any depth.
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("k", [0.0, 5.0]),
    @series.Series::from_ints("v", [1, 2]),
  ])
  let keys = [@expr.col("k")]
  let aggs = [@expr.col("v").sum()]
  let depth = 100000
  let mut predicate = @expr.col("k").gt(@expr.lit_float(-1.0))
  for _ in 0..<depth {
    predicate = predicate.land(@expr.col("k").gt(@expr.lit_float(-1.0)))
  }
  // Optimizing walks row_stable + division_free over the whole predicate to
  // gate the aggregate pushdown; it completes without aborting and renders the
  // deep optimized plan.
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  assert_true(plan.explain(optimized=true).length() > depth)
}

///|
test "deep aggregation expressions don't overflow the group pushdown gate" {
  // A `sum() + sum() + …` aggregation this deep formerly overflowed the native
  // stack inside group_cell_stable when the optimizer tested whether a key
  // predicate could sink below the aggregate. The explicit-stack walk analyses
  // any depth.
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("k", [1, 1, 2]),
    @series.Series::from_ints("v", [10, 20, 30]),
  ])
  let keys = [@expr.col("k")]
  let depth = 100000
  let mut agg = @expr.col("v").sum()
  for _ in 0..<depth {
    agg = agg + @expr.col("v").sum()
  }
  let predicate = @expr.col("k").gt(@expr.lit_int(0))
  let plan = lazy_frame(df)
    .group_by(keys)
    .agg([agg.with_alias("r")])
    .filter(predicate)
  assert_true(plan.explain(optimized=true).length() > depth)
}

///|
test "predicate pushdown keeps a derived select column's backend canonical" {
  // The same hazard one stage over: `s = a + b` is null exactly where the
  // filter drops the row, so the eager (compute-then-filter) and optimized
  // (filter-then-compute) chains would build `s` on different backends were
  // the gather not canonicalising.
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("k", [3, 4, 7, 9]),
    @series.Series::from_int_options("a", [None, None, Some(10), Some(20)]),
    @series.Series::from_ints("b", [1, 1, 1, 1]),
  ])
  let exprs = [
    (@expr.col("a") + @expr.col("b")).with_alias("s"),
    @expr.col("k"),
  ]
  let predicate = @expr.col("k").gt(@expr.lit_int(5))
  let plan = lazy_frame(df).select(exprs).filter(predicate)
  let out = plan.collect()
  assert_eq(out, df.select(exprs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a predicate reading a name the stage defines stays above" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let predicate = @expr.col("dbl").gt(@expr.lit_int(100))
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  // Below the stage `dbl` does not exist: the filter must wait for it.
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "fence: a broadcast aggregation inside with_columns pins the filter above" {
  let df = sales_df()
  // `total` broadcasts sum(qty) over *all* rows; filtering first would
  // recompute it over the survivors (85, not 405).
  let derived = [@expr.col("qty").sum().with_alias("total")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "fence: a cast inside the stage pins the filter above" {
  let df = sales_df()
  // A cast's parse / range rejection raises on the values it meets:
  // filtering first could drop the very row that raises, so no filter
  // crosses a cast-bearing stage even when (as here) every cast succeeds.
  let derived = [@expr.col("qty").cast(@types.DataType::Float).with_alias("f")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "fence: a computed occurrence of the predicate's column is not a bare pass-through" {
  let df = sales_df()
  let projection = [
    (@expr.col("qty") * @expr.lit_int(2)).with_alias("qty2"),
    @expr.col("region"),
  ]
  let predicate = @expr.col("qty2").gt(@expr.lit_int(100))
  let plan = lazy_frame(df).select(projection).filter(predicate)
  // `qty2` exists only above the selection, so the filter stays at the
  // root — while the projection pass still narrows the scan below.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(qty2) > 100)\n" +
    "  SELECT [(col(qty) * 2) as qty2, col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter(predicate))
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
  let plan = lazy_frame(df).select(projection).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  SELECT [col(region), col(qty).sum() as total]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter(predicate))
}

///|
test "a scope-dependent predicate still crosses a bare selection" {
  let df = sales_df()
  // The predicate's own mean is computed over the filter's input scope —
  // and a bare selection neither adds nor drops rows, so that scope is
  // identical on both sides of the swap.
  let projection = [@expr.col("qty"), @expr.col("region")]
  let predicate = @expr.col("qty").gt(@expr.col("qty").mean())
  let plan = lazy_frame(df).select(projection).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty), col(region)]\n" +
    "  FILTER (col(qty) > col(qty).mean())\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter(predicate))
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
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // Every row of a group shares its key tuple, so filtering rows by key
  // before grouping drops exactly the groups the filter would have
  // dropped after — and sum / count cells can never be null, so the
  // stitched columns' backend cannot flip when groups disappear.
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total, col(bonus).count() as n] BY [col(region)]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.group_by([@expr.col("region")]).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a key predicate that empties every group still collects equal" {
  let df = sales_df()
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let predicate = @expr.col("region").eq(@expr.lit_str("north"))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // Below the aggregation the filter leaves zero rows, so the executor
  // aggregates zero groups — the empty-scope probe in `agg` pins
  // the output dtype, keeping the 0-row frames bitwise-equal.
  let out = plan.collect()
  assert_eq(out, df.group_by([@expr.col("region")]).agg(aggs).filter(predicate))
  assert_eq(out.nrows(), 0)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a predicate reading an aggregation output stays above" {
  let df = sales_df()
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let predicate = @expr.col("total").gt(@expr.lit_int(100))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // `total` is not a key: it only exists above the aggregation.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(total) > 100)\n" +
    "  AGGREGATE [col(qty).sum() as total] BY [col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
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
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(bonus).mean() as avg] BY [col(region)]\n" +
    "    SELECT [col(bonus), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
  )
}

///|
test "a key predicate sinks below a distinct-count aggregation" {
  let df = sales_df()
  // `n_unique` cells are always a non-null `Int`, so — like `sum` / `count` —
  // the stitched columns' backend cannot flip when a group disappears, and a
  // key predicate sinks past the aggregation.
  let aggs = [
    @expr.col("qty").n_unique().with_alias("nu"),
    @expr.col("bonus").n_unique().with_alias("nb"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).n_unique() as nu, col(bonus).n_unique() as nb] BY [col(region)]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.group_by([@expr.col("region")]).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a std aggregation pins the filter above the group stage" {
  let df = sales_df()
  // The east group's bonus cells are all null, so its `std` is a null cell and
  // the stitched column stays `Builtin`; like `mean`, dropping that group
  // first would converge the survivors onto `Numeric` — a different output —
  // so the fence keeps the filter above. (`variance` / `median` / `first` /
  // `last` are fenced for the same reason: each can go null on a group.)
  let aggs = [@expr.col("bonus").std().with_alias("s")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(bonus).std() as s] BY [col(region)]\n" +
    "    SELECT [col(bonus), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
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
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(qty).sum().cast(Float) as totalf] BY [col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
  )
}

///|
test "fence: a cast inside an aggregation operand pins the filter above" {
  let df = sales_df()
  // `sum(cast(qty))`: the cast is the aggregation's *operand*, not a
  // top-level wrapper. Its parse / range rejection raises on the values it
  // meets, so dropping a group first could drop the very cell that raises —
  // the filter must stay above even though `sum`'s cell is otherwise
  // group-stable. (Holds even here, where every cast succeeds.) Before the
  // operand check, `group_cell_stable` read only the `sum` tag and sank the
  // filter below, so an optimized collect could succeed where the eager
  // chain raised.
  let aggs = [
    @expr.col("qty").cast(@types.DataType::Float).sum().with_alias("s"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(qty).cast(Float).sum() as s] BY [col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
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
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region).count() > 1)\n" +
    "  AGGREGATE [col(qty).sum() as total] BY [col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    plan.collect(),
    df.group_by([@expr.col("region")]).agg(aggs).filter(predicate),
  )
}

///|
test "fence: a non-reduction aggregation keeps its error and its filter in place" {
  let df = sales_df()
  let aggs = [@expr.col("qty")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // A bare column is not reduction-shaped; the fence holds the filter
  // above, and collect reports the executor's own `InvalidOperation`.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [col(qty)] BY [col(region)]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    Ok(plan.collect()) catch {
      e => Err(e)
    },
    Ok(df.group_by([@expr.col("region")]).agg(aggs).filter(predicate)) catch {
      e => Err(e)
    },
  )
}

///|
test "fence: a null literal in the aggregation list pins the filter above" {
  let df = sales_df()
  let aggs = [@expr.lit(@types.Scalar::Null).with_alias("z")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // A null literal is a null cell by definition — the backend-flip
  // hazard in its purest form — so the filter stays above, and collect
  // behaves exactly as the as-built plan does.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  AGGREGATE [null as z] BY [col(region)]\n" +
    "    SELECT [col(region)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    Ok(plan.collect()) catch {
      e => Err(e)
    },
    Ok(df.group_by([@expr.col("region")]).agg(aggs).filter(predicate)) catch {
      e => Err(e)
    },
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
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [when((col(qty).sum() > 100)).then(1).otherwise(0) as flag, (-col(qty).sum()) as neg] BY [col(region)]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.group_by([@expr.col("region")]).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a predicate on a derived key stays above the aggregation" {
  let df = sales_df()
  // The group key is *derived* (`qty > 50`, aliased `big`): its output
  // column does not exist below the aggregation, so a predicate reading it
  // cannot sink — only a *bare-column* key opens the crossing. The
  // projection pass still narrows the scan to the key's source column.
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let keys = [@expr.col("qty").gt(@expr.lit_int(50)).with_alias("big")]
  let predicate = @expr.col("big")
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER col(big)\n" +
    "  AGGREGATE [col(qty).sum() as total] BY [(col(qty) > 50) as big]\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.group_by(keys).agg(aggs).filter(predicate))
}

///|
test "fence: a non-row-stable extra key keeps the group filter above" {
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("k", ["a", "a", "b"]),
    @series.Series::from_ints("v", [1, 2, 10]),
  ])
  let keys = [@expr.col("k"), @expr.col("v").sum().with_alias("total")]
  let aggs = [@expr.col("v").count().with_alias("n")]
  let predicate = @expr.col("k").eq(@expr.lit_str("a"))
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  // `total` is part of the grouping tuple. If the filter were pushed
  // below the aggregate, it would be recomputed over only the surviving
  // rows and silently change from 13 to 3.
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.group_by(keys).agg(aggs).filter(predicate))
}

///|
test "a bare-column key predicate still sinks past a mixed-key aggregation" {
  let df = sales_df()
  // Two keys: a bare `region` and a derived bucket. A predicate on the bare
  // key sinks (its column is present verbatim below, one value per group),
  // while the derived key keeps its own source `qty` alive at the scan.
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let keys = [
    @expr.col("region"),
    @expr.col("qty").gt(@expr.lit_int(50)).with_alias("big"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total] BY [col(region), (col(qty) > 50) as big]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.group_by(keys).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "row windows stop the descent" {
  let df = sales_df()
  // Positions are not values: head(2) then filter keeps [120], while
  // filtering first would re-number the rows and keep [120, 200].
  let predicate = @expr.col("qty").gt(@expr.lit_int(100))
  let on_head = lazy_frame(df).head(2).filter(predicate)
  assert_eq(on_head.explain(optimized=true), on_head.explain())
  assert_eq(on_head.collect(), df.head(2).filter(predicate))
  assert_eq(
    lazy_frame(df).tail(2).filter(predicate).collect(),
    df.tail(2).filter(predicate),
  )
  assert_eq(
    lazy_frame(df).slice(1, 3).filter(predicate).collect(),
    df.slice(1, 3).filter(predicate),
  )
}

///|
test "sort stops the descent" {
  let df = sales_df()
  let keys = [
    (@expr.col("qty"), @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
  ]
  let predicate = @expr.col("qty").gt(@expr.lit_int(100))
  let plan = lazy_frame(df).sort(keys).filter(predicate)
  // Crossing a sort is deliberately deferred — the filter stays put.
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(plan.collect(), df.sort(keys).filter(predicate))
}

///|
test "stacked filters sink together and keep their order" {
  let df = sales_df()
  let projection = [@expr.col("qty"), @expr.col("bonus")]
  let first = @expr.col("bonus").is_not_null()
  let second = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = lazy_frame(df).select(projection).filter(first).filter(second)
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
  assert_eq(plan.collect(), df.select(projection).filter(first).filter(second))
}

///|
test "a filter above a join stays; one inside a side still sinks" {
  let l = orders_df()
  let r = cities_df()
  let opts = @frame.JoinOptions::on([@expr.col("id")])
  // Above: splitting a predicate across suffix-renamed sides is column
  // provenance, deferred — the join is a barrier.
  let above = lazy_frame(l)
    .join(lazy_frame(r), opts)
    .filter(@expr.col("amount").gt(@expr.lit_int(15)))
  assert_eq(above.explain(optimized=true), above.explain())
  assert_eq(
    above.collect(),
    l.join(r, opts).filter(@expr.col("amount").gt(@expr.lit_int(15))),
  )
  // Inside: each side restarts its own descent, so a filter built into
  // the left pipeline sinks below that side's selection.
  let gate = @expr.col("amount").gt(@expr.lit_int(15))
  let inside = lazy_frame(l)
    .select([@expr.col("id"), @expr.col("amount")])
    .filter(gate)
    .join(lazy_frame(r), opts)
  assert_eq(
    inside.explain(optimized=true),
    "JOIN Inner on [col(id)]\n" +
    "  SELECT [col(id), col(amount)]\n" +
    "    FILTER (col(amount) > 15)\n" +
    "      SCAN [3×2]\n" +
    "  SCAN [3×2]",
  )
  assert_eq(
    inside.collect(),
    l.select([@expr.col("id"), @expr.col("amount")]).filter(gate).join(r, opts),
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
  let plan = lazy_frame(df).with_columns(broken_stage).filter(broken_predicate)
  assert_eq(
    Ok(plan.collect()) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("ghost2")),
  )
  assert_eq(
    Ok(df.with_columns(broken_stage).filter(broken_predicate)) catch {
      e => Err(e)
    },
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
    Ok(
      lazy_frame(df).with_columns(broken_stage).filter(key_predicate).collect(),
    ) catch {
      e => Err(e)
    },
    Ok(df.with_columns(broken_stage).filter(key_predicate)) catch {
      e => Err(e)
    },
  )
  // Sound stage, broken predicate: the predicate's missing column is
  // missing below the stage too — same error, earlier.
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let broken_predicate = @expr.col("ghost").gt(@expr.lit_int(1))
  assert_eq(
    Ok(lazy_frame(df).with_columns(derived).filter(broken_predicate).collect()) catch {
      e => Err(e)
    },
    Ok(df.with_columns(derived).filter(broken_predicate)) catch {
      e => Err(e)
    },
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
    .filter(predicate)
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
  assert_eq(out, df.with_columns(derived).select(projection).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "an all-literal predicate crosses vacuously" {
  let df = sales_df()
  let projection = [@expr.col("qty")]
  let predicate = @expr.lit_bool(true)
  let plan = lazy_frame(df).select(projection).filter(predicate)
  // No columns read means nothing to fence on: the filter sinks.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  FILTER true\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.select(projection).filter(predicate))
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
  let plan = lazy_frame(df).select(one).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "FILTER false\n" + "  SELECT [1 as one]\n" + "    SCAN [4×3]",
  )
  let out = plan.collect()
  assert_eq(out, df.select(one).filter(predicate))
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
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [col(bonus).is_null() as nb, when((col(qty) > 100)).then(\"big\").otherwise(col(region)) as size]\n" +
    "  FILTER (col(region) == \"west\")\n" +
    "    SCAN [4×3]",
  )
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "a map is a value barrier: it blocks the filter sink, like cast" {
  let df = sales_df()
  // A `Map`'s opaque closure can raise on the values it meets, so a `Map` is
  // a value barrier (exactly like `cast`): the filter cannot sink past a
  // with_columns that contains one, even though the predicate reads a column
  // the stage does not define. Contrast the row-local case above, where the
  // filter sinks below the stage.
  let derived = [
    @expr.col("qty").map_elements(label="x10", s => {
      match s {
        @types.Scalar::Int(v) => @types.Scalar::Int(v * 10)
        _ => @types.Scalar::Null
      }
    }),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  // The FILTER stays *above* the WITH_COLUMNS.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  WITH_COLUMNS [map(\"x10\", [col(qty)])]\n" +
    "    SCAN [4×3]",
  )
  // ...and collect stays bitwise-equal to the eager chain through it.
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

///|
test "a lit_series is a barrier: it blocks the filter sink, like cast" {
  let df = sales_df()
  // A frame-tall literal column is positional (cell `i` is row `i`), so a
  // filter dropping rows *before* the stage would leave it mismatched against
  // the now-shorter frame. `lit_series` is therefore a shape barrier: the
  // filter cannot sink past a with_columns that carries one, even though the
  // predicate reads a column the stage does not define. Contrast the
  // derived-column case above, where a row-stable stage lets the filter sink.
  let derived = [
    @expr.lit_series(@series.Series::from_ints("flag", [0, 1, 0, 1])),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = lazy_frame(df).with_columns(derived).filter(predicate)
  // The FILTER stays *above* the WITH_COLUMNS.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  WITH_COLUMNS [lit_series(\"flag\", 4)]\n" +
    "    SCAN [4×3]",
  )
  // ...and collect stays bitwise-equal to the eager chain through it.
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

// ── The CSV source's projection push-down ────────────────────────────────
//
// Structural snapshots only — `explain` never reads the file. Unlike the
// in-memory `Scan`, whose narrowing *inserts* a `SELECT`, a `ScanCsv` narrows
// in place: the projected columns ride on the node as `SCAN_CSV "path"
// [cols]`. The file-backed collect equivalences live in `scan_csv_test.mbt`.

///|
test "scan_csv: a selection writes its columns into the scan, no inserted select" {
  let plan = scan_csv("sales.csv").select([@expr.col("region")])
  // As built there is no projection; optimized, the read narrows in place —
  // and (unlike an in-memory Scan) no extra SELECT is inserted.
  assert_eq(plan.explain(), "SELECT [col(region)]\n  SCAN_CSV \"sales.csv\"")
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n  SCAN_CSV \"sales.csv\" [region]",
  )
}

///|
test "scan_csv: the written projection is sorted for a deterministic explain" {
  // One expression reads two columns; the file's order is unknown at optimize
  // time, so the projection is sorted (bonus before qty).
  let plan = scan_csv("sales.csv").select([
    (@expr.col("qty") + @expr.col("bonus")).with_alias("t"),
  ])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [(col(qty) + col(bonus)) as t]\n" +
    "  SCAN_CSV \"sales.csv\" [bonus, qty]",
  )
}

///|
test "scan_csv guard: an all-literal selection writes no projection" {
  let plan = scan_csv("sales.csv").select([@expr.lit_int(1).with_alias("one")])
  // No source column is read, so the scan stays whole — it still yields rows.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [1 as one]\n  SCAN_CSV \"sales.csv\"",
  )
}

///|
test "scan_csv: a bare scan at the root writes no projection" {
  assert_eq(
    scan_csv("sales.csv").explain(optimized=true),
    "SCAN_CSV \"sales.csv\"",
  )
}

///|
test "scan_csv: a filter's columns stay alive in the written projection" {
  // The selection reads `region`; the filter needs `qty` — both ride into the
  // projection, and (ScanCsv being a floor) the filter stays above the scan.
  let plan = scan_csv("sales.csv")
    .filter(@expr.col("qty").gt(@expr.lit_int(50)))
    .select([@expr.col("region")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SCAN_CSV \"sales.csv\" [qty, region]",
  )
}

///|
test "scan_csv is a floor: a filter directly on it neither sinks nor narrows" {
  // Predicate push-down into the parser is v0.6, so a filter on a bare CSV
  // scan stays put and writes no projection.
  let plan = scan_csv("sales.csv").filter(
    @expr.col("qty").gt(@expr.lit_int(50)),
  )
  assert_eq(plan.explain(optimized=true), plan.explain())
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(qty) > 50)\n  SCAN_CSV \"sales.csv\"",
  )
}

///|
test "scan_csv: an aggregation narrows the scan to its keys and reads" {
  let plan = scan_csv("sales.csv")
    .group_by([@expr.col("region")])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total] BY [col(region)]\n" +
    "  SCAN_CSV \"sales.csv\" [qty, region]",
  )
}

///|
test "scan_ndjson narrows in place like scan_csv, only the label differs" {
  // The shared narrow_scan / render_scan_source path serves both sources, so a
  // selection writes the projection straight onto the SCAN_NDJSON node.
  let plan = scan_ndjson("events.ndjson").select([@expr.col("region")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n  SCAN_NDJSON \"events.ndjson\" [region]",
  )
  // A filter widens the projection and (NDJSON being a floor) stays above it.
  let with_filter = scan_ndjson("events.ndjson")
    .filter(@expr.col("qty").gt(@expr.lit_int(50)))
    .select([@expr.col("region")])
  assert_eq(
    with_filter.explain(optimized=true),
    "SELECT [col(region)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SCAN_NDJSON \"events.ndjson\" [qty, region]",
  )
  // Bare at the root: no requirement, so no projection is written.
  assert_eq(
    scan_ndjson("events.ndjson").explain(optimized=true),
    "SCAN_NDJSON \"events.ndjson\"",
  )
}
