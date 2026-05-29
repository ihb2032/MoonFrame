// Column-level statistical reductions on a `DataFrame`. Every function
// here resolves a column name through `DataFrame::get_column` and then
// delegates to the matching `Series` reduction in `frame/series_stats.mbt`,
// so the per-dtype semantics (null skipping, empty-series fallbacks,
// `Float` NaN handling, `Bool` / `String` rejection for numeric ops)
// match the Series API exactly.

///|
/// Common lookup-then-delegate pattern shared by every reduction in this
/// file. The closure `f` is invoked only when the column resolves; a
/// missing column short-circuits with `Err(ColumnNotFound)` before any
/// per-cell work runs.
fn[T] dispatch_stat(
  df : @frame.DataFrame,
  column : String,
  f : (@frame.Series) -> Result[T, @types.DataError],
) -> Result[T, @types.DataError] {
  df.get_column(column).bind(f)
}

///|
/// Non-null cell count for `column`. `Series::count` is total, so the
/// only failure path is a missing column.
///
/// Errors:
/// - `Err(ColumnNotFound(column))` — `column` doesn't exist in `df`.
pub fn count(
  df : @frame.DataFrame,
  column : String,
) -> Result[Int, @types.DataError] {
  dispatch_stat(df, column, fn(s) { Ok(s.count()) })
}

///|
/// Sum of non-null cells in `column`. See `Series::sum` for the
/// per-dtype rules: `Int` and `Float` columns return the additive
/// identity for empty / all-null inputs; `Bool` / `String` columns
/// surface as `Err(TypeMismatch)`.
///
/// Errors:
/// - `Err(ColumnNotFound(column))` — `column` doesn't exist in `df`.
/// - `Err(TypeMismatch(...))` — `column` is non-numeric.
pub fn sum(
  df : @frame.DataFrame,
  column : String,
) -> Result[@types.Scalar, @types.DataError] {
  dispatch_stat(df, column, fn(s) { s.sum() })
}

///|
/// Arithmetic mean of `column`, returned as `Double` (`Int` sums are
/// promoted). Empty or all-null numeric columns surface as
/// `Err(InvalidOperation(...))`; non-numeric columns as
/// `Err(TypeMismatch(...))`.
///
/// Errors:
/// - `Err(ColumnNotFound(column))` — `column` doesn't exist in `df`.
/// - `Err(InvalidOperation(...))` — numeric column is empty or all-null.
/// - `Err(TypeMismatch(...))` — `column` is non-numeric.
pub fn mean(
  df : @frame.DataFrame,
  column : String,
) -> Result[Double, @types.DataError] {
  dispatch_stat(df, column, fn(s) { s.mean() })
}

///|
/// Minimum non-null cell in `column`, by the natural order of the
/// column's dtype. Empty or all-null columns return `Ok(Scalar::Null)`.
/// `Float` NaN is treated as missing (skipped), matching `sort_by` and
/// pandas — see `Series::min` for the details.
///
/// Errors:
/// - `Err(ColumnNotFound(column))` — `column` doesn't exist in `df`.
pub fn min(
  df : @frame.DataFrame,
  column : String,
) -> Result[@types.Scalar, @types.DataError] {
  dispatch_stat(df, column, fn(s) { s.min() })
}

///|
/// Maximum non-null cell in `column`. Mirrors `min` with `>` in place
/// of `<`; empty / all-null inputs and `Float` NaN behave identically.
///
/// Errors:
/// - `Err(ColumnNotFound(column))` — `column` doesn't exist in `df`.
pub fn max(
  df : @frame.DataFrame,
  column : String,
) -> Result[@types.Scalar, @types.DataError] {
  dispatch_stat(df, column, fn(s) { s.max() })
}
