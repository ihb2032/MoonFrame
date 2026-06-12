///|
/// Whitebox structural pins for the projection pushdown: the rewrite is
/// deliberately invisible through the public surface (`collect` must be
/// bitwise-equal, `explain` renders the plan as built), so the only way
/// to pin *what the optimizer did* — which scans narrowed, in which
/// column order, and which arms must stay no-ops — is to optimize a plan
/// directly and snapshot the rewritten tree through the package's own
/// plan printer. Execution equivalence for the same shapes lives in
/// `optimize_test.mbt`.

///|
/// Render the optimized form of a plan through `explain`'s printer.
fn optimized_text(lf : LazyFrame) -> String {
  let rewritten : LazyFrame = { plan: optimize(lf.plan) }
  rewritten.explain()
}

///|
/// 4×3 fixture mirroring `lazy_test.mbt`'s `sales_df` (a whitebox test
/// unit cannot see blackbox helpers): `qty` / `bonus` / `region`, so
/// every snapshot below shares one column-order frame of reference.
fn wide_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @frame.Series::from_ints("qty", [5, 120, 80, 200]),
    @frame.Series::from_int_options("bonus", [Some(1), None, Some(3), None]),
    @frame.Series::from_strings("region", ["west", "east", "west", "east"]),
  ])
}

///|
/// 3×2 join sides.
fn left_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @frame.Series::from_ints("id", [1, 2, 3]),
    @frame.Series::from_ints("amount", [10, 20, 30]),
  ])
}

///|
fn right_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @frame.Series::from_ints("id", [2, 3, 4]),
    @frame.Series::from_strings("city", ["bern", "cork", "delft"]),
  ])
}

///|
test "a bare scan is untouched (no requirement at the root)" {
  assert_eq(optimized_text(lazy_frame(wide_df())), "SCAN [4×3]")
}

