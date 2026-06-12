///|
/// The public face of the lazy layer: `LazyFrame` wraps a `LogicalPlan`
/// and grows it through builder methods that mirror the eager `DataFrame`
/// verbs name-for-name. Building is **total** — every builder just wraps
/// the plan in one more node, so a `LazyFrame` can always be constructed,
/// chained, and `explain`ed, even when collecting it would fail. All
/// computation (and all failure) happens in `collect`, which interprets
/// the plan through the public eager operators: with no optimizer in
/// front, `lazy_frame(df).f(…).g(…).collect()` is bitwise-equal to
/// `df.f(…).g(…)` — the faithful-deferred-executor contract every test in
/// `lazy_test.mbt` pins.
///
/// The entry point is the static constructor `LazyFrame::from(df)` with
/// the free-function alias `lazy_frame(df)` (the `read_csv` feel) — not a
/// `DataFrame` method, which would have to live in `frame` and close a
/// `frame ↔ lazy` import cycle, and not `lazy(df)`, since `lazy` is a
/// MoonBit reserved word.
pub struct LazyFrame {
  priv plan : LogicalPlan
}

///|
/// Wrap an in-memory frame as the leaf of a new plan (a `Scan` node).
/// Total — the frame is captured as-is, and frames are immutable, so the
/// plan can never observe later state. Named after the `Series::from_*` /
/// `DataFrame::from_rows` constructor family.
pub fn LazyFrame::from(df : @frame.DataFrame) -> LazyFrame {
  { plan: Scan(df) }
}

///|
/// Free-function alias of `LazyFrame::from`, for the `read_csv(path)`
/// hand-feel: `lazy_frame(df).filter_where(…).collect()`. (`lazy(df)`
/// would be the obvious shorter name, but `lazy` is reserved.)
pub fn lazy_frame(df : @frame.DataFrame) -> LazyFrame {
  LazyFrame::from(df)
}

///|
/// Defer `DataFrame::filter_where`: keep the rows where `predicate`
/// evaluates to `true` (`false` / null cells drop the row). Total at build
/// time — a predicate over missing columns or of a non-`Bool` type only
/// fails when the plan is collected.
pub fn LazyFrame::filter_where(
  self : LazyFrame,
  predicate : @expr.Expr,
) -> LazyFrame {
  { plan: Filter(self.plan, predicate) }
}

///|
/// Defer `DataFrame::with_columns`: derive new columns (or replace
/// same-named ones) from expressions, keeping every existing column.
pub fn LazyFrame::with_columns(
  self : LazyFrame,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: WithColumns(self.plan, exprs) }
}

///|
/// Defer `DataFrame::select_exprs`: project the frame down to exactly the
/// evaluated expressions (an all-scalar selection collapses to one row,
/// like its eager counterpart).
pub fn LazyFrame::select_exprs(
  self : LazyFrame,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: Select(self.plan, exprs) }
}

///|
/// Defer `DataFrame::sort_by`: reorder rows by one or more
/// `(column, order, null placement)` keys, later keys breaking ties.
pub fn LazyFrame::sort_by(
  self : LazyFrame,
  by : Array[(String, @frame.SortOrder, @frame.NullOrder)],
) -> LazyFrame {
  { plan: Sort(self.plan, by) }
}

///|
/// Defer `DataFrame::head`: the first `n` rows. Inherits eager `head`'s
/// total clamp — `n` beyond the frame keeps every row, negative `n` keeps
/// none — so collecting can't fail on this node.
pub fn LazyFrame::head(self : LazyFrame, n : Int) -> LazyFrame {
  { plan: Head(self.plan, n) }
}

///|
/// Defer `DataFrame::tail`: the last `n` rows, with the same total clamp
/// as `head`.
pub fn LazyFrame::tail(self : LazyFrame, n : Int) -> LazyFrame {
  { plan: Tail(self.plan, n) }
}

///|
/// `head` under its SQL name (Polars' `limit` ≡ `head`): defers the same
/// node, collects to the same rows, and `explain`s as `HEAD n`.
pub fn LazyFrame::limit(self : LazyFrame, n : Int) -> LazyFrame {
  self.head(n)
}

