///|
/// Replace the column named `name` with `series`, in place
/// (positionally). The target `name` is preserved on the new column
/// — `series.name()` is ignored for naming purposes, so the schema
/// surface stays stable when a caller wants only to swap data /
/// dtype. Cross-dtype replacement is allowed (e.g., swap an `Int`
/// column for a `Float` one).
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` doesn't exist in `self`.
/// - `LengthMismatch` — `series.len() != self.nrows()`.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new`, which rebuilds schema (with the new dtype at the
/// target slot) and the `name_to_index` cache.
pub fn DataFrame::replace_column(
  self : DataFrame,
  name : String,
  series : Series,
) -> DataFrame raise @types.DataError {
  // Find the target slot up front so the length check below has a
  // valid index to report against. `index_of` raises `ColumnNotFound`.
  let idx = self.schema().index_of(name)
  if series.len() != self.nrows() {
    raise @types.DataError::LengthMismatch
  }
  // Force the new column to take the target name so the schema's
  // name slot stays put even if the caller passed a series named
  // differently.
  let renamed = series.rename(name)
  let cols = self.column_series()
  let new_cols = Array::makei(self.ncols(), i => {
    if i == idx {
      renamed
    } else {
      cols[i]
    }
  })
  DataFrame::new(new_cols)
}
