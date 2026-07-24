// The projection pass is idempotent: `push_projection(push_projection(p)) ==
// push_projection(p)` for every plan shape. It used to stack a second,
// identical narrowing `Select` over an in-memory scan on each pass;
// `already_narrows_inmemory` now recognises a bare-column `Select` as the
// narrowing and inserts nothing below it. `push_projection` is package-private,
// so the property is asserted here rather than through the public `explain`.
//
// Full `optimize` (predicate pass then projection pass) is idempotent on every
// shape *except* one: a filter that can sink past a `Select` the projection
// pass inserts. The predicate pass runs first, so on a re-optimize it sinks the
// filter below that inserted select and the projection pass rebuilds around the
// new position — a fixed-point-across-passes concern (deferred, see `optimize`).
// The cases asserted here avoid it.

///|
/// Frames built through `io`, so this white-box test needs no `series` import
/// (the `lazy` package imports it only for `test`).
fn idem_frame() -> @frame.DataFrame raise @types.DataError {
  @io.parse_csv_str("a,b,c\n1,4,7\n2,5,8\n3,6,9")
}

///|
fn idem_other() -> @frame.DataFrame raise @types.DataError {
  @io.parse_csv_str("a,d\n1,10\n2,20\n3,30")
}

///|
fn plan_render(plan : LogicalPlan) -> String {
  let buf = StringBuilder::new()
  render(plan, buf, 0)
  buf.to_string()
}

///|
/// `push_projection(push_projection(plan)) == push_projection(plan)`, compared
/// through the rendered form (the `LogicalPlan` closures have no `Eq`, and
/// `render` already prints every field that distinguishes two plans). Returns
/// the fixed point so a caller can also pin what it converged to.
fn assert_projection_idempotent(plan : LogicalPlan) -> String raise {
  let once = push_projection(plan, None)
  let twice = push_projection(once, None)
  assert_eq(plan_render(once), plan_render(twice))
  plan_render(once)
}

///|
/// `optimize(optimize(plan)) == optimize(plan)` — both passes. Only sound on
/// plans without the filter-sinks-past-an-inserted-select interaction.
fn assert_optimize_idempotent(plan : LogicalPlan) -> String raise {
  let once = optimize(plan)
  assert_eq(plan_render(once), plan_render(optimize(once)))
  plan_render(once)
}

///|
test "projection pushdown is idempotent across plan shapes" {
  let df = idem_frame()
  let plans = [
    // A bare projection directly over the scan — the shape that used to stack.
    LazyFrame::LazyFrame(df).select([@expr.col("a")]).plan,
    // A narrowing select with a row window between it and the scan.
    LazyFrame::LazyFrame(df).head(2).select([@expr.col("a")]).plan,
    // A computed selection (narrows to what it reads, keeps its insert).
    LazyFrame::LazyFrame(df).select([
      (@expr.col("a") + @expr.col("b")).with_alias("s"),
    ]).plan,
    // Filter + narrowing select: the predicate columns stay alive at the scan.
    // (This is the shape whose *full*-optimize idempotence is deferred; the
    // projection pass alone is stable on it.)
    LazyFrame::LazyFrame(df)
    .filter(@expr.col("b").gt(@expr.lit_int(4)))
    .select([@expr.col("a")]).plan,
    // A projection reading every column narrows nothing.
    LazyFrame::LazyFrame(df).select([
      @expr.col("a"),
      @expr.col("b"),
      @expr.col("c"),
    ]).plan,
  ]
  for plan in plans {
    assert_projection_idempotent(plan) |> ignore
  }
}

///|
test "the bare-projection fixed point inserts no redundant narrowing select" {
  let df = idem_frame()
  // The redundant double is gone from the first pass: the select is itself the
  // narrowing over the in-memory scan.
  assert_eq(
    assert_projection_idempotent(
      LazyFrame::LazyFrame(df).select([@expr.col("a")]).plan,
    ),
    "SELECT [col(a)]\n  SCAN [3×3]",
  )
  // With a row window between, the narrowing select survives (it lets HEAD
  // carry one column instead of three) — and re-optimizing does not add a
  // second one.
  assert_eq(
    assert_projection_idempotent(
      LazyFrame::LazyFrame(df).head(2).select([@expr.col("a")]).plan,
    ),
    "SELECT [col(a)]\n  HEAD 2\n    SELECT [col(a)]\n      SCAN [3×3]",
  )
}

///|
test "full optimize is idempotent on plans without the filter-sink interaction" {
  let df = idem_frame()
  assert_optimize_idempotent(
    LazyFrame::LazyFrame(df).select([@expr.col("a")]).plan,
  )
  |> ignore
  assert_optimize_idempotent(
    LazyFrame::LazyFrame(df).head(2).select([@expr.col("a")]).plan,
  )
  |> ignore
  // A join: each side restarts its own projection pass, and the narrowing
  // select on the left side is not doubled.
  let joined = LazyFrame::LazyFrame(df)
    .select([@expr.col("a")])
    .join(
      LazyFrame::LazyFrame(idem_other()),
      @frame.JoinOptions::on([@expr.col("a")]),
    ).plan
  assert_eq(
    assert_optimize_idempotent(joined),
    "JOIN Inner on [col(a)]\n" +
    "  SELECT [col(a)]\n" +
    "    SCAN [3×3]\n" +
    "  SCAN [3×2]",
  )
}
