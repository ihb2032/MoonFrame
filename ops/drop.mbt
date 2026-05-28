///|
/// Return a copy of `df` with every column whose name appears in
/// `names` removed. Remaining columns keep their relative order.
///
/// Duplicate entries in `names` are tolerated and act idempotently —
/// dropping `["a", "a"]` is the same as dropping `["a"]`. This matches
/// pandas / polars behavior and avoids forcing callers to deduplicate
/// upstream when assembling a drop list from multiple sources.
///
/// Errors:
/// - `Err(ColumnNotFound(name))` — `name` does not exist. Reported on
///   the first offending entry in `names`.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new` (called with the surviving column subset).
pub fn drop(
  df : @frame.DataFrame,
  names : Array[String],
) -> Result[@frame.DataFrame, @types.DataError] {
  // Validate every requested drop names actually exists before
  // building the survivor list — saves a half-built result on error.
  let to_drop : Map[String, Unit] = {}
  for n in names {
    match df.get_column(n) {
      Ok(_) => to_drop[n] = ()
      Err(e) => return Err(e)
    }
  }
  // `get_column` cannot fail: name came from `df.columns()`.
  let survivors = df
    .columns()
    .filter(name => !to_drop.contains(name))
    .map(name => df.get_column(name).unwrap())
  @frame.DataFrame::new(survivors)
}
