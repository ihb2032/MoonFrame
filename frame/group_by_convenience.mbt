// The `group_by` convenience verbs — Polars' `GroupBy.sum()` / `.mean()` /
// `.count()` / `.len()` / … — one aggregation applied to **every non-key
// column** of the grouped frame. Each is sugar: `sum()` is exactly
// `agg([col(n).sum() for every non-key column n])`, in source column order,
// so every rule the general `agg` documents — key columns heading the output
// in key order, one row per group in first-appearance order, the shared
// aggregation kernel's dtype / null / `NaN` semantics — applies verbatim, and
// a frame whose non-key columns include a non-numeric one surfaces `agg`'s
// `TypeMismatch` for the numeric-only ops (`sum` / `mean` / `median` /
// `quantile` / `std` / `variance`); call `agg` with explicit columns to
// aggregate a mixed frame selectively.
//
// "Non-key" is by name: the columns excluded are exactly those whose name a
// key output name matches — a bare `col("k")` key excludes the source column
// `k`, and a derived key excludes the column its output name lands on (the
// leftmost column it reads). A frame whose every column is a key reduces to
// the distinct key tuples, `agg([])`'s shape.
//
// `count` / `len` are different verbs, Polars' split: `count()` holds each
// non-key column's **non-null cell count** (an `Int` cell per column, the
// `Expr::count` reduction), while `len()` is the single `Int` column
// `"len"` holding each group's **row count** — nulls included, dtype-blind,
// the one convenience that ignores the columns entirely.

///|
/// The shared driver: apply `op` to a bare-column expression for every
/// non-key column, in source column order, and defer to `agg`.
fn GroupedDataFrame::agg_op_all(
  self : GroupedDataFrame,
  op : (@expr.Expr) -> @expr.Expr,
) -> DataFrame raise @types.DataError {
  let excluded : Map[String, Unit] = Map([])
  for c in self.key_columns {
    excluded[c.name()] = ()
  }
  let exprs : Array[@expr.Expr] = []
  for name in self.source.columns() {
    if !excluded.contains(name) {
      exprs.push(op(@expr.col(name)))
    }
  }
  self.agg(exprs)
}

///|
/// Sum of every non-key column, per group — `agg` with `col(n).sum()` for
/// each non-key column `n`: numeric columns keep their dtype, an all-null
/// group sums to the additive identity, and a non-numeric non-key column
/// `raise`s `TypeMismatch` (Polars' `gb.sum()`).
pub fn GroupedDataFrame::sum(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.sum())
}

///|
/// Mean of every non-key column, per group — `agg` with `col(n).mean()`
/// for each non-key column `n`: `Float` cells, an all-null group a `Null`
/// cell (Polars' `gb.mean()`).
pub fn GroupedDataFrame::mean(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.mean())
}

///|
/// Median of every non-key column, per group — `agg` with `col(n).median()`
/// for each non-key column `n` (Polars' `gb.median()`).
pub fn GroupedDataFrame::median(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.median())
}

///|
/// `q`-th quantile of every non-key column, per group, under
/// `interpolation` (default `Nearest`) — `agg` with `col(n).quantile(q)`
/// for each non-key column `n` (Polars' `gb.quantile(q)`).
pub fn GroupedDataFrame::quantile(
  self : GroupedDataFrame,
  q : Double,
  interpolation? : @series.QuantileInterpolation = @series.QuantileInterpolation::Nearest,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.quantile(q, interpolation~))
}

///|
/// Sample standard deviation (`ddof = 1`) of every non-key column, per
/// group (Polars reaches the same statistic through `agg`; MoonFrame spells
/// the convenience for symmetry with `DataFrame::std`).
pub fn GroupedDataFrame::std(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.std())
}

///|
/// Sample variance (`ddof = 1`) of every non-key column, per group — `std`
/// squared; spelled out because `var` is a reserved MoonBit word.
pub fn GroupedDataFrame::variance(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.variance())
}

///|
/// Minimum of every non-key column, per group — total over every dtype, so
/// `Bool` / `String` columns reduce too (a `NaN` is skipped), an all-null
/// group a `Null` cell (Polars' `gb.min()`).
pub fn GroupedDataFrame::min(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.min())
}

///|
/// Maximum of every non-key column, per group — `min` with the order
/// reversed, sharing its dtype-total and `NaN`-skipping rules (Polars'
/// `gb.max()`).
pub fn GroupedDataFrame::max(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.max())
}

///|
/// Non-null cell count of every non-key column, per group — an `Int` cell
/// per column, total over every dtype (Polars' `gb.count()`; the row count
/// regardless of nulls is `len`).
pub fn GroupedDataFrame::count(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.count())
}

///|
/// First cell of every non-key column, per group, in group row order —
/// positional, so a null first cell is a `Null` cell (Polars' `gb.first()`).
pub fn GroupedDataFrame::first(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.first())
}

///|
/// Last cell of every non-key column, per group, in group row order — the
/// trailing mirror of `first` (Polars' `gb.last()`).
pub fn GroupedDataFrame::last(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.last())
}

///|
/// Distinct non-null value count of every non-key column, per group — an
/// `Int` cell per column over every dtype, with the documented `n_unique`
/// rule (nulls skipped, every `NaN` one bucket; Polars' `gb.n_unique()`).
pub fn GroupedDataFrame::n_unique(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  self.agg_op_all(e => e.n_unique())
}

///|
/// Row count per group as a single `Int` column named `"len"` — nulls
/// included, dtype-blind: the one convenience that aggregates no column,
/// reading the groups directly (Polars' `gb.len()`; per-column non-null
/// counts are `count`). Raises only through the frame assembly below, whose
/// failure paths cannot fire here except a key named `"len"` colliding
/// (`DuplicateColumn`).
pub fn GroupedDataFrame::len(
  self : GroupedDataFrame,
) -> DataFrame raise @types.DataError {
  // The same never-abort guard `agg` runs: `g[0]` below indexes the source
  // on the strength of the construction invariants.
  self.check_handle_invariants()
  let reps = self.groups.map(g => g[0])
  let out_cols = self.key_columns.map(c => c.gather_series(reps))
  let sizes = Series::from_ints(
    "len",
    self.groups.map(g => g.length().to_int64()),
  )
  DataFrame::from_parts([..out_cols, sizes], self.groups.length())
}
