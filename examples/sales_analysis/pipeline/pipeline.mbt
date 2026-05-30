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
/// The fallible steps — `filter_try`, `select`, `sort_by`, and the now
/// `Result`-returning `describe` — are chained with `Result::bind` /
/// `Result::map` so error propagation is structural: there's no explicit
/// `Err(e) => return Err(e)` arm that the type system would let us write
/// but that coverage could never reach (`describe` here only builds a
/// fixed-schema summary, so its `Err` is unreachable, and `bind` keeps
/// that branch inside the stdlib rather than in our code).
pub fn widget_report(
  df : @moonframe.DataFrame,
) -> Result[(@moonframe.DataFrame, @moonframe.DataFrame), @moonframe.DataError] {
  @moonframe.filter_try(df, is_widget_row)
  .bind(widgets => {
    @moonframe.select(widgets, ["region", "price", "quantity", "revenue"])
  })
  .bind(projected => {
    @moonframe.sort_by(projected, @moonframe.SortSpec::desc("quantity"))
  })
  .bind(sorted => @moonframe.describe(sorted).map(summary => (sorted, summary)))
}

///|
/// Row predicate for `filter_try`. Surfaces the `RowView` accessor
/// error verbatim so a misspelled column or a dtype mismatch becomes
/// a `DataError`, not a silent "row excluded".
pub fn is_widget_row(
  row : @moonframe.RowView,
) -> Result[Bool, @moonframe.DataError] {
  row.get_string("product").map(name => name == "widget")
}
