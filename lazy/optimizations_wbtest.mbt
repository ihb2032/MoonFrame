// Whitebox tests for the optimizer switch — the flags' observable effect
// on the rendered plan, read through `optimize_with` directly (the public
// `explain` carries no flag; only `collect` does).

///|
fn all_off() -> Optimizations {
  {
    slice_pushdown: false,
    predicate_pushdown: false,
    projection_pushdown: false,
    cluster_with_columns: false,
    simplify_expressions: false,
  }
}

///|
fn flag_chain() -> LogicalPlan raise @types.DataError {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("v", [1, 2, 3, 4]),
  ])
  // No filter between the with_columns and the head — the slice pass
  // sinks a head across layout-preserving stages only, and a filter is
  // not one.
  LazyFrame::LazyFrame(df)
  .with_columns([(@expr.col("v") * @expr.lit_int(2)).with_alias("d")])
  .head(2).plan
}

///|
test "every stage off leaves the plan exactly as built" {
  assert_eq(
    plan_render(flag_chain().optimize_with(all_off())),
    plan_render(flag_chain()),
  )
}

///|
test "one flag off removes exactly that stage's rewrite" {
  let as_built = plan_render(flag_chain())
  // The slice pass sinks the head below the with_columns; the flag off
  // keeps the head at the top, which is the as-built shape.
  let no_slice = Optimizations::{
    slice_pushdown: false,
    predicate_pushdown: true,
    projection_pushdown: true,
    cluster_with_columns: true,
    simplify_expressions: true,
  }
  assert_eq(plan_render(flag_chain().optimize_with(no_slice)), as_built)
  // With the slice pass on, the full pipeline's render differs from the
  // as-built one (the head sunk) — the flag has an observable effect.
  assert_true(plan_render(flag_chain().optimize()) != as_built)
}

///|
test "collect carries the flags to the pipeline" {
  // The public seam: an all-off collect still answers the same frame
  // (every stage is semantics-preserving).
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("v", [1, 2, 3, 4]),
  ])
  let chain = LazyFrame::LazyFrame(df)
    .filter(@expr.col("v").gt(@expr.lit_int(1)))
    .sort([(@expr.col("v"), true, true)])
  assert_eq(chain.collect(optimizations=all_off()), chain.collect())
}
