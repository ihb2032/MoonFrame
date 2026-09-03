///|
/// The cross-pass battery: the shapes where the optimizer's two rewrites
/// meet — `explain`'s before/after pair (the as-built plan beside the one
/// `collect` actually runs), the flagship pipeline where a filter sinks
/// *and* a scan narrows under it, and the depth-totality probes that keep
/// the executor and both passes iterative. The per-pass batteries live in
/// `optimize_projection_test.mbt` and `optimize_predicates_test.mbt`; the
/// shared fixture frames live in `lazy_test.mbt`.

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
