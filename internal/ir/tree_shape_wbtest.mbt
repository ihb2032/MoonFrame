// The tree-shape pins for `ExprNode::children`, in the package that owns the
// shape, reading the structural equality this package's own whitebox files
// share. The recursive shape of the AST lives in exactly one place — the
// descent `each_child` encodes — with `children` as the array form the naming
// analyses consume. The pins hold both halves honest: which variants expose
// which sub-nodes, and that the array is fresh on every call.

///|
test "children: each variant exposes its immediate sub-nodes, left to right" {
  let a = Col("a")
  let b = Col("b")
  fn assert_kids(node : ExprNode, want : Array[ExprNode]) -> Unit raise {
    let got = node.children()
    assert_eq(got.length(), want.length())
    for i in 0..<want.length() {
      assert_true(got[i] == want[i])
    }
  }
  // Leaves have no children — a lit_series carries its data inline.
  assert_kids(Col("x"), [])
  assert_kids(Lit(@types.Scalar::Int(1)), [])
  assert_kids(LitSeries(@series.Series::from_ints("v", [1, 2, 3])), [])
  // A binary lists both operands, left to right.
  assert_kids(Binary(Add, a, b), [a, b])
  // The single-child wrappers expose their one operand.
  assert_kids(Unary(Neg, a), [a])
  assert_kids(Unary(IsNull, a), [a])
  assert_kids(Agg(@series.ReduceOp::Sum, a), [a])
  assert_kids(Str(ToUppercase, a), [a])
  assert_kids(Cast(a, @types.DataType::Float), [a])
  assert_kids(Alias(a, "x"), [a])
  // A ternary lists all three arms, condition first.
  let cond = Binary(Gt, a, Lit(@types.Scalar::Int(0)))
  assert_kids(Ternary(cond, a, b), [cond, a, b])
  // `is_in` exposes only its operand — the set is literal data, not children.
  assert_kids(IsIn(a, [@types.Scalar::Int(1)].exact_view()), [a])
  // `is_between` lists its operand and both bounds.
  assert_kids(
    IsBetween(a, Lit(@types.Scalar::Int(0)), b, @types.ClosedInterval::Both),
    [a, Lit(@types.Scalar::Int(0)), b],
  )
  // A map lists its input expressions (none for an empty input list).
  assert_kids(Map("m", [a, b].exact_view(), fn(vs) { vs[0] }), [a, b])
  assert_kids(Map("m", [].exact_view(), fn(_vs) { @types.Scalar::Null }), [])
}

///|
test "children: a map's returned array never aliases the node's inputs" {
  // The array is a fresh copy every call, so mutating it cannot corrupt the
  // (immutable-by-construction) expression tree.
  let m = Map("m", [Col("a")].exact_view(), fn(vs) { vs[0] })
  let kids = m.children()
  kids.push(Col("injected"))
  assert_eq(m.children().length(), 1)
}
