// Whole-frame statistical reductions on a `DataFrame`. Each of `sum`,
// `mean`, `min`, `max`, and `count` collapses the frame to a **single row**
// — one cell per source column, names and order preserved — mirroring
// Polars' `df.sum()` / `df.mean()` / `df.min()` / `df.max()` / `df.count()`,
// which return a 1-row frame rather than a scalar. `null_count` is the
// same-shaped census: one `Int` cell per column counting its nulls, and
// `describe` is the per-column summary report — one row per source column
// instead of one column per source column.
//
// Cell semantics, uniform across `sum` / `mean` / `min` / `max`, follow the
// aggregation rules the series reducer's header states canonically (the
// evaluator-side enumeration is the Aggregations bullet); what
// these verbs add on top of them is the *frame shape*:
//   - a **numeric** column (`Int` / `Float`) reduces to its value — `sum`,
//     `min`, and `max` keep the source dtype, `mean` is always `Float`;
//   - a **non-numeric** column (`Bool` / `String`) reduces to a `Null` cell
//     kept in the source dtype. So `sum` / `min` / `max` preserve the frame's
//     schema (numeric cells filled, non-numeric cells null) and `mean`
//     promotes only the numeric columns to `Float`.
//
// `count` is the exception: the **non-null cell count** as `Int` for every
// column regardless of dtype — the 1-row transpose of `null_count`.
//
// Two deliberate choices flow from the uniform numeric-only rule:
//   - `min` / `max` null out `Bool` / `String` columns, where Polars would
//     instead order them. The numeric-only rule is kept uniform across the
//     four reductions for one predictable frame shape; a caller who wants a
//     `Bool` / `String` extremum reads the column's total `Series::min`
//     / `max`, which order every dtype.
//   - an empty / all-null numeric column follows the per-group / per-scope
//     reducers, not the `Series` API: `sum` is the additive identity
//     (`0` / `0.0`), while `mean` / `min` / `max` yield a `Null` cell rather
//     than `Series::mean`'s `InvalidOperation` — a whole-frame reduction
//     always produces a value slot. (This is why these go through the
//     reduction kernel's total accessors, not `DataFrame`'s old raising
//     per-column reductions.)
//
// A 0-column frame reduces to `1×0`: there is one summary row per source
// frame whatever its shape, and with no column to reduce that row is simply
// empty. `reduce_to_row` passes the height explicitly for that reason, as
// `null_count` does.
//
// The per-column scalar reductions (`df.sum("col")` → `Scalar`) are
// retired: read one column's scalar through its `Series`, e.g.
// `df.get_column("col").sum()` (= Polars `df["col"].sum()`).

///|
/// The fixed set of whole-frame reductions, one per public method below. Kept
/// separate from the kernel's open-ended `ReduceOp` (which the expression
/// aggregations also feed) on purpose: `df.sum()` and its four siblings are a
/// closed Polars-aligned set, and they dispatch to the total `Series`
/// accessors here rather than routing through `reducer_for`, so a new kernel
/// reduction (`std` / `median` / `first` / …) must *not* silently become a
/// frame-wide method — several would misalign Polars (its `df.first()` and
/// `df.n_unique()` are row operations, not per-column reductions). Decoupling
/// the tag keeps this match closed at five without a dead arm.
priv enum FrameReduceOp {
  Sum
  Mean
  Min
  Max
  Count
}

///|
/// Sum every column as a 1-row `DataFrame`: numeric columns hold their sum
/// (source dtype preserved), non-numeric columns a `Null` cell — the same
/// uniform cell semantics every whole-frame reduction here follows. For one
/// column's scalar use `df.get_column(name).sum()`.
pub fn DataFrame::sum(self : DataFrame) -> DataFrame raise @types.DataError {
  self.reduce_to_row(FrameReduceOp::Sum)
}

///|
/// Arithmetic mean of every column as a 1-row `DataFrame`: numeric columns
/// hold their mean as `Float` (an empty / all-null numeric column → `Null`),
/// non-numeric columns a `Null` cell in their own dtype.
pub fn DataFrame::mean(self : DataFrame) -> DataFrame raise @types.DataError {
  self.reduce_to_row(FrameReduceOp::Mean)
}

///|
/// Minimum of every column as a 1-row `DataFrame`: numeric columns hold their
/// minimum non-null cell (`Float` `NaN` skipped, source dtype preserved),
/// non-numeric columns a `Null` cell. Note this nulls `Bool` / `String`
/// columns rather than ordering them — use `Series::min` for a typed
/// extremum over any dtype.
pub fn DataFrame::min(self : DataFrame) -> DataFrame raise @types.DataError {
  self.reduce_to_row(FrameReduceOp::Min)
}

