// Pure pipeline logic for the sales-analysis example. Living in its
// own library package keeps `main` thin (so it can be marked
// `#coverage.skip` without losing real coverage) and lets the
// blackbox tests next to this file exercise every branch through
// the facade — exactly the way a downstream user would call them.

///|
/// Run the sales pipeline against `df`. Returns the sorted widget
/// frame paired with its per-column `describe` summary. Surfacing
/// both lets `main` print them and the test assert on them without
/// the helper having to know about either side.
///
/// v0.2 method-chain form: every step is a `DataFrame` method that
/// raises on failure, so the four fallible steps (`filter`, `select`,
/// `sort_by`, and the always-`Ok`-in-practice `describe`) chain
/// directly. No `.bind` / `.map` plumbing and no explicit
/// `Err(e) => return Err(e)` arm for coverage to skip.
pub fn widget_report(
  df : @moonframe.DataFrame,
) -> (@moonframe.DataFrame, @moonframe.DataFrame) raise @moonframe.DataError {
  let sorted = df
    .filter(is_widget_row)
    .select(["region", "price", "quantity", "revenue"])
    .sort_by([
      ("quantity", @moonframe.SortOrder::Desc, @moonframe.NullOrder::NullsLast),
    ])
  (sorted, sorted.describe())
}

///|
/// Row predicate for `filter`. The fallible `RowView::get_string`
/// raises straight through, so a misspelled column or a dtype mismatch
/// becomes a `DataError`, not a silent "row excluded".
pub fn is_widget_row(
  row : @moonframe.RowView,
) -> Bool raise @moonframe.DataError {
  row.get_string("product") == "widget"
}
