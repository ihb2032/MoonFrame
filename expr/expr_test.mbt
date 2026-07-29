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
  // Two maps with the same label and inputs are equal even when they hold
  // *different* closures — equality reads `(label, inputs)`, never the
  // (uncomparable) function.
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
  // A map is never equal to a non-map (the mismatched-variant fallthrough).
  assert_diff_expr(same_a, col("a"))
}

///|
test "map_batches: label, returns_scalar, and inputs distinguish nodes" {
  let same_a = col("a").map_batches(label="m", fn(s) { s })
  // Same label + returns_scalar + inputs are equal even with different
  // closures — the function is opaque to equality.
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
  // Never equal to a non-`MapBatches` node — including a same-label `Map`
  // (the mismatched-variant fallthrough).
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
test "equality: fill_null and fill_nan compare structurally, each its own kind" {
  // The two guard the same shape but are separate variants (not one shared
  // arm): each compares equal to itself, unequal on a differing value, and
  // unequal to the other kind even with identical operands.
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
test "equality: is_in compares operand and its literal set" {
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
  // Never equal to a non-`IsIn` node (the mismatched-variant fallthrough).
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
test "equality: is_between compares operand and both bounds" {
  let a = col("a").is_between(lit_int(0), lit_int(10))
  assert_same_expr(a, col("a").is_between(lit_int(0), lit_int(10)))
  assert_diff_expr(a, col("b").is_between(lit_int(0), lit_int(10)))
  assert_diff_expr(a, col("a").is_between(lit_int(1), lit_int(10)))
  assert_diff_expr(a, col("a").is_between(lit_int(0), lit_int(9)))
  // Never equal to a non-`IsBetween` node.
  assert_diff_expr(a, col("a"))
}

///|
/// The compatibility contract `docs/api.md` states for `==` on expressions:
/// structural over the tree as built, with a closure compared by its label.
/// Both halves surprise someone — they are pinned here so a change to either
/// has to be a decision.
test "equality: structural as built, closures compared by label" {
  // Nothing is simplified on the way in, so an identity operand still counts,
  // and an operator flipped end-for-end is a different tree.
  assert_diff_expr(col("a") + lit_int(0), col("a"))
  assert_diff_expr(lit_int(1).lt(col("a")), col("a").gt(lit_int(1)))
  // A closure has no identity: same label, same inputs, equal — whatever the
  // two functions actually do. The label is the function identity.
  let doubled = map_many(label="f", [col("a")], cells => cells[0])
  let nulled = map_many(label="f", [col("a")], _ => @types.Scalar::Null)
  assert_same_expr(doubled, nulled)
  assert_diff_expr(doubled, map_many(label="g", [col("a")], cells => cells[0]))
}
