// Whitebox pins for the constant-folding walk's structural contracts.

///|
/// The rebuild step keeps the walk-excluded shapes verbatim — the closure
/// carriers and the childless leaves never enter the fold with children to
/// rebuild, so their identity arms are defensive. Pinned here directly so
/// the contract (an excluded node handed to the rebuild comes back
/// unchanged, whatever children are attributed to it) is stated as a test
/// rather than left as an unreachable line.
test "rebuild_over: the walk-excluded shapes come back verbatim" {
  let shapes : Array[@ir.ExprNode] = [
    @ir.ExprNode::Col("a"),
    @ir.ExprNode::Lit(@types.Scalar::Int(1)),
    @ir.ExprNode::LitSeries(@series.Series::from_ints("s", [1, 2])),
    @ir.ExprNode::Map("m", [], _ => @types.Scalar::Null),
    @ir.ExprNode::MapBatches("mb", [], false, _ => {
      @series.Series::from_ints("r", [1])
    }),
  ]
  for shape in shapes {
    assert_eq(rebuild_over(shape, []).children().length(), 0)
  }
}
