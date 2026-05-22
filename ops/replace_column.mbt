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
  let names = df.columns()
  let mut idx = -1
  for i, n in names {
    if n == name {
      idx = i
      break
    }
  }
  if idx < 0 {
    return Err(@types.DataError::ColumnNotFound(name))
  }
  if series.len() != df.nrows() {
    return Err(@types.DataError::LengthMismatch)
  }
  // Force the new column to take the target name so the schema's
  // name slot stays put even if the caller passed a series named
  // differently.
  let renamed = series.rename(name)
  let new_cols : Array[@frame.Series] = []
  for i, _ in names {
    if i == idx {
      new_cols.push(renamed)
    } else {
      // `get_column_at` cannot fail in [0, ncols).
      new_cols.push(df.get_column_at(i).unwrap())
    }
  }
  @frame.DataFrame::new(new_cols)
}
