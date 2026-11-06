// The tree-shape pins, asserted through the face production walks use. The
// recursive shape of an expression lives in one place — `ExprNode::children`
// — and every engine walk (the naming analyses, the pushdown stability
// analyses, the value-fence descents) reads it there, so the pins assert it
// there too: whitebox, unwrapping the handle's own `node`. These moved from
// the handle-level face that wrapped them, which no production walk outside
// this package ever called and which the internal-surface guard therefore
// retired.

///|
test "children: each variant exposes its immediate sub-nodes, left to right" {
  let a = col("a")
  let b = col("b")
  fn kid_strings(e : Expr) -> Array[String] {
    e.node.children().map(k => Expr::of_node(k).to_string())
  }
  // Leaves have no children.
  assert_eq(kid_strings(col("x")), [])
  assert_eq(kid_strings(lit_int(1)), [])
  // A binary lists both operands, left to right.
  assert_eq(kid_strings(a + b), [a.to_string(), b.to_string()])
  // The single-child wrappers expose their one operand.
  assert_eq(kid_strings(-a), [a.to_string()])
  assert_eq(kid_strings(a.is_null()), [a.to_string()])
  assert_eq(kid_strings(a.sum()), [a.to_string()])
  assert_eq(kid_strings(a.cast(@types.DataType::Float)), [a.to_string()])
  assert_eq(kid_strings(a.with_alias("x")), [a.to_string()])
  // A ternary lists all three arms, condition first.
  let cond = a.gt(lit_int(0))
  assert_eq(kid_strings(when(cond).then(a).otherwise(b)), [
    cond.to_string(),
    a.to_string(),
    b.to_string(),
  ])
  // `is_in` exposes only its operand — the set is literal data, not children.
  assert_eq(kid_strings(a.is_in([@types.Scalar::Int(1)])), [a.to_string()])
  // `is_between` lists its operand and both bounds.
  assert_eq(kid_strings(a.is_between(lit_int(0), b)), [
    a.to_string(),
    lit_int(0).to_string(),
    b.to_string(),
  ])
  // A map lists its input expressions (none for an empty input list).
  assert_eq(kid_strings(map_many(label="m", [a, b], fn(vs) { vs[0] })), [
    a.to_string(),
    b.to_string(),
  ])
  assert_eq(
    kid_strings(map_many(label="m", [], fn(_vs) { @types.Scalar::Null })),
    [],
  )
  // A string op exposes its single operand; `lit_series` carries its data
  // inline, so it has no sub-nodes.
  assert_eq(kid_strings(col("s").str_to_uppercase()), [col("s").to_string()])
  assert_eq(kid_strings(col("s").str_contains("a")), [col("s").to_string()])
  assert_eq(
    kid_strings(lit_series(@series.Series::from_ints("v", [1, 2, 3]))),
    [],
  )
}

///|
test "children: a map's returned array never aliases the node's inputs" {
  // The array is a fresh copy every call, so mutating it cannot corrupt the
  // (immutable-by-construction) expression tree.
  let m = map_many(label="m", [col("a")], fn(vs) { vs[0] })
  let kids = m.node.children()
  kids.push(@ir.ExprNode::Col("injected"))
  assert_eq(m.node.children().length(), 1)
}
