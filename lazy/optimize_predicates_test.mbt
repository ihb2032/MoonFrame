///|
/// Blackbox battery for the predicate pass — the rewrite that sinks each
/// `Filter` toward the scan (and absorbs the first one sitting on a file
/// source into the read itself). The tests pin where a filter sinks, and the
/// fences where it must stay: several fences guard real divergences (a
/// broadcast aggregation's scope, a `cast`'s value-dependent rejection, a
/// signed-zero group key; a `mean`'s null cell is fenced conservatively),
/// each pinned by plan-shape snapshot plus `collect ≡ eager` parity. The
/// projection pass's battery lives in `optimize_projection_test.mbt`, the
/// cross-pass shapes in `optimize_test.mbt`; the shared fixture frames live
/// in `lazy_test.mbt`.

///|
test "drop/rename/rename_with/unique/drop_nulls/fill_null are predicate barriers" {
  // A filter directly above each of these nodes must not sink through it: they
  // are predicate fences (place_filter stops at them). Were any mistakenly made
  // a pass-through, the predicate pass would push the filter below it and the
  // optimized plan would diverge from the as-built one. Snapshotting
  // optimized == as-built pins the fence (the cross-check to the Join barrier
  // above; collect-equivalence covers the values).
  let df = sales_df()
  let qty_gt = @expr.col("qty").gt(@expr.lit_int(50))
  let drop_plan = LazyFrame::LazyFrame(df)
    .drop([@expr.col("bonus")])
    .filter(qty_gt)
  assert_eq(drop_plan.explain(optimized=true), drop_plan.explain())
  let rename_plan = LazyFrame::LazyFrame(df)
    .rename([("qty", "quantity")])
    .filter(@expr.col("quantity").gt(@expr.lit_int(50)))
  assert_eq(rename_plan.explain(optimized=true), rename_plan.explain())
  let rename_with_plan = LazyFrame::LazyFrame(df)
    .rename_with(name => "col_\{name}")
    .filter(@expr.col("col_qty").gt(@expr.lit_int(50)))
  assert_eq(
    rename_with_plan.explain(optimized=true),
    rename_with_plan.explain(),
  )
  let unique_plan = LazyFrame::LazyFrame(df).unique().filter(qty_gt)
  assert_eq(unique_plan.explain(optimized=true), unique_plan.explain())
  let drop_nulls_plan = LazyFrame::LazyFrame(df).drop_nulls().filter(qty_gt)
  assert_eq(drop_nulls_plan.explain(optimized=true), drop_nulls_plan.explain())
  let fill_null_plan = LazyFrame::LazyFrame(df)
    .fill_null(@types.Scalar::Int(0))
    .filter(qty_gt)
  assert_eq(fill_null_plan.explain(optimized=true), fill_null_plan.explain())
}

// ── The predicate pass ──────────────────────────────────────────────────

