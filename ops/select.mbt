///|
/// Project the frame down to the columns named in `names`, in the
/// order they appear in `names`. The result is a new `DataFrame`
/// whose row count is unchanged.
///
/// Errors:
/// - `Err(ColumnNotFound(name))` — `name` does not exist in `self`.
/// - `Err(DuplicateColumn(name))` — `names` contains the same name
///   twice (which would otherwise produce a frame with a duplicate
///   column).
///
/// Errors are reported in the order names are processed, so a missing
/// name encountered before a duplicate surfaces as `ColumnNotFound`
/// first.
///
/// All structural invariants on the returned frame are guaranteed by
/// routing the new column list through `DataFrame::new`, which
/// rebuilds the `schema` and `name_to_index` cache in lock-step.
pub fn select(
  df : @frame.DataFrame,
  names : Array[String],
) -> Result[@frame.DataFrame, @types.DataError] {
  let picked : Array[@frame.Series] = []
  let seen : Map[String, Unit] = {}
  for n in names {
    if seen.contains(n) {
      return Err(@types.DataError::DuplicateColumn(n))
    }
    seen[n] = ()
    match df.get_column(n) {
      Ok(s) => picked.push(s)
      Err(e) => return Err(e)
    }
  }
  @frame.DataFrame::new(picked)
}
