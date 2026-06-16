// Column-level statistical reductions on a `DataFrame`. Each method
// resolves a column name through `get_column` (which raises
// `ColumnNotFound` for an unknown name) and then delegates to the
// matching `Series` reduction in `series_stats.mbt`, so the per-dtype
// semantics (null skipping, empty-series fallbacks, `Float` NaN handling,
// `Bool` / `String` rejection for numeric ops) match the Series API
// exactly.

///|
/// Non-null cell count for `column`. `Series::count` is total, so the
/// only failure path is a missing column.
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
pub fn DataFrame::count(
  self : DataFrame,
  column : String,
) -> Int raise @types.DataError {
  self.get_column(column).count()
}

///|
/// Sum of non-null cells in `column`. See `Series::sum` for the
/// per-dtype rules: `Int` and `Float` columns return the additive
/// identity for empty / all-null inputs; `Bool` / `String` columns
/// raise `TypeMismatch`.
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
/// - `TypeMismatch(...)` — `column` is non-numeric.
pub fn DataFrame::sum(
  self : DataFrame,
  column : String,
) -> @types.Scalar raise @types.DataError {
  self.get_column(column).sum()
}

///|
/// Arithmetic mean of `column`, returned as `Double` (`Int` sums are
/// promoted). Empty or all-null numeric columns raise
/// `InvalidOperation`; non-numeric columns raise `TypeMismatch`.
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
/// - `InvalidOperation(...)` — numeric column is empty or all-null.
/// - `TypeMismatch(...)` — `column` is non-numeric.
pub fn DataFrame::mean(
  self : DataFrame,
  column : String,
) -> Double raise @types.DataError {
  self.get_column(column).mean()
}

///|
/// Minimum non-null cell in `column`, by the natural order of the
/// column's dtype. Empty or all-null columns return `Scalar::Null`.
/// `Float` NaN is treated as missing (skipped), matching `sort` and
/// pandas — see `Series::min_value` for the details. Total beyond the
/// column lookup, so the only failure path is a missing column.
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
pub fn DataFrame::min(
  self : DataFrame,
  column : String,
) -> @types.Scalar raise @types.DataError {
  self.get_column(column).min_value()
}

///|
/// Maximum non-null cell in `column`. Mirrors `min` with `>` in place
/// of `<`; empty / all-null inputs and `Float` NaN behave identically.
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
pub fn DataFrame::max(
  self : DataFrame,
  column : String,
) -> @types.Scalar raise @types.DataError {
  self.get_column(column).max_value()
}
