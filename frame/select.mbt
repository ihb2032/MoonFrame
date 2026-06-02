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
  // Map each name to its column, in order. The running `seen` set makes a
  // repeated name raise `DuplicateColumn` at the repeat — before any later
  // name is examined — matching the documented "first error in name order"
  // contract; `get_column` raises `ColumnNotFound` for an unknown name.
  // `Array::map` is left-to-right and forwards the raise, so the first
  // offending name short-circuits the scan.
  let seen : Map[String, Unit] = {}
  let picked = names.map(n => {
    if seen.contains(n) {
      raise @types.DataError::DuplicateColumn(n)
    }
    seen[n] = ()
    self.get_column(n)
  })
  DataFrame::new(picked)
}
