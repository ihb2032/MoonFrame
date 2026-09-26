///|
/// The cross-pass battery: the shapes where the optimizer's two rewrites
/// meet — `explain`'s before/after pair (the as-built plan beside the one
/// `collect` actually runs), the flagship pipeline where a filter sinks
/// *and* a scan narrows under it, and the depth-totality probes that keep
/// the executor and both passes iterative. The projection and predicate
/// passes each carry their own battery; the shared fixture frames are the
/// package's own.

///|
test "explain defaults to the plan as built; optimized=true is the before/after pair" {
  let plan = LazyFrame::LazyFrame(sales_df()).select([@expr.col("qty")])
  // Before: the chain verbatim — and the default is pinned to
  // `optimized=false` explicitly.
  assert_eq(plan.explain(), "SELECT [col(qty)]\n  SCAN [4×3]")
  assert_eq(plan.explain(), plan.explain(optimized=false))
  // After: the select is itself the narrowing over the in-memory scan, so the
  // optimizer inserts nothing below it — a bare projection is never doubled.
  assert_eq(plan.explain(optimized=true), "SELECT [col(qty)]\n  SCAN [4×3]")
}

///|
test "explain(optimized=true) rewrites a copy: the plan itself is unperturbed" {
  let df = sales_df()
  let plan = LazyFrame::LazyFrame(df).select([@expr.col("region")])
  let optimized = plan.explain(optimized=true)
  // Rendering the optimized form is stable across calls, and it perturbs
  // neither the as-built rendering nor what collect returns.
  assert_eq(plan.explain(optimized=true), optimized)
  assert_eq(plan.explain(), "SELECT [col(region)]\n  SCAN [4×3]")
  assert_eq(plan.collect(), df.select([@expr.col("region")]))
}

///|
test "deep lazy plans collect without overflowing: execute and the optimizer are iterative" {
  // One native frame per plan node formerly overflowed the stack at ~1000 nodes
  // (collect aborted with a STATUS_STACK_OVERFLOW) inside execute and the
  // optimizer passes — unlike every Expr walk, the *plan* walks were never made
  // iterative. The chain is built purely through the public builders (each wraps
  // one node, total). collect = execute(optimize(plan)) drives push_predicates,
  // push_projection, and execute, each over the full depth; `head(1)` keeps each
  // node's eager verb O(1) so the test pins depth-totality, not per-node work.
  // (`explain` is not asserted at this depth: a plan's indentation grows per
  // level, so its rendered string is O(depth²) — too large to materialise. The
  // explain golden tests cover render at ordinary depths.)
  let df = @frame.DataFrame::DataFrame([@series.Series::from_ints("a", [1, 2])])
  let mut lf = LazyFrame::LazyFrame(df)
  for _ in 0..<100000 {
    lf = lf.head(1)
  }
  assert_eq(lf.collect().shape(), (1, 1))
}

///|
test "the flagship pipeline sinks its filter and narrows its scan" {
  let df = sales_df()
  let derived = [(@expr.col("qty") * @expr.lit_int(3)).with_alias("adj")]
  let projection = [@expr.col("adj"), @expr.col("region")]
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let plan = LazyFrame::LazyFrame(df)
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
/// Optimizer interaction with the string namespace. A `Str` node raises only on
/// scope-independent facts — the dtype-level `TypeMismatch` of a non-String
/// operand, and for the regex ops the `InvalidOperation` of a pattern that does
/// not compile, hoisted out of the per-cell map — never on a value, so it is
/// `row_stable` — a filter sinks past a `with_columns`
/// that derives a string column, exactly as it does past arithmetic. And a
/// `Str` wrapping an aggregation inherits that aggregation's
/// group-cell-stability, so an `str_*` over `first` keeps a group filter
/// above the aggregate. Both pin the `Str` arms added to `row_stable` /
/// `group_cell_stable`; the shared fixtures are the package's own.

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
