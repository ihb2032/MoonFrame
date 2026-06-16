// Pure null-handling logic for the data-cleaning example. Living in
// its own library package keeps `main` thin (so it can be marked
// `#coverage.skip` without losing real coverage) and lets the
// blackbox tests next to this file exercise every branch through
// the facade.

///|
/// Clean `df` by dropping rows whose `score` is null, then filling
/// any remaining null `note` cells with the sentinel string "n/a".
/// Returns the cleaned frame so callers can chain further ops (the
/// `main` orchestrator round-trips it through `write_csv` /
/// `read_csv`; tests assert on it directly).
///
/// The two fallible steps chain as `DataFrame` methods that raise on
/// failure — no `.bind` plumbing, no `Err(e) => return Err(e)` arm for
/// coverage to skip.
pub fn clean(
  df : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  df
  .drop_nulls(subset=[@moonframe.col("score")])
  .fill_null("note", @moonframe.Scalar::String("n/a"))
}
