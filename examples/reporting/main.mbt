// MoonFrame example: a small reporting pipeline that turns a sales CSV
// into the v0.3 output formats.
//
//   read_csv → group_by(region) + agg(sum revenue, sum quantity)
//            → sort(revenue desc)
//            → to_html            (a styled <table> for a web page / notebook)
//            → format_vega_lite   (a Vega-Lite v5 bar-chart spec)
//
// Reporting logic lives in the sibling `report/` package so it is
// covered by `report_test.mbt`. `main` is a thin orchestrator around
// `read_csv` / `write_vega_lite` / `println` and is therefore marked
// `#coverage.skip` — every meaningful branch is in the helper.
//
// Run from the project root:
//     moon run examples/reporting

///|
#coverage.skip
fn main {
  let path = "examples/reporting/sales.csv"
  let chart_out = "_build/revenue_by_region.vl.json"
  // The whole pipeline raises `DataError`; a single `try`/`catch` at the
  // top of `main` keeps the happy path a flat method chain and prints a
  // diagnostic on any failure (read error, bad column, …).
  try {
    let df = @moonframe.read_csv(path)
    let summary = @report.revenue_by_region(df)
    println("Revenue by region:")
    println(summary.to_markdown())
    // 1) HTML table — paste into a page / notebook for a rendered view.
    println("\nHTML table:")
    println(@report.revenue_table(summary))
    // 2) Vega-Lite v5 spec — paste into https://vega.github.io/editor/.
    println("\nVega-Lite spec:")
    println(@report.revenue_chart(summary))
    // …and persist the same spec to `_build/` via the file-backed
    // wrapper (the directory always exists during `moon` runs).
    @moonframe.write_vega_lite(
      chart_out,
      summary,
      @moonframe.ChartSpec::bar("region", "revenue").with_title(
        "Revenue by region",
      ),
    )
    println("\nWrote Vega-Lite spec to \{chart_out}")
  } catch {
    e => println("reporting failed: \{e.message()}")
  }
}
