///|
/// Per-column null-count summary, returned as a `1 × ncols` DataFrame.
/// Column names match `self.columns()` verbatim, in the same order, and
/// every output column has dtype `Int` with a single non-null cell —
/// the null count of the source column.
///
/// The 0-column case collapses to a 0×0 frame: `DataFrame::new`'s
/// "empty column list ⇒ nrows = 0" rule kicks in, and producing a
/// "1×0" frame would otherwise require fabricating a row count without
/// any column to anchor it. Callers that need a guaranteed-nonempty
/// summary should attach a sentinel column before calling.
///
/// Raises only because the summary is built through the fallible
/// `DataFrame::new`; its failure paths (duplicate-name, length-mismatch)
/// cannot fire here — the names come from `self.column_series()` (already
/// unique) and every output column has length 1 (or 0 in the 0-column
/// case) — so the raise is forwarded, never actually taken.
pub fn DataFrame::null_count(
  self : DataFrame,
) -> DataFrame raise @types.DataError {
  let cols = self
    .column_series()
    .map(s => Series::from_ints(s.name(), [s.null_count().to_int64()]))
  DataFrame::new(cols)
}
