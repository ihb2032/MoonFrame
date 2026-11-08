// Whitebox coverage pins for the temporal risk walk's accumulator steps
// over non-empty stage sets — the rename / rename_with / unpivot folds
// the passes reach only through plans whose trees they happen to cross,
// pinned here directly so every step stays counted.

///|
test "the standalone walk steps an aggregate-all plan" {
  let df = DataFrame::DataFrame([
    @series.Series::from_ints("g", [1, 2]),
    @series.Series::from_ints("v", [10, 20]),
  ])
  let plan = LazyFrame::LazyFrame(df).group_by([@expr.col("g")]).sum()
  let risk = value_risk_in_plan(plan.plan)
  assert_true(!risk.any)
}

///|
test "the risk accumulators fold non-empty stage sets" {
  let stage = @set.Set([])
  stage.add("ts")
  let below = leaf_acc(stage)
  // Rename moves the family's name; the union folds both spellings.
  let renamed = rename_acc(below, [("ts", "moment")])
  assert_true(renamed.stage.contains("moment"))
  assert_true(renamed.union.contains("ts"))
  // RenameWith maps through the closure.
  let closed = rename_with_acc(below, n => n + "_x")
  assert_true(closed.stage.contains("ts_x"))
  // Unpivot keeps the index names beside the value column.
  let unpivoted = unpivot_acc(below, "v")
  assert_true(unpivoted.stage.contains("v"))
  assert_true(unpivoted.stage.contains("ts"))
}
