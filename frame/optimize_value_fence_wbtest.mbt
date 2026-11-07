// Whitebox pin for the standalone risk walk's aggregate-all step: the
// pushdown passes always hand their risk in, so this walk is the only
// reader that steps an `AggregateAll` node — its hook is the pass-through
// the shared rebuild's last hook spells inline.

///|
test "value risk: an aggregate-all plan rides the standalone walk" {
  let df = DataFrame::DataFrame([
    @series.Series::from_ints("g", [1, 2]),
    @series.Series::from_ints("v", [10, 20]),
  ])
  let plan = LazyFrame::LazyFrame(df).group_by([@expr.col("g")]).sum()
  let risk = value_risk_in_plan(plan.plan)
  // Neither family's names ride an all-int plan, and no leaf raised a flag.
  assert_true(!risk.decimal.any && !risk.temporal.any)
}