///|
test "a trailing filter sinks below a bare-column selection" {
  let df = sales_df()
  let projection = [@expr.col("qty"), @expr.col("region")]
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = LazyFrame::LazyFrame(df).select(projection).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
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
  // `fill_null` is a dedicated row-stable node (semantically the guarded
  // ternary), so the optimizer crosses it with no fill_null-specific rule:
  // the stage replaces `qty` in place but the predicate reads `region`, so
  // the filter sinks below the stage.
  let filled = [@expr.col("qty").fill_null(@expr.lit_int(0))]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = LazyFrame::LazyFrame(df).with_columns(filled).filter(predicate)
  assert_eq(
    plan.explain(optimized=true),
    "WITH_COLUMNS [col(qty).fill_null(0)]\n" +
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
  // onto `Numeric`. Column equality compares content and not the backend, so
  // this pins the canonicalisation itself rather than a difference `collect`
  // would otherwise report.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("k", [3, 4, 7, 9]),
    @series.Series::from_int_options("a", [None, None, Some(10), Some(20)]),
    @series.Series::from_ints("b", [1, 1, 1, 1]),
    @series.Series::from_ints("v", [100, 200, 300, 400]),
  ])
  let keys = [@expr.col("k"), @expr.col("a") + @expr.col("b")]
  let aggs = [@expr.col("v").sum()]
  let predicate = @expr.col("k").gt(@expr.lit_int(5))
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
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
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("k", [0.0, neg_zero]),
    @series.Series::from_ints("v", [1, 2]),
  ])
  let keys = [@expr.col("k")]
  let aggs = [@expr.col("v").sum()]
  let predicate = (@expr.lit_float(1.0) / @expr.col("k")).gt(
    @expr.lit_float(0.0),
  )
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
  // Not pushed: the optimized plan is the as-built plan.
  assert_eq(plan.explain(optimized=true), plan.explain())
  // And `collect` matches the eager chain: +0.0 and -0.0 stay one group whose
  // representative (+0.0) passes the filter, keeping the sum of both rows.
  let out = plan.collect()
  assert_eq(out, df.group_by(keys).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a pow predicate with a negative exponent also stays above a signed-zero aggregate" {
  // `(+0.0) ** -1 = +inf` but `(-0.0) ** -1 = -inf`, so a negative exponent
  // reveals a folded key's sign exactly as division does — the filter must stay
  // above the aggregate, not sink into the group's individual rows.
  let neg_zero = -1.0 * id_double(0.0)
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("k", [0.0, neg_zero]),
    @series.Series::from_ints("v", [1, 2]),
  ])
  let keys = [@expr.col("k")]
  let aggs = [@expr.col("v").sum()]
  let predicate = @expr.col("k")
    .pow(@expr.lit_float(-1.0))
    .gt(@expr.lit_float(0.0))
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
  // Not pushed: the optimized plan is the as-built plan.
  assert_eq(plan.explain(optimized=true), plan.explain())
  // And `collect` matches the eager chain: +0.0 and -0.0 stay one group.
  let out = plan.collect()
  assert_eq(out, df.group_by(keys).agg(aggs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "predicate pushdown still sinks a division-free predicate below an aggregate" {
  // The signed-zero fence is precise — only division or a negative exponent
  // reveals a zero's sign — so a comparison predicate on the key still sinks
  // (and must, to keep the optimization for the common case).
  let neg_zero = -1.0 * id_double(0.0)
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("k", [0.0, neg_zero, 5.0]),
    @series.Series::from_ints("v", [1, 2, 3]),
  ])
  let keys = [@expr.col("k")]
  let aggs = [@expr.col("v").sum()]
  let predicate = @expr.col("k").gt(@expr.lit_float(-1.0))
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
  // Pushed: the optimized plan differs from the as-built plan.
  assert_true(plan.explain(optimized=true) != plan.explain())
  assert_eq(plan.collect(), df.group_by(keys).agg(aggs).filter(predicate))
}

