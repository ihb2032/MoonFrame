///|
/// Blackbox equality / shape semantics for the `Expr` tree. The enum is
/// read-only outside `expr` (`[4036]` — this file cannot spell
/// `Expr::Col(..)` directly), so trees are asserted by comparing
/// construction routes under derived `Eq`. Construction-route equivalences
/// (static vs free constructors, operator vs method alias, builder chains)
/// live in `expr_ops_test.mbt`; rendering and column-collection in
/// `explain_test.mbt`; evaluation semantics in `frame/expr_eval_test.mbt`.

///|
test "col: different names are different nodes" {
  assert_not_eq(col("a"), col("b"))
}

///|
test "lit: payload value and dtype distinguish nodes" {
  assert_not_eq(lit_int(1), lit_int(2))
  assert_not_eq(lit_int(1), lit_float(1.0))
}

///|
test "binary: operand order is preserved, not commuted" {
  assert_not_eq(col("a") + col("b"), col("b") + col("a"))
  assert_not_eq(col("a").lt(col("b")), col("b").lt(col("a")))
}

///|
test "binary: nesting shape is preserved, not flattened" {
  assert_eq(col("a") + col("b") + col("c"), col("a") + col("b") + col("c"))
  assert_not_eq(
    col("a") + col("b") + col("c"),
    col("a") + (col("b") + col("c")),
  )
}

///|
test "binary: all twelve operator tags are pairwise distinct nodes" {
  let a = col("a")
  let b = col("b")
  let trees = [
    a + b,
    a - b,
    a * b,
    a / b,
    a.eq(b),
    a.ne(b),
    a.lt(b),
    a.le(b),
    a.gt(b),
    a.ge(b),
    a & b,
    a | b,
  ]
  for i in 0..<trees.length() {
    for j in (i + 1)..<trees.length() {
      assert_not_eq(trees[i], trees[j])
    }
  }
}

///|
test "unary: negation, not, and the null probes are distinct wrappers" {
  let e = col("x")
  let trees = [-e, e.not(), e.is_null(), e.is_not_null()]
  for i in 0..<trees.length() {
    for j in (i + 1)..<trees.length() {
      assert_not_eq(trees[i], trees[j])
    }
  }
}

///|
test "agg: the five reductions are distinct wrappers" {
  let e = col("x")
  let trees = [e.sum(), e.mean(), e.min(), e.max(), e.count()]
  for i in 0..<trees.length() {
    for j in (i + 1)..<trees.length() {
      assert_not_eq(trees[i], trees[j])
    }
  }
}

///|
test "cast and alias: payloads distinguish nodes, wrappers distinguish kinds" {
  let e = col("x")
  assert_eq(e.cast(@types.DataType::Float), e.cast(@types.DataType::Float))
  assert_not_eq(e.cast(@types.DataType::Float), e.cast(@types.DataType::Int))
  assert_not_eq(e.with_alias("p"), e.with_alias("q"))
  // Same operand under different wrapper kinds is never the same node.
  assert_not_eq(e.cast(@types.DataType::Float), e.with_alias("p"))
  assert_not_eq(e.sum(), e.with_alias("sum"))
}

///|
test "ternary: condition and both branches each distinguish nodes" {
  let cond = col("c").gt(lit_int(0))
  let same = when(cond).then(lit_int(1)).otherwise(lit_int(0))
  assert_eq(same, when(cond).then(lit_int(1)).otherwise(lit_int(0)))
  assert_not_eq(
    same,
    when(col("d").gt(lit_int(0))).then(lit_int(1)).otherwise(lit_int(0)),
  )
  assert_not_eq(same, when(cond).then(lit_int(2)).otherwise(lit_int(0)))
  assert_not_eq(same, when(cond).then(lit_int(1)).otherwise(lit_int(9)))
}

///|
test "construction is total: nonsense trees still build" {
  // `((p & false) + 1.5).sum().cast(Bool)` cannot evaluate, but building
  // it is fine — every error belongs to evaluation, none to construction.
  assert_eq(
    ((col("p") & lit_bool(false)) + lit_float(1.5))
    .sum()
    .cast(@types.DataType::Bool),
    ((Expr::col("p") & lit(@types.Scalar::Bool(false))) +
    lit(@types.Scalar::Float(1.5)))
    .sum()
    .cast(@types.DataType::Bool),
  )
}
