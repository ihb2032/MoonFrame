// Whole-frame statistical reductions on a `DataFrame`. Each of `sum`,
// `mean`, `min`, `max`, and `count` collapses the frame to a **single row**
// — one cell per source column, names and order preserved — mirroring
// Polars' `df.sum()` / `df.mean()` / `df.min()` / `df.max()` / `df.count()`,
// which return a 1-row frame rather than a scalar.
//
// Cell semantics, uniform across `sum` / `mean` / `min` / `max`:
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
// A 0-column frame collapses to `0×0` (there is no column to anchor the
// single row), matching `null_count`.
//
// The v0.4 per-column scalar reductions (`df.sum("col")` → `Scalar`) are
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
/// (source dtype preserved), non-numeric columns a `Null` cell. See the file
/// header for the full semantics. For one column's scalar use
/// `df.get_column(name).sum()`.
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
/// Raises only through the 1-row `DataFrame::new`, whose failure paths
/// (duplicate name / length mismatch) cannot fire here — the output column
/// names are exactly `self`'s (already unique) and every output column has
/// length 1 — so the raise is forwarded, never actually taken. (A 0-column
/// frame produces zero output columns, i.e. a `0×0` result.)
fn DataFrame::reduce_to_row(
  self : DataFrame,
  op : FrameReduceOp,
) -> DataFrame raise @types.DataError {
  let cols : Array[Series] = []
  for s in self.column_series() {
    cols.push(reduce_column(s, op))
  }
  DataFrame::new(cols)
}

///|
/// Reduce one source column under `op` to a length-1 output column. Returns
/// the `(cell, probe)` of the reduction — `cell` is the reduced `Scalar` (or
/// `Scalar::Null`), `probe` fixes the output dtype — projected onto a typed
/// column by the shared `scalars_to_series`.
///
/// Numeric-only for `sum` / `mean` / `min` / `max`: a `Bool` / `String`
/// column yields a `Null` cell kept in its source dtype (`probe = data`),
/// while a numeric column reduces (`mean` retyped to `Float`). `count` is
/// dtype-independent — always the non-null count as `Int`. This is distinct
/// from the expression engine's `eval_agg` (which reduces every dtype and
/// raises on a non-numeric `sum` / `mean`): the whole-frame reductions
/// tolerate non-reducible columns by nulling them, matching `df.sum()`.
fn reduce_column(
  s : Series,
  op : FrameReduceOp,
) -> Series raise @types.DataError {
  let name = s.name()
  // `data` doubles as the numeric test (its variant) and, for the
  // dtype-preserving reductions, the output `probe`; `ColumnData` has no
  // `Null` variant, so there is no dead arm to thread through. The accessor
  // wraps the backing array without copying it.
  let data = s.storage().data()
  let numeric = match data {
    @column.ColumnData::Int(_) | @column.ColumnData::Float(_) => true
    _ => false
  }
  let (cell, probe) = match op {
    FrameReduceOp::Count =>
      (@types.Scalar::Int(s.count().to_int64()), @column.ColumnData::Int([]))
    // `Series::sum` only raises for a non-numeric dtype, which the `numeric`
    // guard excludes — so the call never actually raises here.
    FrameReduceOp::Sum =>
      (if numeric { s.sum() } else { @types.Scalar::Null }, data)
    FrameReduceOp::Min =>
      (if numeric { s.min() } else { @types.Scalar::Null }, data)
    FrameReduceOp::Max =>
      (if numeric { s.max() } else { @types.Scalar::Null }, data)
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
      (cell, if numeric { @column.ColumnData::Float([]) } else { data })
    }
  }
  scalars_to_series(probe, name, [cell])
}
