///|
/// Project the frame down to the columns named in `names`, in the
/// order they appear in `names`. The result is a new `DataFrame`
/// whose row count is unchanged.
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` does not exist in `self`.
/// - `DuplicateColumn(name)` — `names` contains the same name twice
///   (which would otherwise produce a frame with a duplicate column).
///
/// Errors are reported in the order names are processed, so a missing
/// name encountered before a duplicate surfaces as `ColumnNotFound`
/// first.
///
/// All structural invariants on the returned frame are guaranteed by
/// routing the new column list through `DataFrame::new`, which
/// rebuilds the `schema` and `name_to_index` cache in lock-step.
pub fn DataFrame::select(
  self : DataFrame,
  names : Array[String],
) -> DataFrame raise @types.DataError {
  let picked : Array[Series] = []
  let seen : Map[String, Unit] = {}
  for n in names {
    if seen.contains(n) {
      raise @types.DataError::DuplicateColumn(n)
    }
    seen[n] = ()
    // `get_column` raises `ColumnNotFound(n)` for an unknown name.
    picked.push(self.get_column(n))
  }
  DataFrame::new(picked)
}