///|
test "select: a proper-subset requirement narrows the scan, in scan column order" {
  let plan = lazy_frame(wide_df()).select_exprs([
    (@expr.col("bonus") + @expr.col("qty")).with_alias("t"),
  ])
  // The inserted projection follows the *frame's* column order
  // (qty before bonus), not the expression's reference order.
  assert_eq(
    optimized_text(plan),
    "SELECT [(col(bonus) + col(qty)) as t]\n" +
    "  SELECT [col(qty), col(bonus)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "select guard: reading every column inserts nothing" {
  let plan = lazy_frame(wide_df()).select_exprs([
    @expr.col("qty"),
    @expr.col("bonus"),
    @expr.col("region"),
  ])
  assert_eq(optimized_text(plan), plan.explain())
}

///|
test "select guard: an all-literal selection inserts nothing" {
  let plan = lazy_frame(wide_df()).select_exprs([
    @expr.lit_int(1).with_alias("one"),
  ])
  assert_eq(optimized_text(plan), "SELECT [1 as one]\n  SCAN [4×3]")
}

///|
test "select: a missing column is not kept alive, the rest narrow as usual" {
  let plan = lazy_frame(wide_df()).select_exprs([
    @expr.col("qty"),
    @expr.col("ghost"),
  ])
  // `ghost` exists nowhere, so only `qty` survives at the scan; the
  // user's expression still raises its own `ColumnNotFound` at collect.
  assert_eq(
    optimized_text(plan),
    "SELECT [col(qty), col(ghost)]\n" +
    "  SELECT [col(qty)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "filter: the requirement passes through, widened by the predicate's columns" {
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = lazy_frame(wide_df())
    .filter_where(predicate)
    .select_exprs([@expr.col("region")])
  assert_eq(
    optimized_text(plan),
    "SELECT [col(region)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  // At the root the requirement is unbounded: a bare filter's layout may
  // be observed in full, so nothing narrows.
  let bare = lazy_frame(wide_df()).filter_where(predicate)
  assert_eq(optimized_text(bare), bare.explain())
}

///|
test "sort: the requirement passes through, widened by the sort keys" {
  let plan = lazy_frame(wide_df())
    .sort_by([("bonus", @frame.SortOrder::Asc, @frame.NullOrder::NullsLast)])
    .select_exprs([@expr.col("qty")])
  assert_eq(
    optimized_text(plan),
    "SELECT [col(qty)]\n" +
    "  SORT [bonus Asc NullsLast]\n" +
    "    SELECT [col(qty), col(bonus)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "row windows pass the requirement through verbatim" {
  let base = lazy_frame(wide_df())
  let qty = [@expr.col("qty")]
  assert_eq(
    optimized_text(base.head(2).select_exprs(qty)),
    "SELECT [col(qty)]\n" +
    "  HEAD 2\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    optimized_text(base.tail(1).select_exprs(qty)),
    "SELECT [col(qty)]\n" +
    "  TAIL 1\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    optimized_text(base.slice(1, 3).select_exprs(qty)),
    "SELECT [col(qty)]\n" +
    "  SLICE [1, 3)\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns: defined names are subtracted, read names added" {
  let plan = lazy_frame(wide_df())
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")])
    .select_exprs([@expr.col("dbl"), @expr.col("region")])
  // `dbl` is served by the with_columns stage itself; the scan only owes
  // `region` (selected) and `qty` (read by the derivation).
  assert_eq(
    optimized_text(plan),
    "SELECT [col(dbl), col(region)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as dbl]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns: redefining a selected column keeps only what it reads" {
  let plan = lazy_frame(wide_df())
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("bonus")])
    .select_exprs([@expr.col("bonus")])
  // The selected `bonus` is a *defined* name: the original scan column
  // is dead, and only the derivation's input `qty` survives.
  assert_eq(
    optimized_text(plan),
    "SELECT [col(bonus)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as bonus]\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns at the root is a no-op (its full layout is the result)" {
  let plan = lazy_frame(wide_df()).with_columns([
    (@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl"),
  ])
  assert_eq(optimized_text(plan), plan.explain())
}

///|
test "join is a barrier, but each side restarts its own pass" {
  let opts = @frame.JoinOptions::on(["id"])
  // A selection *below* the left side narrows that side's scan.
  let narrowed_side = lazy_frame(left_df())
    .select_exprs([@expr.col("id")])
    .join(lazy_frame(right_df()), opts)
  assert_eq(
    optimized_text(narrowed_side),
    "JOIN Inner on [id]\n" +
    "  SELECT [col(id)]\n" +
    "    SELECT [col(id)]\n" +
    "      SCAN [3×2]\n" +
    "  SCAN [3×2]",
  )
  // A selection *above* the join narrows neither side: splitting a
  // requirement across suffix-renamed sides is out of spike scope.
  let above = lazy_frame(left_df())
    .join(lazy_frame(right_df()), opts)
    .select_exprs([@expr.col("city")])
  assert_eq(optimized_text(above), above.explain())
}

///|
test "aggregate: keys and aggregation reads survive, the rest narrows" {
  let plan = lazy_frame(wide_df())
    .group_by(["region"])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    optimized_text(plan),
    "AGGREGATE [col(qty).sum() as total] BY [region]\n" +
    "  SELECT [col(qty), col(region)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "aggregate guard: reading every column inserts nothing" {
  let plan = lazy_frame(wide_df())
    .group_by(["region"])
    .agg([
      @expr.col("qty").sum().with_alias("a"),
      @expr.col("bonus").max().with_alias("b"),
    ])
  assert_eq(optimized_text(plan), plan.explain())
}

///|
test "nested selects: the outer requirement never prunes the inner expression list" {
  let plan = lazy_frame(wide_df())
    .select_exprs([
      (@expr.col("qty") + @expr.col("bonus")).with_alias("t"),
      @expr.col("region"),
    ])
    .select_exprs([@expr.col("t")])
  // Dead-expression elimination is out of spike scope: the inner select
  // still evaluates `region`, and — reading every scan column — it also
  // inserts nothing below itself.
  assert_eq(optimized_text(plan), plan.explain())
}
