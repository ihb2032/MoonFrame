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
/// `null_count` is total — every input that's a well-formed
/// `DataFrame` produces a well-formed result, and `DataFrame::new`'s
/// failure paths (duplicate-name, length-mismatch) cannot fire here
/// because the names come from `df.columns()` (already unique) and
/// every output column has length 1 (or 0 in the 0-column case).
pub fn null_count(df : @frame.DataFrame) -> @frame.DataFrame {
  let cols = df
    .columns()
    .map(name => {
      // `get_column` cannot fail: name came from `df.columns()`.
      let s = df.get_column(name).unwrap()
      @frame.Series::from_ints(name, [s.null_count()])
    })
  // Names are unique (inherited from `df.columns()`), every column
  // has the same length (1) — the constructor cannot fail. `unwrap`
  // here is a structural assertion, not a real error path.
  @frame.DataFrame::new(cols).unwrap()
}
