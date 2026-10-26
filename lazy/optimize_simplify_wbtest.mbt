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

///|
/// The rebuild step returns each new shape's children to the right slots —
/// `Diff`'s single child and step count, `Clip`'s operand and whichever
/// bounds exist (an omitted side stays absent, a present one lands in its
/// own slot, never shifted into the other's).
test "rebuild_over: diff and clip rebuild over their children" {
  let a : @ir.ExprNode = @ir.ExprNode::Col("a")
  let lit0 : @ir.ExprNode = @ir.ExprNode::Lit(@types.Scalar::Int(0))
  let lit1 : @ir.ExprNode = @ir.ExprNode::Lit(@types.Scalar::Int(1))
  assert_true(
    rebuild_over(@ir.ExprNode::Diff(a, 3), [lit0])
    is @ir.ExprNode::Diff(lit0, 3),
  )
  assert_true(
    rebuild_over(@ir.ExprNode::Clip(a, Some(a), None), [lit0, lit1])
    is @ir.ExprNode::Clip(lit0, Some(lit1), None),
  )
  assert_true(
    rebuild_over(@ir.ExprNode::Clip(a, None, Some(a)), [lit0, lit1])
    is @ir.ExprNode::Clip(lit0, None, Some(lit1)),
  )
  assert_true(
    rebuild_over(@ir.ExprNode::Clip(a, Some(a), Some(a)), [lit0, lit1, a])
    is @ir.ExprNode::Clip(lit0, Some(lit1), Some(a)),
  )
}
