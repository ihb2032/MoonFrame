///|
/// Blackbox shape semantics for the `Expr` tree. `Expr` is an opaque handle
/// over an AST this file cannot name — no variant to spell, and no equality to
/// compare with — so two trees are asserted through their rendering, which is
/// what the shared `assert_same_expr` / `assert_diff_expr` do. What that pins
/// is the documented surface: same shape renders the same, and any difference
/// in shape shows. Construction-route equivalences (operator vs method alias,
/// builder chains) live in `expr_ops_test.mbt`; rendering and
/// column-collection in `explain_test.mbt`; evaluation semantics in
/// `frame/expr_eval_test.mbt`.

///|
test "col: different names are different nodes" {
  assert_diff_expr(col("a"), col("b"))
}

///|
test "lit: payload value and dtype distinguish nodes" {
  assert_diff_expr(lit_int(1), lit_int(2))
  assert_diff_expr(lit_int(1), lit_float(1.0))
}

///|
test "binary: operand order is preserved, not commuted" {
  assert_diff_expr(col("a") + col("b"), col("b") + col("a"))
  assert_diff_expr(col("a").lt(col("b")), col("b").lt(col("a")))
}

///|
test "binary: nesting shape is preserved, not flattened" {
  assert_same_expr(
    col("a") + col("b") + col("c"),
    col("a") + col("b") + col("c"),
  )
  assert_diff_expr(
    col("a") + col("b") + col("c"),
    col("a") + (col("b") + col("c")),
  )
}

///|
test "binary: all twelve operator tags are pairwise distinct nodes" {
  let a = col("a")
  let b = col("b")
  let trees : ReadOnlyArray[Expr] = [
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
      assert_diff_expr(trees[i], trees[j])
    }
  }
}

///|
test "unary: negation, not, and the null probes are distinct wrappers" {
  let e = col("x")
  let trees : ReadOnlyArray[Expr] = [-e, e.not(), e.is_null(), e.is_not_null()]
  for i in 0..<trees.length() {
    for j in (i + 1)..<trees.length() {
      assert_diff_expr(trees[i], trees[j])
    }
  }
}

///|
test "agg: the eleven reductions are distinct wrappers" {
  let e = col("x")
  let trees : ReadOnlyArray[Expr] = [
    e.sum(),
    e.mean(),
    e.min(),
    e.max(),
    e.count(),
    e.std(),
    e.variance(),
    e.median(),
    e.n_unique(),
    e.first(),
    e.last(),
  ]
  for i in 0..<trees.length() {
    for j in (i + 1)..<trees.length() {
      assert_diff_expr(trees[i], trees[j])
    }
  }
}

///|
test "cast and alias: payloads distinguish nodes, wrappers distinguish kinds" {
  let e = col("x")
  assert_same_expr(
    e.cast(@types.DataType::Float),
    e.cast(@types.DataType::Float),
  )
  assert_diff_expr(e.cast(@types.DataType::Float), e.cast(@types.DataType::Int))
  assert_diff_expr(e.with_alias("p"), e.with_alias("q"))
  // Same operand under different wrapper kinds is never the same node.
  assert_diff_expr(e.cast(@types.DataType::Float), e.with_alias("p"))
  assert_diff_expr(e.sum(), e.with_alias("sum"))
}

///|
test "ternary: condition and both branches each distinguish nodes" {
  let cond = col("c").gt(lit_int(0))
  let same = when(cond).then(lit_int(1)).otherwise(lit_int(0))
  assert_same_expr(same, when(cond).then(lit_int(1)).otherwise(lit_int(0)))
  assert_diff_expr(
    same,
    when(col("d").gt(lit_int(0))).then(lit_int(1)).otherwise(lit_int(0)),
  )
  assert_diff_expr(same, when(cond).then(lit_int(2)).otherwise(lit_int(0)))
  assert_diff_expr(same, when(cond).then(lit_int(1)).otherwise(lit_int(9)))
}

///|
test "map: label and inputs distinguish nodes; the closure is opaque" {
  let same_a = map_many(label="m", [col("a")], fn(vs) { vs[0] })
  // Two maps with the same label and inputs render alike even when they hold
  // *different* closures — a map shows `(label, inputs)` and never the
  // (unshowable) function.
  assert_same_expr(
    same_a,
    map_many(label="m", [col("a")], fn(_vs) { @types.Scalar::Null }),
  )
  // The label distinguishes.
  assert_diff_expr(same_a, map_many(label="n", [col("a")], fn(vs) { vs[0] }))
  // The inputs distinguish — both by content and by arity.
  assert_diff_expr(same_a, map_many(label="m", [col("b")], fn(vs) { vs[0] }))
  assert_diff_expr(
    same_a,
    map_many(label="m", [col("a"), col("b")], fn(vs) { vs[0] }),
  )
  // A map never renders like a non-map.
  assert_diff_expr(same_a, col("a"))
}

///|
test "map_batches: label, returns_scalar, and inputs distinguish nodes" {
  let same_a = col("a").map_batches(label="m", fn(s) { s })
  // Same label + returns_scalar + inputs render alike even with different
  // closures — the function is not part of what a node shows.
  assert_same_expr(
    same_a,
    col("a").map_batches(label="m", fn(_s) { Series::from_ints("z", []) }),
  )
  // The label distinguishes.
  assert_diff_expr(same_a, col("a").map_batches(label="n", fn(s) { s }))
  // The input distinguishes.
  assert_diff_expr(same_a, col("b").map_batches(label="m", fn(s) { s }))
  // The `returns_scalar` flag distinguishes two otherwise-identical nodes.
  assert_diff_expr(
    same_a,
    col("a").map_batches(label="m", returns_scalar=true, fn(s) { s }),
  )
  // Never renders like a non-`MapBatches` node — including a same-label
  // `Map`, which is a different kind however alike its payload looks.
  assert_diff_expr(same_a, col("a"))
  assert_diff_expr(same_a, map_many(label="m", [col("a")], fn(vs) { vs[0] }))
}

