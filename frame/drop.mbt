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
  // Validate every requested drop name actually exists before building
  // the survivor list — `get_column` raises on the first unknown name.
  let to_drop : Map[String, Unit] = {}
  for n in names {
    let _ = self.get_column(n)
    to_drop[n] = ()
  }
  let survivors = self.column_series().filter(s => !to_drop.contains(s.name()))
  DataFrame::new(survivors)
}
