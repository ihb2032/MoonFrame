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
/// `sort`, and the always-`Ok`-in-practice `describe`) chain
/// directly. No `.bind` / `.map` plumbing and no explicit
/// `Err(e) => return Err(e)` arm for coverage to skip.
pub fn widget_report(
  df : @moonframe.DataFrame,
) -> (@moonframe.DataFrame, @moonframe.DataFrame) raise @moonframe.DataError {
  let sorted = df
    .filter(is_widget_row())
    .select(@moonframe.cols(["region", "price", "quantity", "revenue"]))
    .sort([
      (
        @moonframe.col("quantity"),
        @moonframe.SortOrder::Desc,
        @moonframe.NullOrder::NullsLast,
      ),
    ])
  (sorted, sorted.describe())
}

///|
/// Row predicate for `filter`, reified with the `map_many` escape hatch:
/// the closure receives each row's `product` cell as a `Scalar` and keeps
/// the rows whose value is `"widget"`. A missing `product` column makes the
/// predicate raise `ColumnNotFound` at evaluation, and a non-string cell
/// raises `TypeMismatch` via `Scalar::as_string` — the same errors the old
/// closure predicate surfaced, now carried by an inspectable `Expr`.
pub fn is_widget_row() -> @moonframe.Expr {
  @moonframe.map_many(label="is_widget", [@moonframe.col("product")], cells => {
    @moonframe.Scalar::Bool(cells[0].as_string() == "widget")
  })
}