///|
/// Maximum of every column as a 1-row `DataFrame`. Mirrors `min` with the
/// order reversed; the `NaN`-skipping and non-numeric-`Null` rules are
/// identical.
pub fn DataFrame::max(self : DataFrame) -> DataFrame raise @types.DataError {
  self.reduce_to_row(FrameReduceOp::Max)
}

///|
/// Non-null cell count of every column as a 1-row `Int` `DataFrame` — the
/// row-oriented counterpart of the column-oriented `null_count`. Total over
/// every dtype (no numeric restriction).
pub fn DataFrame::count(self : DataFrame) -> DataFrame raise @types.DataError {
  self.reduce_to_row(FrameReduceOp::Count)
}

///|
/// Reduce every column under `op` into a single output cell, assembling the
/// length-1 result columns into a 1-row `DataFrame`. The shared driver behind
/// the five public reductions above.
///
/// The result is one row for every source frame, its own height included: a
/// 0-row frame reduces to a 1-row summary, and a 0-column one to `1×0` — the
/// row with nothing in it. The height is passed explicitly for the latter,
/// since there is then no column to infer it from.
///
/// Raises only through the 1-row `DataFrame::from_parts`, whose failure paths
/// (duplicate name / length mismatch) cannot fire here — the output column
/// names are exactly `self`'s (already unique) and every output column has
/// length 1 — so the raise is forwarded, never actually taken.
fn DataFrame::reduce_to_row(
  self : DataFrame,
  op : FrameReduceOp,
) -> DataFrame raise @types.DataError {
  let cols : Array[Series] = []
  for s in self.column_series() {
    cols.push(reduce_column(s, op))
  }
  DataFrame::from_parts(cols, 1)
}

///|
/// Reduce one source column under `op` to a length-1 output column. Returns
/// the `(cell, probe)` of the reduction — `cell` is the reduced `Scalar` (or
/// `Scalar::Null`), `probe` fixes the output dtype — projected onto a typed
/// column by the shared `scalars_to_series`.
///
/// Numeric-only for `sum` / `mean` / `min` / `max`: a `Bool` / `String`
/// column yields a `Null` cell kept in its source dtype (`probe = dtype`),
/// while a numeric column reduces (`mean` retyped to `Float`). `count` is
/// dtype-independent — always the non-null count as `Int`. This is distinct
/// from the expression engine's aggregation kernel (which reduces every dtype and
/// raises on a non-numeric `sum` / `mean`): the whole-frame reductions
/// tolerate non-reducible columns by nulling them, matching `df.sum()`.
fn reduce_column(
  s : Series,
  op : FrameReduceOp,
) -> Series raise @types.DataError {
  let name = s.name()
  // The column's own dtype doubles as the numeric test and, for the
  // dtype-preserving reductions, the output `probe`. A column dtype is never
  // `Null` (that is a value-level concept), so `is_numeric` decides the test
  // without a dead arm and `scalars_to_series` never sees the dtype it rejects.
  let dtype = s.dtype()
  let numeric = dtype.is_numeric()
  let (cell, probe) = match op {
    FrameReduceOp::Count =>
      (@types.Scalar::Int(s.count().to_int64()), @types.DataType::Int)
    // `Series::sum` only raises for a non-numeric dtype, which the `numeric`
    // guard excludes — so the call never actually raises here.
    FrameReduceOp::Sum =>
      (if numeric { s.sum() } else { @types.Scalar::Null }, dtype)
    FrameReduceOp::Min =>
      (if numeric { s.min() } else { @types.Scalar::Null }, dtype)
    FrameReduceOp::Max =>
      (if numeric { s.max() } else { @types.Scalar::Null }, dtype)
    FrameReduceOp::Mean => {
      // `mean_opt` is the total form of `Series::mean`: `Some` for a numeric
      // column with a non-null cell, `None` for an empty / all-null one (where
      // a whole-frame reduction wants a `Null` cell, not `InvalidOperation`).
      let cell = if numeric {
        match s.mean_opt() {
          Some(m) => @types.Scalar::Float(m)
          None => @types.Scalar::Null
        }
      } else {
        @types.Scalar::Null
      }
      (cell, if numeric { @types.DataType::Float } else { dtype })
    }
  }
  scalars_to_series(probe, name, [cell])
}

///|
/// Per-column null-count summary, returned as a `1 × ncols` DataFrame.
/// Column names match `self.columns()` verbatim, in the same order, and
/// every output column has dtype `Int` with a single non-null cell —
/// the null count of the source column.
///
/// The summary is one row wide of whatever the source has, so a 0-column
/// frame summarises to `1×0` — the row is there, it just has nothing in it.
/// The height is passed explicitly for that reason: with no column to anchor
/// it, an inferred one would round the row away.
///
/// Raises only because the summary is built through the fallible
/// `DataFrame::from_parts`; its failure paths (duplicate-name, length-mismatch)
/// cannot fire here — the names come from `self.column_series()` (already
/// unique) and every output column has length 1 — so the raise is forwarded,
/// never actually taken.
pub fn DataFrame::null_count(
  self : DataFrame,
) -> DataFrame raise @types.DataError {
  let cols = self
    .column_series()
    .map(s => Series::from_ints(s.name(), [s.null_count().to_int64()]))
  DataFrame::from_parts(cols, 1)
}

