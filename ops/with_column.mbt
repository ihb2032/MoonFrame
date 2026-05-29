///|
/// Append `series` as a new rightmost column. The column name is taken
/// from `series.name()`.
///
/// Errors:
/// - `Err(DuplicateColumn(name))` — `series.name()` already exists in
///   `df`.
/// - `Err(LengthMismatch)` — `series.len() != df.nrows()`. Note that
///   for a 0-column frame, `df.nrows()` is `0`, so `with_column` will
///   only accept an empty series. Callers that want to "bootstrap a
///   frame from a non-empty series" should use `DataFrame::new`
///   directly.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new`.
pub fn with_column(
  df : @frame.DataFrame,
  series : @frame.Series,
) -> Result[@frame.DataFrame, @types.DataError] {
  // Duplicate-name check before length so the diagnostic matches what
  // the caller most likely cares about first (collisions tend to be
  // build-once mistakes, length to be data-shape mistakes).
  let name = series.name()
  if df.get_column(name) is Ok(_) {
    return Err(@types.DataError::DuplicateColumn(name))
  }
  if series.len() != df.nrows() {
    return Err(@types.DataError::LengthMismatch)
  }
  // `column_series` returns a fresh, owned array, so appending the new
  // column can't perturb `df`.
  let new_cols = df.column_series()
  new_cols.push(series)
  @frame.DataFrame::new(new_cols)
}