///|
test "deep optimizer predicates don't overflow: the pushdown walks are iterative" {
  // A key predicate this deep formerly overflowed the native stack and aborted
  // inside row_stable / signed_zero_safe during optimization — before the executor
  // even ran. The explicit-stack walks analyse any depth.
  let df = @frame.DataFrame::DataFrame([
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
  // Optimizing walks row_stable + signed_zero_safe over the whole predicate to
  // gate the aggregate pushdown; it completes without aborting and renders the
  // deep optimized plan.
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
  assert_true(plan.explain(optimized=true).length() > depth)
}

///|
test "deep aggregation expressions don't overflow the group pushdown gate" {
  // A `sum() + sum() + …` aggregation this deep formerly overflowed the native
  // stack inside group_cell_stable when the optimizer tested whether a key
  // predicate could sink below the aggregate. The explicit-stack walk analyses
  // any depth.
  let df = @frame.DataFrame::DataFrame([
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
  let plan = LazyFrame::LazyFrame(df)
    .group_by(keys)
    .agg([agg.with_alias("r")])
    .filter(predicate)
  assert_true(plan.explain(optimized=true).length() > depth)
}

///|
test "deep crossable spine collects without overflowing: place_filter is iterative" {
  // place_filter sinks the filter through every crossable Select; a spine this
  // deep formerly overflowed the native stack inside place_filter (and
  // push_projection rebuilding it). collect drives the optimizer then execute.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", [1, 2, 3]),
  ])
  let mut lf = LazyFrame::LazyFrame(df)
  for _ in 0..<20000 {
    lf = lf.select([@expr.col("a")])
  }
  lf = lf.filter(@expr.col("a").gt(@expr.lit_int(1)))
  // Filter keeps a > 1 → rows [2, 3]; the deep Select spine is pure projection.
  assert_eq(lf.collect().shape(), (2, 1))
}

///|
test "predicate pushdown keeps a derived select column's backend canonical" {
  // The same hazard one stage over: `s = a + b` is null exactly where the
  // filter drops the row, so the eager (compute-then-filter) and optimized
  // (filter-then-compute) chains would build `s` on different backends were
  // the gather not canonicalising.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("k", [3, 4, 7, 9]),
    @series.Series::from_int_options("a", [None, None, Some(10), Some(20)]),
    @series.Series::from_ints("b", [1, 1, 1, 1]),
  ])
  let exprs = [
    (@expr.col("a") + @expr.col("b")).with_alias("s"),
    @expr.col("k"),
  ]
  let predicate = @expr.col("k").gt(@expr.lit_int(5))
  let plan = LazyFrame::LazyFrame(df).select(exprs).filter(predicate)
  let out = plan.collect()
  assert_eq(out, df.select(exprs).filter(predicate))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "fence: a predicate reading a name the stage defines stays above" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let predicate = @expr.col("dbl").gt(@expr.lit_int(100))
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).select(projection).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).select(projection).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).select(projection).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // Every row of a group shares its key tuple, so filtering rows by key
  // before grouping drops exactly the groups the filter would have dropped
  // after — and sum / count cells are never null, which is what clears them
  // to sink.
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
  let plan = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // Below the aggregation the filter leaves zero rows, so the executor
  // aggregates zero groups — the empty-scope probe in `agg` pins
  // the output dtype, keeping the 0-row frames equal.
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
  let plan = LazyFrame::LazyFrame(df)
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
  // `mean` is fenced, so the filter stays above the aggregate whatever the
  // data does — here the east group's bonus cells are all null, the case the
  // fence was originally argued from. What is pinned is the plan shape and
  // parity with the eager chain, not a claim that sinking would change the
  // result; see `group_cell_stable` for why the fence is conservative.
  let aggs = [@expr.col("bonus").mean().with_alias("avg")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = LazyFrame::LazyFrame(df)
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
  // a key predicate sinks past the aggregation.
  let aggs = [
    @expr.col("qty").n_unique().with_alias("nu"),
    @expr.col("bonus").n_unique().with_alias("nb"),
  ]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = LazyFrame::LazyFrame(df)
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
  // The east group's bonus cells are all null, so its `std` is a null cell —
  // the case the fence was argued from. Like `mean`, `std` is fenced, so the
  // filter stays above the aggregate whatever the data does. What is pinned is
  // the plan shape and parity with the eager chain, not a claim that sinking
  // would change the result; see `group_cell_stable` for why the fence is
  // conservative. (`variance` / `median` / `first` / `last` are fenced the same
  // way: each can go null on a group.)
  let aggs = [@expr.col("bonus").std().with_alias("s")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = LazyFrame::LazyFrame(df)
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
  let plan = LazyFrame::LazyFrame(df)
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
  let plan = LazyFrame::LazyFrame(df)
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
  let plan = LazyFrame::LazyFrame(df)
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
  let plan = LazyFrame::LazyFrame(df)
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
  let plan = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .filter(predicate)
  // A null literal is a null cell by definition, so it fails the never-null
  // half of the rule in its purest form: the filter stays above, and collect
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
  let plan = LazyFrame::LazyFrame(df)
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
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
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
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("k", ["a", "a", "b"]),
    @series.Series::from_ints("v", [1, 2, 10]),
  ])
  let keys = [@expr.col("k"), @expr.col("v").sum().with_alias("total")]
  let aggs = [@expr.col("v").count().with_alias("n")]
  let predicate = @expr.col("k").eq(@expr.lit_str("a"))
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggs).filter(predicate)
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
  let on_head = LazyFrame::LazyFrame(df).head(2).filter(predicate)
  assert_eq(on_head.explain(optimized=true), on_head.explain())
  assert_eq(on_head.collect(), df.head(2).filter(predicate))
  assert_eq(
    LazyFrame::LazyFrame(df).tail(2).filter(predicate).collect(),
    df.tail(2).filter(predicate),
  )
  assert_eq(
    LazyFrame::LazyFrame(df).slice(1, 3).filter(predicate).collect(),
    df.slice(1, 3).filter(predicate),
  )
}

