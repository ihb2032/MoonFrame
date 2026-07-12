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
/// Every builder that takes an array copies it, so a plan can never
/// observe later mutation of a caller's argument — the immutability the
/// paragraph above promises holds for the arguments too, not just the
/// captured frames.
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
/// hand-feel: `lazy_frame(df).filter(…).collect()`. (`lazy(df)`
/// would be the obvious shorter name, but `lazy` is reserved.)
pub fn lazy_frame(df : @frame.DataFrame) -> LazyFrame {
  LazyFrame::from(df)
}

///|
/// Defer `DataFrame::filter`: keep the rows where `predicate`
/// evaluates to `true` (`false` / null cells drop the row). Total at build
/// time — a predicate over missing columns or of a non-`Bool` type only
/// fails when the plan is collected.
pub fn LazyFrame::filter(self : LazyFrame, predicate : @expr.Expr) -> LazyFrame {
  { plan: Filter(self.plan, predicate) }
}

///|
/// Defer `DataFrame::with_columns`: derive new columns (or replace
/// same-named ones) from expressions, keeping every existing column.
pub fn LazyFrame::with_columns(
  self : LazyFrame,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: WithColumns(self.plan, exprs.copy()) }
}

///|
/// Defer `DataFrame::select`: project the frame down to exactly the
/// evaluated expressions (an all-scalar selection collapses to one row,
/// like its eager counterpart).
pub fn LazyFrame::select(
  self : LazyFrame,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: Select(self.plan, exprs.copy()) }
}

///|
/// Defer `DataFrame::sort`: reorder rows by one or more
/// `(key, order, null placement)` keys, later keys breaking ties. Each key
/// is an `Expr` evaluated over the whole frame at collect time, so a
/// missing column or a dtype clash only surfaces then.
pub fn LazyFrame::sort(
  self : LazyFrame,
  by : Array[(@expr.Expr, @frame.SortOrder, @frame.NullOrder)],
) -> LazyFrame {
  { plan: Sort(self.plan, by.copy()) }
}

///|
/// Defer `DataFrame::head`: the first `n` rows. Inherits eager `head`'s
/// total clamp — `n` beyond the frame keeps every row, negative `n` keeps
/// none — so collecting can't fail on this node. Also exposed under its
/// Polars / SQL name `limit` (via `#alias`): the same deferred node, so
/// `lf.limit(n)` collects to the same rows and `explain`s as `HEAD n`.
#alias(limit)
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
/// Defer `DataFrame::slice`: the half-open row window `[start, end)`.
/// Unlike `head` / `tail` this mirrors eager `slice`'s bounds checks —
/// out-of-range bounds (`IndexOutOfBounds`) or `start > end`
/// (`InvalidOperation`) surface when the plan is collected.
pub fn LazyFrame::slice(self : LazyFrame, start : Int, end : Int) -> LazyFrame {
  { plan: Slice(self.plan, start, end) }
}

///|
/// Defer `DataFrame::drop`: remove the columns named by `exprs` (bare `col`
/// references), keeping every other column. A name absent from the frame, or a
/// non-`col` expression, surfaces as the eager `drop`'s error at collect time.
pub fn LazyFrame::drop(
  self : LazyFrame,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: Drop(self.plan, exprs.copy()) }
}

///|
/// Defer `DataFrame::rename`: apply each `(from, to)` rename in order. A
/// missing source name or a colliding target surfaces at collect time.
pub fn LazyFrame::rename(
  self : LazyFrame,
  pairs : Array[(String, String)],
) -> LazyFrame {
  { plan: Rename(self.plan, pairs.copy()) }
}

///|
/// Defer `DataFrame::rename_with`: rename every column through `f`
/// (`new = f(old)`). A collision — two columns `f` maps to the same name —
/// surfaces as the eager `rename_with`'s `DuplicateColumn` at collect time.
pub fn LazyFrame::rename_with(
  self : LazyFrame,
  f : (String) -> String,
) -> LazyFrame {
  { plan: RenameWith(self.plan, f) }
}

///|
/// Defer `DataFrame::unique`: keep the first occurrence of each distinct row,
/// in first-appearance order. Total like its eager counterpart.
pub fn LazyFrame::unique(self : LazyFrame) -> LazyFrame {
  { plan: Unique(self.plan) }
}

///|
/// Defer `DataFrame::drop_nulls`: drop every row with a null in `subset` (a
/// list of `col` references), or — with no `subset` — in any column. A name
/// absent from the frame surfaces at collect time.
pub fn LazyFrame::drop_nulls(
  self : LazyFrame,
  subset? : Array[@expr.Expr],
) -> LazyFrame {
  { plan: DropNulls(self.plan, subset.map(s => s.copy())) }
}

///|
/// Defer `DataFrame::fill_null`: replace every null cell, in every column,
/// with `value`. A column whose dtype does not match `value` surfaces the
/// eager verb's error at collect time.
pub fn LazyFrame::fill_null(
  self : LazyFrame,
  value : @types.Scalar,
) -> LazyFrame {
  { plan: FillNull(self.plan, value) }
}

///|
/// Defer `DataFrame::sum`: collapse the plan to a 1-row frame of each column's
/// sum (numeric columns their sum in the source dtype, non-numeric columns a
/// `Null` cell). `collect` equals the eager `df.sum()`.
pub fn LazyFrame::sum(self : LazyFrame) -> LazyFrame {
  { plan: Reduce(self.plan, LazyReduceOp::Sum) }
}

