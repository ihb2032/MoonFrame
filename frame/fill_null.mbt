///|
/// Replace every null cell in the column named `column` with `value`.
/// The remaining columns, and the schema's column order, are kept
/// verbatim. The target column's dtype is **unchanged** — the fill
/// `value` must match the column's existing dtype; cross-dtype filling
/// is not supported in v0.1 (callers can build a new series and pipe it
/// through `replace_column` if they need that).
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
/// - `TypeMismatch(...)` — `value` is `Scalar::Null` (filling nulls with
///   null is meaningless), or `value.dtype()` differs from the target
///   column's dtype. Both diagnostics bubble unchanged from
///   `Series::fill_null` so the message text matches the Series API.
///   Column-lookup runs before the fill so a missing name is surfaced
///   ahead of a type-mismatch error.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new`, which rebuilds the schema and `name_to_index`
/// cache in lock-step with the column vector.
pub fn DataFrame::fill_null(
  self : DataFrame,
  column : String,
  value : @types.Scalar,
) -> DataFrame raise @types.DataError {
  // Look up the target column first so a missing-column error fires
  // before the (more expensive) `Series::fill_null` traversal runs.
  let target = self.get_column(column)
  let filled = target.fill_null(value)
  let new_cols = self
    .column_series()
    .map(s => if s.name() == column { filled } else { s })
  DataFrame::new(new_cols)
}