///|
test "sort stops the descent" {
  let df = sales_df()
  let keys = [
    (@expr.col("qty"), @types.SortOrder::Asc, @types.NullOrder::NullsLast),
  ]
  let predicate = @expr.col("qty").gt(@expr.lit_int(100))
  let plan = LazyFrame::LazyFrame(df).sort(keys).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df)
    .select(projection)
    .filter(first)
    .filter(second)
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
  let above = LazyFrame::LazyFrame(l)
    .join(LazyFrame::LazyFrame(r), opts)
    .filter(@expr.col("amount").gt(@expr.lit_int(15)))
  assert_eq(above.explain(optimized=true), above.explain())
  assert_eq(
    above.collect(),
    l.join(r, opts).filter(@expr.col("amount").gt(@expr.lit_int(15))),
  )
  // Inside: each side restarts its own descent, so a filter built into
  // the left pipeline sinks below that side's selection.
  let gate = @expr.col("amount").gt(@expr.lit_int(15))
  let inside = LazyFrame::LazyFrame(l)
    .select([@expr.col("id"), @expr.col("amount")])
    .filter(gate)
    .join(LazyFrame::LazyFrame(r), opts)
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
  let plan = LazyFrame::LazyFrame(df)
    .with_columns(broken_stage)
    .filter(broken_predicate)
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
      LazyFrame::LazyFrame(df)
      .with_columns(broken_stage)
      .filter(key_predicate)
      .collect(),
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
    Ok(
      LazyFrame::LazyFrame(df)
      .with_columns(derived)
      .filter(broken_predicate)
      .collect(),
    ) catch {
      e => Err(e)
    },
    Ok(df.with_columns(derived).filter(broken_predicate)) catch {
      e => Err(e)
    },
  )
}

///|
test "an all-literal predicate crosses vacuously" {
  let df = sales_df()
  let projection = [@expr.col("qty")]
  let predicate = @expr.lit_bool(true)
  let plan = LazyFrame::LazyFrame(df).select(projection).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).select(one).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
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
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
  // The FILTER stays *above* the WITH_COLUMNS.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  WITH_COLUMNS [map(\"x10\", [col(qty)])]\n" +
    "    SCAN [4×3]",
  )
  // ...and collect stays equal to the eager chain through it.
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
  let plan = LazyFrame::LazyFrame(df).with_columns(derived).filter(predicate)
  // The FILTER stays *above* the WITH_COLUMNS.
  assert_eq(
    plan.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  WITH_COLUMNS [lit_series(\"flag\", 4)]\n" +
    "    SCAN [4×3]",
  )
  // ...and collect stays equal to the eager chain through it.
  assert_eq(plan.collect(), df.with_columns(derived).filter(predicate))
}

// ── File-source predicate absorption (structural; the file-backed collect
// equivalences live in scan_csv_test.mbt) ──

///|
test "scan_csv: an absorbed predicate keeps its columns out of the projection" {
  // The selection reads `region`; the filter needs `qty`. The predicate rides
  // *into* the scan, which reads `qty` itself to prune rows — so the written
  // projection is the consumer's `region` alone and no FILTER node remains.
  let plan = scan_csv("sales.csv")
    .filter(@expr.col("qty").gt(@expr.lit_int(50)))
    .select([@expr.col("region")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n" +
    "  SCAN_CSV \"sales.csv\" [region] WHERE (col(qty) > 50)",
  )
}

///|
test "scan_csv absorbs a filter directly on it; a second one stays above" {
  let plan = scan_csv("sales.csv").filter(
    @expr.col("qty").gt(@expr.lit_int(50)),
  )
  // As built the filter is its own node; optimized, the scan carries it.
  assert_eq(plan.explain(), "FILTER (col(qty) > 50)\n  SCAN_CSV \"sales.csv\"")
  assert_eq(
    plan.explain(optimized=true),
    "SCAN_CSV \"sales.csv\" WHERE (col(qty) > 50)",
  )
  // Only one predicate is absorbed: combining two would reorder which
  // operand's evaluation error surfaces first, so the outer one stays a node.
  let two = plan.filter(@expr.col("region").eq(@expr.lit_str("west")))
  assert_eq(
    two.explain(optimized=true),
    "FILTER (col(region) == \"west\")\n" +
    "  SCAN_CSV \"sales.csv\" WHERE (col(qty) > 50)",
  )
}

///|
test "scan_csv: a column-less predicate is absorbed like any other" {
  // A predicate that names no column rides into the scan too: the pruner's
  // zero-column key frame carries the file's row count (`N×0`), so the literal
  // broadcasts over the real height. Both sources behave alike.
  let csv = scan_csv("sales.csv").filter(@expr.lit_bool(true))
  assert_eq(csv.explain(optimized=true), "SCAN_CSV \"sales.csv\" WHERE true")
  let ndjson = scan_ndjson("events.ndjson").filter(@expr.lit_bool(false))
  assert_eq(
    ndjson.explain(optimized=true),
    "SCAN_NDJSON \"events.ndjson\" WHERE false",
  )
}
