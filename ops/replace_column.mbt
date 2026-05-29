///|
/// Replace the column named `name` with `series`, in place
/// (positionally). The target `name` is preserved on the new column
/// — `series.name()` is ignored for naming purposes, so the schema
/// surface stays stable when a caller wants only to swap data /
/// dtype. Cross-dtype replacement is allowed (e.g., swap an `Int`
/// column for a `Float` one).
///
/// Errors:
/// - `Err(ColumnNotFound(name))` — `name` doesn't exist in `df`.
/// - `Err(LengthMismatch)` — `series.len() != df.nrows()`.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new`, which rebuilds schema (with the new dtype at the
/// target slot) and the `name_to_index` cache.
pub fn replace_column(
  df : @frame.DataFrame,
  name : String,
  series : @frame.Series,
) -> Result[@frame.DataFrame, @types.DataError] {
  // Find the target slot up front so the length check below has a
  // valid index to report against.
  let idx = match df.schema().index_of(name) {
    Ok(i) => i
    Err(e) => return Err(e)
  }
  if series.len() != df.nrows() {
    return Err(@types.DataError::LengthMismatch)
  }
  // Force the new column to take the target name so the schema's
  // name slot stays put even if the caller passed a series named
  // differently.
  let renamed = series.rename(name)
  let cols = df.column_series()
  let new_cols = Array::makei(df.ncols(), i => {
    if i == idx {
      renamed
    } else {
      cols[i]
    }
  })
  @frame.DataFrame::new(new_cols)
}