///|
/// Defer `DataFrame::slice`: the half-open row window `[start, end)`.
/// Unlike `head` / `tail` this mirrors eager `slice`'s bounds checks —
/// out-of-range bounds (`IndexOutOfBounds`) or `start > end`
/// (`InvalidOperation`) surface when the plan is collected.
pub fn LazyFrame::slice(self : LazyFrame, start : Int, end : Int) -> LazyFrame {
  { plan: Slice(self.plan, start, end) }
}

///|
/// Defer `DataFrame::join`: combine this plan's output (the left side)
/// with another plan's output (the right side) under `options` — each
/// side carries its own deferred pipeline. Key resolution, type checks,
/// and the cross-join key rules all surface at collect time.
pub fn LazyFrame::join(
  self : LazyFrame,
  other : LazyFrame,
  options : @frame.JoinOptions,
) -> LazyFrame {
  { plan: Join(self.plan, other.plan, options) }
}

///|
/// Defer `DataFrame::group_by`: attach grouping keys to the plan and
/// return a `LazyGroupBy` waiting for its aggregations. Nothing is
/// partitioned yet — like every builder this is total, so missing or
/// repeated key names only surface at collect time, as the eager
/// `group_by`'s `ColumnNotFound` / `DuplicateColumn`. Only
/// `LazyGroupBy::agg` grows the plan; a `LazyGroupBy` is never itself
/// collectable, mirroring how the eager `GroupedDataFrame` is not a frame.
pub fn LazyFrame::group_by(
  self : LazyFrame,
  keys : Array[String],
) -> LazyGroupBy {
  { plan: self.plan, keys }
}

///|
/// A deferred `group_by` awaiting its aggregations — the lazy mirror of
/// the eager `GroupedDataFrame` stage in `group_by(keys).agg_exprs(…)`,
/// except it holds no groups: just the input plan and the key names,
/// which `agg` completes into a single `Aggregate` node. Both fields stay
/// private — a `LazyGroupBy` is only ever the step between
/// `LazyFrame::group_by` and `LazyGroupBy::agg`, and sharing one across
/// several `agg` calls just forks the plan, like every other builder.
pub struct LazyGroupBy {
  priv plan : LogicalPlan
  priv keys : Array[String]
}

///|
/// Complete the deferred group-by: defer `group_by(keys).agg_exprs(exprs)`
/// as one `Aggregate` node and return to the `LazyFrame` chain. Each
/// expression must be reduction-shaped (aggregations / literals and their
/// combinators — a bare column reference is not); building stays total,
/// so a non-reduction expression, a missing column, a dtype clash, or an
/// output-name collision waits for collect and surfaces as the eager
/// `agg_exprs` error (`InvalidOperation` / `ColumnNotFound` /
/// `TypeMismatch` / `DuplicateColumn`).
pub fn LazyGroupBy::agg(
  self : LazyGroupBy,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: Aggregate(self.plan, self.keys, exprs) }
}

///|
/// Run the plan and materialize the result — the only point in the lazy
/// layer that computes (or fails). The plan first passes through the
/// total projection-pushdown rewrite (`optimize.mbt`), which drops scan
/// columns nothing downstream reads; the rewrite's contract is exactly
/// this method's, so it changes what work happens, never what comes
/// back. The (optimized) plan is then walked bottom-up, delegating each
/// node to the public eager operator it defers, so the result is
/// bitwise-equal to running the same verbs eagerly in the same order,
/// and the errors are exactly the eager operators' errors
/// (`ColumnNotFound`, `TypeMismatch`, `IndexOutOfBounds`, …). `explain`
/// is untouched: it renders the plan as built.
pub fn LazyFrame::collect(
  self : LazyFrame,
) -> @frame.DataFrame raise @types.DataError {
  execute(optimize(self.plan))
}

///|
/// Render the logical plan as an indented tree — the root operation on
/// the first line, inputs two spaces deeper, expressions in their
/// documented `Show` form, and `SCAN [rows×cols]` leaves:
///
/// ```text
/// SELECT [col(region), col(adj)]
///   WITH_COLUMNS [(col(revenue) * 1.1) as adj]
///     FILTER (col(region) == "west")
///       SCAN [4×3]
/// ```
///
/// Total — a plan that would fail to `collect` still explains, which is
/// the point: inspect first, compute later.
pub fn LazyFrame::explain(self : LazyFrame) -> String {
  let buf = StringBuilder::new()
  render(self.plan, buf, 0)
  buf.to_string()
}
