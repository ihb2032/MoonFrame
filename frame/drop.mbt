///|
/// Return a copy of `self` with every column whose name appears in
/// `names` removed. Remaining columns keep their relative order.
///
/// Duplicate entries in `names` are tolerated and act idempotently —
/// dropping `["a", "a"]` is the same as dropping `["a"]`. This matches
/// pandas / polars behavior and avoids forcing callers to deduplicate
/// upstream when assembling a drop list from multiple sources.
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` does not exist. Reported on the
///   first offending entry in `names`.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new` (called with the surviving column subset).
pub fn DataFrame::drop(
  self : DataFrame,
  names : Array[String],
) -> DataFrame raise @types.DataError {
  // Validate-and-collect in one pass: mapping each name through
  // `get_column` raises `ColumnNotFound` on the first unknown name — so a
  // bad name surfaces before any survivor list is built — and
  // `Map::from_array` folds the names into a drop set where duplicate
  // entries collapse (matching the idempotent-drop contract).
  let to_drop : Map[String, Unit] = Map::from_array(
    names.map(n => {
      let _ = self.get_column(n)
      (n, ())
    }),
  )
  let survivors = self.column_series().filter(s => !to_drop.contains(s.name()))
  DataFrame::new(survivors)
}
