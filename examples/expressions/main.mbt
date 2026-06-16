// MoonFrame example: the v0.4 expression + lazy-query layer end to end.
//
//   read_csv → with_columns (derive profit, unit_price)
//            → filter_where (Expr predicate: profit > 0 & region == west)
//            → group_by(region).agg (composite aggregation)
//            → with_columns (when / then / otherwise tier)
//            → lazy_frame(...).explain() + .collect()
//
// All the logic lives in the sibling `analysis/` package so it is covered
// by `analysis_test.mbt`. `main` is a thin orchestrator around `read_csv`
// / `println` and is therefore marked `#coverage.skip` — every meaningful
// branch is in the helpers.
//
// Run from the project root:
//     moon run examples/expressions

///|
#coverage.skip
fn main {
  let path = "examples/expressions/sales.csv"
  // The whole pipeline raises `DataError`; a single `try`/`catch` at the
  // top of `main` keeps the happy path a flat method chain and prints a
  // diagnostic on any failure (read error, bad column, …).
  try {
    let df = @moonframe.read_csv(path)
    // 1) Derived columns via `with_columns` + the `Expr` operators.
    println(
      "Enriched (profit = revenue - cost, unit_price = revenue / quantity):",
    )
    println(@analysis.enrich(df).to_markdown())
    // 2) An `Expr` predicate drives `filter_where`.
    println("\nProfitable western rows:")
    println(@analysis.top_west(df).to_markdown())
    // 3) Composite aggregation with `agg`.
    println("\nMargins by region:")
    println(@analysis.margins(df).to_markdown())
    // 4) A `when / then / otherwise` conditional column.
    println("\nGraded by revenue tier:")
    println(@analysis.graded(df).to_markdown())
    // 5) A deferred `LazyFrame`: inspect the plan, then collect it. The
    //    optimized form shows the filter sunk below the projection and the
    //    scan narrowed to the columns the query reads.
    let plan = @analysis.report_plan(df)
    println("\nLazy plan (as built):")
    println(plan.explain())
    println("\nLazy plan (optimized):")
    println(plan.explain(optimized=true))
    println("\nCollected:")
    println(plan.collect().to_markdown())
  } catch {
    e => println("expressions example failed: \{e.message()}")
  }
}
