// Pure reporting logic for the reporting example. Living in its own
// library package keeps `main` thin (so it can be marked
// `#coverage.skip` without losing real coverage) and lets the blackbox
// tests next to this file exercise every branch through the facade —
// exactly the way a downstream user would call them.

///|
/// Summarise `df` into revenue and quantity per region: group by
/// `region`, sum both measures, and order the regions by revenue
/// (highest first). Returns the summary frame so callers can render it
/// — `main` prints / persists it; the tests assert on it directly.
///
/// Every step is a `DataFrame` method that raises on failure, so a
/// missing `region` / `revenue` / `quantity` column bubbles up as a
/// `DataError` rather than producing a silently-wrong summary.
pub fn revenue_by_region(
  df : @moonframe.DataFrame,
) -> @moonframe.DataFrame raise @moonframe.DataError {
  df
  .group_by([@moonframe.col("region")])
  .agg([
    @moonframe.col("revenue").sum().with_alias("revenue"),
    @moonframe.col("quantity").sum().with_alias("quantity"),
  ])
  .sort([
    (
      @moonframe.col("revenue"),
      @moonframe.SortOrder::Desc,
      @moonframe.NullOrder::NullsLast,
    ),
  ])
}

///|
/// Render `summary` as a styled HTML table (CSS `class` + `<caption>`)
/// ready to drop into a web page or notebook. Total: HTML rendering is
/// a pure `DataFrame` method that cannot fail.
pub fn revenue_table(summary : @moonframe.DataFrame) -> String {
  summary.to_html(
    options=@moonframe.HtmlOptions(
      table_class="dataframe",
      caption="Revenue by region",
    ),
  )
}

///|
/// Emit a Vega-Lite v5 bar-chart spec for `summary` — region on the x
/// axis, revenue on the y axis — as a JSON string that pastes straight
/// into the Vega editor. Raises `ColumnNotFound` if `summary` lacks a
/// charted column.
pub fn revenue_chart(
  summary : @moonframe.DataFrame,
) -> String raise @moonframe.DataError {
  @moonframe.format_vega_lite(
    summary,
    @moonframe.ChartSpec::bar("region", "revenue", title="Revenue by region"),
  )
}
