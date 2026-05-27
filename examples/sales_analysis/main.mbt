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
  let df = match @moonframe.read_csv(path) {
    Ok(d) => d
    Err(e) => {
      println("failed to read \{path}: \{e.message()}")
      return
    }
  }
  match @pipeline.widget_report(df) {
    Ok((sorted, summary)) => {
      println("Loaded \{df.nrows()} rows, \{df.ncols()} columns from \{path}")
      println("\nWidget rows, sorted by quantity (desc):")
      println(@moonframe.to_markdown(sorted))
      println("\nPer-column summary:")
      println(@moonframe.to_markdown(summary))
    }
    Err(e) => println("pipeline failed: \{e.message()}")
  }
}
