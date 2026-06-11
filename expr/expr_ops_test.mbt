///|
/// Blackbox construction-route tests for the `expr_ops.mbt` surface: every
/// route that is *supposed* to build the same node (static method vs free
/// alias, operator vs method alias, builder chain vs one-shot chain) is
/// pinned equal under derived `Eq`, and the chain ergonomics the design
/// leans on (postfix methods binding tighter than `&` / `|`) are pinned by
/// parenthesisation equivalence. Tree-shape semantics live in
/// `expr_test.mbt`, rendering in `explain_test.mbt`.

///|
test "col and lit: static methods and free aliases build the same nodes" {
  assert_eq(col("a"), Expr::col("a"))
  assert_eq(lit(@types.Scalar::Int(7)), Expr::lit(@types.Scalar::Int(7)))
}

///|
test "lit: typed shorthands agree with the generic form" {
  assert_eq(lit_int(7), lit(@types.Scalar::Int(7)))
  assert_eq(lit_float(0.5), lit(@types.Scalar::Float(0.5)))
  assert_eq(lit_str("x"), lit(@types.Scalar::String("x")))
  assert_eq(lit_bool(true), lit(@types.Scalar::Bool(true)))
  assert_eq(lit(@types.Scalar::Null), Expr::lit(@types.Scalar::Null))
}

///|
test "logical operators and their method aliases build identical nodes" {
  // `and` is a MoonBit reserved word, so the method aliases are the
  // `BitAnd` / `BitOr` impl spellings themselves.
  let p = col("p")
  let q = col("q")
  assert_eq(p.land(q), p & q)
  assert_eq(p.lor(q), p | q)
  assert_not_eq(p & q, p | q)
}

///|
test "postfix comparisons bind tighter than logical operators" {
  // The design claim behind comparisons-as-methods: the chain needs no
  // parentheses, unlike Polars' operator comparisons — `&` receives the
  // two completed comparisons as its operands.
  let left = col("a").gt(lit_int(0))
  let right = col("b").lt(lit_int(5))
  assert_eq(col("a").gt(lit_int(0)) & col("b").lt(lit_int(5)), left & right)
}

///|
test "method chains compose left to right" {
  let summed = col("a").sum()
  assert_eq(col("a").sum().with_alias("x"), summed.with_alias("x"))
  // Wrapping order is part of the tree: alias-then-sum is a different
  // expression from sum-then-alias.
  assert_not_eq(col("a").sum().with_alias("x"), col("a").with_alias("x").sum())
}

///|
test "operator precedence: multiplicative over additive, unary minus tightest" {
  let prod = col("b") * col("c")
  assert_eq(col("a") + col("b") * col("c"), col("a") + prod)
  let negx = -col("x")
  assert_eq(-col("x") + col("y"), negx + col("y"))
}

///|
test "when/then/otherwise: held builder steps equal the one-shot chain" {
  let cond = col("score").ge(lit_int(60))
  let staged = when(cond)
  let staged2 = staged.then(lit_str("pass"))
  assert_eq(
    staged2.otherwise(lit_str("fail")),
    when(cond).then(lit_str("pass")).otherwise(lit_str("fail")),
  )
}

///|
test "when/then/otherwise: the conditional is an ordinary expression" {
  // The lowered conditional composes like any other node — method chains
  // and operators apply to it directly, and it occupies an operand slot
  // like any leaf would.
  let grade = when(col("s").ge(lit_int(60)))
    .then(lit_int(1))
    .otherwise(lit_int(0))
  let aliased = grade.with_alias("g")
  assert_eq(aliased, grade.with_alias("g"))
  assert_not_eq(grade + col("bonus"), col("bonus") + grade)
}
