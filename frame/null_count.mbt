///|
/// Per-column null-count summary, returned as a `1 × ncols` DataFrame.
/// Column names match `self.columns()` verbatim, in the same order, and
/// every output column has dtype `Int` with a single non-null cell —
/// the null count of the source column.
///
/// The summary is one row wide of whatever the source has, so a 0-column
/// frame summarises to `1×0` — the row is there, it just has nothing in it.
/// The height is passed explicitly for that reason: with no column to anchor
/// it, an inferred one would round the row away.
///
/// Raises only because the summary is built through the fallible
/// `DataFrame::from_parts`; its failure paths (duplicate-name, length-mismatch)
/// cannot fire here — the names come from `self.column_series()` (already
/// unique) and every output column has length 1 — so the raise is forwarded,
/// never actually taken.
pub fn DataFrame::null_count(
  self : DataFrame,
) -> DataFrame raise @types.DataError {
  let cols = self
    .column_series()
    .map(s => Series::from_ints(s.name(), [s.null_count().to_int64()]))
  DataFrame::from_parts(cols, 1)
}
