// MoonFrame example: a small reporting pipeline that turns a sales CSV
// into its output formats.
//
//   read_csv → group_by(region) + agg(sum revenue, sum quantity)
//            → sort(revenue desc)
//            → to_html                      (a styled <table> for a web page)
//            → plot().bar().to_json()       (a Vega-Lite v6 bar-chart spec)
//            → plot().bar().write_html()    (a self-contained chart page)
//
// Reporting logic lives in the sibling `report/` package so it is
// covered by that package's blackbox tests. `main` is a thin orchestrator around
// `read_csv` / the chart's `write_json` / `write_html` / `println` and is
// therefore marked
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
    // 2) Vega-Lite v6 spec — paste into https://vega.github.io/editor/.
    println("\nVega-Lite spec:")
    println(@report.revenue_chart(summary))
    // …and persist the same spec to `_build/` via the chain's writer
    // (the directory always exists during `moon` runs).
    let chart = @moonframe.plot(summary).bar(
      x="region",
      y="revenue",
      title="Revenue by region",
    )
    chart.write_json(chart_out)
    println("\nWrote Vega-Lite spec to \{chart_out}")
    // 3) The same chart as a self-contained HTML page — open it in a
    // browser for the interactive view, with vega-embed's action links
    // (SVG / PNG export, the spec source, the online editor).
    let page_out = "_build/revenue_by_region.html"
    chart.write_html(page_out)
    println("\nWrote chart page to \{page_out}")
  } catch {
    e => println("reporting failed: \{e.message()}")
  }
}