///|
/// Defer `DataFrame::mean`: a 1-row frame of each numeric column's mean as
/// `Float` (empty / all-null → `Null`), non-numeric columns a `Null` cell.
pub fn LazyFrame::mean(self : LazyFrame) -> LazyFrame {
  { plan: Reduce(self.plan, LazyReduceOp::Mean) }
}

///|
/// Defer `DataFrame::min`: a 1-row frame of each numeric column's minimum
/// (`NaN` skipped, source dtype kept), non-numeric columns a `Null` cell.
pub fn LazyFrame::min(self : LazyFrame) -> LazyFrame {
  { plan: Reduce(self.plan, LazyReduceOp::Min) }
}

///|
/// Defer `DataFrame::max`: the maximum counterpart of `min`.
pub fn LazyFrame::max(self : LazyFrame) -> LazyFrame {
  { plan: Reduce(self.plan, LazyReduceOp::Max) }
}

///|
/// Defer `DataFrame::count`: a 1-row `Int` frame of each column's non-null cell
/// count (every dtype).
pub fn LazyFrame::count(self : LazyFrame) -> LazyFrame {
  { plan: Reduce(self.plan, LazyReduceOp::Count) }
}

///|
/// Defer `DataFrame::null_count`: a 1-row `Int` frame of each column's null
/// count — the complement of `count`.
pub fn LazyFrame::null_count(self : LazyFrame) -> LazyFrame {
  { plan: Reduce(self.plan, LazyReduceOp::NullCount) }
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
/// Defer `DataFrame::group_by`: attach grouping key expressions to the plan
/// and return a `LazyGroupBy` waiting for its aggregations. Each key is an
/// `Expr` evaluated over the whole frame at collect time (a bare `col`, a
/// derived key, or a length-1 key broadcasting to one group), exactly like
/// the eager verb. Nothing is partitioned yet — like every builder this is
/// total, so a missing column, a dtype clash, or a repeated output name
/// only surfaces at collect time, as the eager `group_by`'s
/// `ColumnNotFound` / `TypeMismatch` / `DuplicateColumn`. Only
/// `LazyGroupBy::agg` grows the plan; a `LazyGroupBy` is never itself
/// collectable, mirroring how the eager `GroupedDataFrame` is not a frame.
pub fn LazyFrame::group_by(
  self : LazyFrame,
  keys : Array[@expr.Expr],
) -> LazyGroupBy {
  { plan: self.plan, keys: keys.copy() }
}

///|
/// A deferred `group_by` awaiting its aggregations — the lazy mirror of
/// the eager `GroupedDataFrame` stage in `group_by(keys).agg(…)`,
/// except it holds no groups: just the input plan and the key
/// expressions, which `agg` completes into a single `Aggregate` node. Both
/// fields stay private — a `LazyGroupBy` is only ever the step between
/// `LazyFrame::group_by` and `LazyGroupBy::agg`, and sharing one across
/// several `agg` calls just forks the plan, like every other builder.
pub struct LazyGroupBy {
  priv plan : LogicalPlan
  priv keys : Array[@expr.Expr]
}

///|
/// Complete the deferred group-by: defer `group_by(keys).agg(exprs)`
/// as one `Aggregate` node and return to the `LazyFrame` chain. Each
/// expression must be reduction-shaped (aggregations / literals and their
/// combinators — a bare column reference is not); building stays total,
/// so a non-reduction expression, a missing column, a dtype clash, or an
/// output-name collision waits for collect and surfaces as the eager
/// `agg` error (`InvalidOperation` / `ColumnNotFound` /
/// `TypeMismatch` / `DuplicateColumn`).
pub fn LazyGroupBy::agg(
  self : LazyGroupBy,
  exprs : Array[@expr.Expr],
) -> LazyFrame {
  { plan: Aggregate(self.plan, self.keys, exprs.copy()) }
}

///|
/// Run the plan and materialize the result — the only point in the lazy
/// layer that computes (or fails). The plan first passes through the
/// total optimizer rewrites (`optimize.mbt`): filters sink below the
/// stages they provably commute with, so rows drop as early as possible,
/// and a required-columns pass then drops scan columns nothing downstream
/// reads (and, for a `scan_csv` source, never parses them). The rewrites'
/// contract is exactly this method's, so they change
/// what work happens, never what comes back. The (optimized) plan is then
/// walked bottom-up, delegating each node to the public eager operator it
/// defers, so the result is bitwise-equal to running the same verbs
/// eagerly in the same order, and the errors are exactly the eager
/// operators' errors (`ColumnNotFound`, `TypeMismatch`,
/// `IndexOutOfBounds`, …). To see the rewritten plan this method actually
/// runs, render it with `explain(optimized=true)`.
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
/// By default this is the plan **as built** — a faithful mirror of the
/// chained verbs, which is the package's contract. Pass `optimized=true`
/// to render the plan `collect` actually runs instead: a sunk `FILTER`
/// appears below the stages it crossed, and the projection pushdown shows
/// up as a narrowing `SELECT` over an in-memory `SCAN` or as the column list
/// on a `SCAN_CSV` source, so printing both forms is the before/after view
/// of what the optimizer moved and pruned. (Polars' `LazyFrame::explain(optimized)` is the
/// namesake; plans are immutable, so the flag rewrites a copy and never
/// perturbs this frame.)
///
/// Total either way — the rewrite is a pure tree walk, so a plan that
/// would fail to `collect` still explains, which is the point: inspect
/// first, compute later.
pub fn LazyFrame::explain(
  self : LazyFrame,
  optimized? : Bool = false,
) -> String {
  let plan = if optimized { optimize(self.plan) } else { self.plan }
  let buf = StringBuilder::new()
  render(plan, buf, 0)
  buf.to_string()
}