///|
test "construction is total: nonsense trees still build" {
  // `((p & false) + 1.5).sum().cast(Bool)` cannot evaluate, but building
  // it is fine — every error belongs to evaluation, none to construction.
  assert_same_expr(
    ((col("p") & lit_bool(false)) + lit_float(1.5))
    .sum()
    .cast(@types.DataType::Bool),
    ((col("p") & lit(@types.Scalar::Bool(false))) +
    lit(@types.Scalar::Float(1.5)))
    .sum()
    .cast(@types.DataType::Bool),
  )
}

///|
test "deep trees don't overflow: rendering is iterative" {
  // A left-nested tree this deep overflows any walk that recurses on the call
  // stack, and an overflow aborts. The renderer drives an explicit work stack
  // instead, so a tree of any depth renders — which is what the assertions
  // below compare, and what every caller reaching a tree through `to_string`
  // depends on.
  let depth = 200000
  let mut a = col("a")
  let mut b = col("a")
  for _ in 0..<depth {
    a = a + col("a")
    b = b + col("a")
  }
  assert_same_expr(a, b)
  // A single differing leaf under the same shape is still detected.
  assert_diff_expr(a, b + col("z"))
}

///|
// The "each variant is unequal to every other variant" coverage test lives in
// `internal/ir`, beside the equality it pins: a `variant_tag` match there makes
// adding an `ExprNode` variant a compile error until its representative is
// added, closing the silent gap this blackbox list left (a forgotten rep
// dropped a variant's equality coverage without any signal). It cannot live
// here in any case — `Expr` carries no equality for a blackbox test to reach.

///|
test "shape: fill_null and fill_nan are each their own kind" {
  // The two guard the same shape but are separate variants (not one shared
  // arm): each renders like itself, differently on a differing value, and
  // differently from the other kind even with identical operands.
  assert_same_expr(
    col("a").fill_null(lit_int(0)),
    col("a").fill_null(lit_int(0)),
  )
  assert_same_expr(
    col("a").fill_nan(lit_float(0.0)),
    col("a").fill_nan(lit_float(0.0)),
  )
  assert_diff_expr(
    col("a").fill_null(lit_int(0)),
    col("a").fill_null(lit_int(1)),
  )
  assert_diff_expr(
    col("a").fill_nan(lit_float(0.0)),
    col("a").fill_nan(lit_float(1.0)),
  )
  assert_diff_expr(
    col("a").fill_null(lit_int(0)),
    col("a").fill_nan(lit_int(0)),
  )
}

///|
test "shape: is_in carries its operand and its literal set" {
  let a = col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)])
  assert_same_expr(
    a,
    col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
  )
  // A differing operand, a differing member, and a differing set length each
  // distinguish. The set is structural: `Int(2)` and `Float(2.0)` are distinct
  // members even though `is_in` would match either.
  assert_diff_expr(
    a,
    col("b").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
  )
  assert_diff_expr(
    a,
    col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(3)]),
  )
  assert_diff_expr(a, col("a").is_in([@types.Scalar::Int(1)]))
  assert_diff_expr(
    a,
    col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Float(2.0)]),
  )
  // Never renders like a non-`IsIn` node.
  assert_diff_expr(a, col("a"))
}

///|
test "is_in copies its literal set at the public boundary" {
  let members = [@types.Scalar::Int(1), @types.Scalar::Int(2)]
  let expression = col("a").is_in(members)
  members[0] = @types.Scalar::Int(99)
  assert_same_expr(
    expression,
    col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
  )
}

///|
test "shape: is_between carries its operand and both bounds" {
  let a = col("a").is_between(lit_int(0), lit_int(10))
  assert_same_expr(a, col("a").is_between(lit_int(0), lit_int(10)))
  assert_diff_expr(a, col("b").is_between(lit_int(0), lit_int(10)))
  assert_diff_expr(a, col("a").is_between(lit_int(1), lit_int(10)))
  assert_diff_expr(a, col("a").is_between(lit_int(0), lit_int(9)))
  // Never renders like a non-`IsBetween` node.
  assert_diff_expr(a, col("a"))
}

///|
/// What `docs/api.md` points callers at now that expressions have no equality:
/// compare renderings. So the rendering has to answer the question a caller
/// asks it — "did my builder produce the expression I meant" — which means it
/// shows the tree *as built*, and shows a closure by its label. Both halves
/// surprise someone, so both are pinned here and a change to either has to be
/// a decision.
test "rendering: shows the tree as built, closures by label" {
  // Nothing is simplified on the way in, so an identity operand still counts,
  // and an operator flipped end-for-end is a different tree.
  assert_diff_expr(col("a") + lit_int(0), col("a"))
  assert_diff_expr(lit_int(1).lt(col("a")), col("a").gt(lit_int(1)))
  // A closure has nothing to show: same label, same inputs, same rendering —
  // whatever the two functions actually do. The label is the identity.
  let doubled = map_many(label="f", [col("a")], cells => cells[0])
  let nulled = map_many(label="f", [col("a")], _ => @types.Scalar::Null)
  assert_same_expr(doubled, nulled)
  assert_diff_expr(doubled, map_many(label="g", [col("a")], cells => cells[0]))
}
