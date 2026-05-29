///|
/// Per-column null-count summary, returned as a `1 × ncols` DataFrame.
/// Column names match `df.columns()` verbatim, in the same order, and
/// every output column has dtype `Int` with a single non-null cell —
/// the null count of the source column.
///
/// The 0-column case collapses to a 0×0 frame: `DataFrame::new`'s
/// "empty column list ⇒ nrows = 0" rule kicks in, and producing a
/// "1×0" frame would otherwise require fabricating a row count without
/// any column to anchor it. Callers that need a guaranteed-nonempty
/// summary should attach a sentinel column before calling.
///
/// Returns `Result` because the summary is built through the fallible
/// `DataFrame::new`; its failure paths (duplicate-name, length-mismatch)
/// cannot fire here — the names come from `df.column_series()` (already
/// unique) and every output column has length 1 (or 0 in the 0-column
/// case) — so the value is always `Ok`, forwarded rather than `unwrap`ped.
pub fn null_count(
  df : @frame.DataFrame,
) -> Result[@frame.DataFrame, @types.DataError] {
  let cols = df
    .column_series()
    .map(s => @frame.Series::from_ints(s.name(), [s.null_count().to_int64()]))
  @frame.DataFrame::new(cols)
}
