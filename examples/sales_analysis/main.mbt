// MoonFrame example: end-to-end sales pipeline.
//
//   read_csv → filter (widget rows only) → select (4 columns)
//            → sort_by (quantity desc)
//            → describe (per-column summary)
//            → to_markdown (printable report)
//
// Pipeline logic lives in the sibling `pipeline/` package so it is
// covered by `pipeline_test.mbt`. `main` is a thin orchestrator
// around `read_csv` + `println` and is therefore marked
// `#coverage.skip` — every meaningful branch is in the helper.
//
// Run from the project root:
//     moon run examples/sales_analysis

///|
#coverage.skip
fn main {
  let path = "examples/sales_analysis/sales.csv"
  // The whole pipeline raises `DataError`; a single `try`/`catch` at the
  // top of `main` keeps the happy path a flat method chain and prints a
  // diagnostic on any failure (read error, bad column, …).
  try {
    let df = @moonframe.read_csv(path)
    let (sorted, summary) = @pipeline.widget_report(df)
    println("Loaded \{df.nrows()} rows, \{df.ncols()} columns from \{path}")
    println("\nWidget rows, sorted by quantity (desc):")
    println(sorted.to_markdown())
    println("\nPer-column summary:")
    println(summary.to_markdown())
  } catch {
    e => println("pipeline failed: \{e.message()}")
  }
}
