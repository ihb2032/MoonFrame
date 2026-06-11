///|
/// Blackbox construction tests for the S0 `Expr` subset. The enum is
/// read-only outside `expr` (`[4036]` — this file cannot spell
/// `Expr::Col(..)` directly), so trees are asserted by comparing
/// construction routes under derived `Eq`; the evaluation semantics of the
/// same trees are pinned in `frame/expr_eval_test.mbt`.

///|
test "col: static method and free alias build the same node" {
  assert_eq(col("a"), Expr::col("a"))
}

///|
test "col: different names are different nodes" {
  assert_not_eq(col("a"), col("b"))
}

///|
test "lit: generic form and typed shorthands agree" {
  assert_eq(lit_int(7), lit(@types.Scalar::Int(7)))
  assert_eq(lit_float(0.5), lit(@types.Scalar::Float(0.5)))
  assert_eq(lit_str("x"), lit(@types.Scalar::String("x")))
  assert_eq(lit_bool(true), lit(@types.Scalar::Bool(true)))
  assert_eq(lit(@types.Scalar::Null), Expr::lit(@types.Scalar::Null))
}

///|
test "lit: payload value and dtype distinguish nodes" {
  assert_not_eq(lit_int(1), lit_int(2))
  assert_not_eq(lit_int(1), lit_float(1.0))
}

///|
test "add: `+` builds a Binary node and preserves operand order" {
  assert_eq(col("a") + col("b"), Expr::col("a") + Expr::col("b"))
  assert_not_eq(col("a") + col("b"), col("b") + col("a"))
}

///|
test "add: nesting shape is preserved, not flattened" {
  assert_eq(col("a") + col("b") + col("c"), col("a") + col("b") + col("c"))
  assert_not_eq(
    col("a") + col("b") + col("c"),
    col("a") + (col("b") + col("c")),
  )
}

///|
test "and: `&` builds a Binary node distinct from `+`" {
  assert_eq(col("p") & col("q"), Expr::col("p") & Expr::col("q"))
  assert_not_eq(col("p") & col("q"), col("p") + col("q"))
  assert_not_eq(col("p") & col("q"), col("q") & col("p"))
}

///|
test "construction is total: nonsense trees still build" {
  // `(p & false) + 1.5` cannot evaluate (Bool + Float), but building it is
  // fine — every error belongs to evaluation, none to construction.
  assert_eq(
    (col("p") & lit_bool(false)) + lit_float(1.5),
    (Expr::col("p") & lit(@types.Scalar::Bool(false))) +
    lit(@types.Scalar::Float(1.5)),
  )
}