///|
/// Per-column statistical summary, returned as a `DataFrame` with one
/// row per source column. The result schema is fixed and dtype-pure —
/// every cell has the dtype declared below, regardless of the source
/// frame's shape or column dtypes:
///
/// - `column` (`String`): source column name, in declaration order
/// - `dtype` (`String`): source column dtype rendered via `DataType::to_string`
/// - `count` (`Int`): non-null cell count
/// - `null_count` (`Int`): null cell count
/// - `n_unique` (`Int`): distinct non-null value count
/// - `mean` (`Float`, nullable): arithmetic mean for numeric columns;
///   `Null` for non-numeric or empty / all-null numeric columns
/// - `min` (`String`, nullable): minimum cell rendered via
///   `Scalar::to_string`; `Null` for empty / all-null columns
/// - `max` (`String`, nullable): maximum cell rendered via
///   `Scalar::to_string`; `Null` for empty / all-null columns
///
/// `min` / `max` are rendered as `String` so the summary can carry
/// extrema for every dtype in a single column without forcing a
/// uniform value type. A `Float` extremum renders via `Double::to_string`,
/// which drops the decimal point of a whole value (`1.0` → `"1"`), so a
/// `Float` column's extrema can read like an `Int`'s — the `dtype` column
/// disambiguates. The per-column reductions (`min`, `max`) keep the
/// original dtype if a caller needs it typed.
///
/// This is a deliberately reduced summary: it omits the standard deviation,
/// variance, and quantiles (`25%` / `50%` / `75%`) that Polars' `describe`
/// reports. The per-column kernels expose those directly (`Series` std /
/// variance / median) for callers who need them.
///
/// Because `min` / `max` skip `NaN` (Polars' regular extrema) while `count`
/// and `n_unique` treat `NaN` as a present value, an all-`NaN` `Float` column
/// reports a non-zero `count` and an `n_unique` of `1` (every `NaN` folds into
/// one distinct bucket) but `Null` `min` / `max` — these can legitimately
/// disagree, in addition to the empty / all-null case noted above.
///
/// Raises only because the summary frame is built through the fallible
/// `DataFrame::DataFrame`; the output columns are hardcoded-unique and equal
/// length, so the raise is forwarded, never actually taken. The 0-column
/// case collapses to a `0×8` frame: zero source columns ⇒ zero output
/// rows, but the eight schema columns are still present so downstream
/// code can rely on the result's column layout.
pub fn DataFrame::describe(
  self : DataFrame,
) -> DataFrame raise @types.DataError {
  let names : Array[String] = []
  let dtypes : Array[String] = []
  let counts : Array[Int64] = []
  let null_counts : Array[Int64] = []
  let n_uniques : Array[Int64] = []
  let means : Array[Double?] = []
  let mins : Array[String?] = []
  let maxs : Array[String?] = []
  for s in self.column_series() {
    names.push(s.name())
    dtypes.push(s.dtype().to_string())
    counts.push(s.count().to_int64())
    null_counts.push(s.null_count().to_int64())
    n_uniques.push(s.n_unique().to_int64())
    // `mean_opt` is the total form of `Series::mean` — `None` exactly where
    // `mean` would raise (a non-numeric column, or an empty / all-null
    // numeric one), `Some(mean)` otherwise. The aggregate view wants that
    // single null cell either way (the per-column API keeps the
    // distinction), so it reads the total accessor and skips the error
    // catch, like the `min` / `max` reads just below.
    means.push(s.mean_opt())
    // `min` / `max` are total; they return `Scalar::Null` to signal "no
    // value" — a null cell here — and otherwise render via
    // `Scalar::to_string`.
    let lo = s.min()
    mins.push(if lo.is_null() { None } else { Some(lo.to_string()) })
    let hi = s.max()
    maxs.push(if hi.is_null() { None } else { Some(hi.to_string()) })
  }
  // The output columns share a length (`self.ncols()`) and the names are
  // hardcoded-unique, so `DataFrame::DataFrame` always succeeds; the raise is
  // forwarded rather than caught.
  DataFrame::DataFrame([
    Series::from_strings("column", names),
    Series::from_strings("dtype", dtypes),
    Series::from_ints("count", counts),
    Series::from_ints("null_count", null_counts),
    Series::from_ints("n_unique", n_uniques),
    Series::from_float_options("mean", means),
    Series::from_string_options("min", mins),
    Series::from_string_options("max", maxs),
  ])
}
