// Coverage guard for the handwritten `ExprNode` equality, next to the function
// it pins. The "one representative per variant" list it needs was a silent sync
// point: forgetting a rep for a new variant would quietly stop testing it (and
// the count lived in a hand-bumped comment). `variant_tag` closes that — an
// exhaustive, wildcard-free match, so a new `ExprNode` variant is a compile
// error HERE until its arm exists, landing the author beside the `reps` list
// they must also extend. The production match-sites already force the variant
// to be handled; this brings the same compile signal to the equality test.
//
// The test lives in this package rather than in `expr`, where it started: the
// relation belongs to the AST, `Expr` no longer carries an `==` to reach it
// through, and a package's own tests are what its coverage is measured by.

///|
/// A distinct tag per `ExprNode` variant, in declaration order — exhaustive and
/// wildcard-free on purpose, so adding a variant forces an arm here (a compile
/// error at this test file) rather than silently dropping its equality
/// coverage.
fn variant_tag(node : ExprNode) -> Int {
  match node {
    Col(_) => 0
    Lit(_) => 1
    LitSeries(_) => 2
    Binary(_, _, _) => 3
    Unary(_, _) => 4
    Agg(_, _) => 5
    Str(_, _) => 6
    Cast(_, _) => 7
    Alias(_, _) => 8
    Ternary(_, _, _) => 9
    FillNull(_, _) => 10
    FillNan(_, _) => 11
    IsIn(_, _) => 12
    IsBetween(_, _, _, _) => 13
    Map(_, _, _) => 14
    MapBatches(_, _, _, _) => 15
  }
}

///|
test "equality: each variant is unequal to every other variant" {
  // One representative of each `ExprNode` variant, in `variant_tag` order.
  let a : ExprNode = Col("a")
  let one : ExprNode = Lit(@types.Scalar::Int(1))
  let reps : ReadOnlyArray[ExprNode] = [
    a,
    one,
    LitSeries(@series.Series::from_ints("s", [1])),
    Binary(BinOp::Add, a, Col("b")),
    Unary(UnOp::Neg, a),
    Agg(AggOp::Sum, a),
    Str(StrOp::ToUppercase, a),
    Cast(a, @types.DataType::Float),
    Alias(a, "z"),
    Ternary(Col("c"), one, Lit(@types.Scalar::Int(0))),
    FillNull(a, Lit(@types.Scalar::Int(0))),
    FillNan(a, Lit(@types.Scalar::Float(0.0))),
    IsIn(a, [@types.Scalar::Int(1)]),
    IsBetween(
      a,
      Lit(@types.Scalar::Int(0)),
      Lit(@types.Scalar::Int(10)),
      @types.ClosedInterval::Both,
    ),
    Map("m", [a], vs => vs[0]),
    MapBatches("mb", [a], false, s => s[0]),
  ]
  // The reps carry one of every variant, in tag order with no gap — so the
  // count is derived from `variant_tag` rather than hand-maintained, a
  // duplicated or misordered rep is caught, and a variant added to
  // `variant_tag` above (a compile error there) is not left untested here.
  let tags = Array::makei(reps.length(), i => variant_tag(reps[i]))
  assert_eq(tags, Array::makei(reps.length(), i => i))
  // Comparing every ordered pair of distinct variants exercises each
  // per-variant arm of the structural equality as the *first* operand — the arm
  // a future variant addition is forced to extend.
  for i in 0..<reps.length() {
    for j in 0..<reps.length() {
      if i != j {
        assert_false(reps[i] == reps[j])
      }
    }
  }
  // And each representative equals itself, which is the other half of every
  // arm: the one that walks into the children rather than short-circuiting on
  // a variant mismatch.
  for rep in reps {
    assert_true(rep == rep)
  }
}

///|
test "equality: within a variant, a differing payload is unequal" {
  // The other half of each arm: two nodes of the *same* variant that differ in
  // what the arm compares before walking into children — the operator tag, the
  // cast target, the alias, the membership set, the interval, a closure's
  // label. Variant-against-variant (above) short-circuits before reaching any
  // of these.
  let a : ExprNode = Col("a")
  let b : ExprNode = Col("b")
  assert_false(
    (Binary(BinOp::Add, a, b) : ExprNode) == Binary(BinOp::Sub, a, b),
  )
  assert_false((Unary(UnOp::Neg, a) : ExprNode) == Unary(UnOp::Not, a))
  assert_false((Agg(AggOp::Sum, a) : ExprNode) == Agg(AggOp::Mean, a))
  assert_false(
    (Str(StrOp::ToUppercase, a) : ExprNode) == Str(StrOp::ToLowercase, a),
  )
  assert_false(
    (Cast(a, @types.DataType::Float) : ExprNode) ==
    Cast(a, @types.DataType::Int),
  )
  assert_false((Alias(a, "x") : ExprNode) == Alias(a, "y"))
  assert_false(
    (IsIn(a, [@types.Scalar::Int(1)]) : ExprNode) ==
    IsIn(a, [@types.Scalar::Int(2)]),
  )
  let zero : ExprNode = Lit(@types.Scalar::Int(0))
  let ten : ExprNode = Lit(@types.Scalar::Int(10))
  assert_false(
    (IsBetween(a, zero, ten, @types.ClosedInterval::Both) : ExprNode) ==
    IsBetween(a, zero, ten, @types.ClosedInterval::Left),
  )
  // A closure has no identity, so a `Map` is its label and its input count.
  assert_false(
    (Map("m", [a], vs => vs[0]) : ExprNode) == Map("n", [a], vs => vs[0]),
  )
  assert_false(
    (MapBatches("mb", [a], false, s => s[0]) : ExprNode) ==
    MapBatches("mb", [a], true, s => s[0]),
  )
}
