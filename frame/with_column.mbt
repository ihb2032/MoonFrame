///|
/// Append `series` as a new rightmost column. The column name is taken
/// from `series.name()`.
///
/// Raises:
/// - `DuplicateColumn(name)` — `series.name()` already exists in `self`.
/// - `LengthMismatch` — `series.len() != self.nrows()`. Note that for a
///   0-column frame, `self.nrows()` is `0`, so `with_column` will only
///   accept an empty series. Callers that want to "bootstrap a frame
///   from a non-empty series" should use `DataFrame::new` directly.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new`.
pub fn DataFrame::with_column(
  self : DataFrame,
  series : Series,
) -> DataFrame raise @types.DataError {
  // Duplicate-name check before length so the diagnostic matches what
  // the caller most likely cares about first (collisions tend to be
  // build-once mistakes, length to be data-shape mistakes). The `O(1)`
  // `name_to_index` lookup avoids `columns().contains`, which allocated a
  // fresh name array and scanned it linearly.
  let name = series.name()
  if self.name_to_index.contains(name) {
    raise @types.DataError::DuplicateColumn(name)
  }
  if series.len() != self.nrows() {
    raise @types.DataError::LengthMismatch
  }
  // `column_series` returns a fresh, owned array, so appending the new
  // column can't perturb `self`.
  let new_cols = self.column_series()
  new_cols.push(series)
  DataFrame::new(new_cols)
}
