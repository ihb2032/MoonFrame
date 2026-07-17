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
      assert_not_eq(trees[i], trees[j])
    }
  }
}

///|
test "unary: negation, not, and the null probes are distinct wrappers" {
  let e = col("x")
  let trees : ReadOnlyArray[Expr] = [-e, e.not(), e.is_null(), e.is_not_null()]
  for i in 0..<trees.length() {
    for j in (i + 1)..<trees.length() {
      assert_not_eq(trees[i], trees[j])
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
test "map: label and inputs distinguish nodes; the closure is opaque" {
  let same_a = map_many(label="m", [col("a")], fn(vs) { vs[0] })
  // Two maps with the same label and inputs are equal even when they hold
  // *different* closures — equality reads `(label, inputs)`, never the
  // (uncomparable) function.
  assert_eq(
    same_a,
    map_many(label="m", [col("a")], fn(_vs) { @types.Scalar::Null }),
  )
  // The label distinguishes.
  assert_not_eq(same_a, map_many(label="n", [col("a")], fn(vs) { vs[0] }))
  // The inputs distinguish — both by content and by arity.
  assert_not_eq(same_a, map_many(label="m", [col("b")], fn(vs) { vs[0] }))
  assert_not_eq(
    same_a,
    map_many(label="m", [col("a"), col("b")], fn(vs) { vs[0] }),
  )
  // A map is never equal to a non-map (the mismatched-variant fallthrough).
  assert_not_eq(same_a, col("a"))
}

///|
test "map_batches: label, returns_scalar, and inputs distinguish nodes" {
  let same_a = col("a").map_batches(label="m", fn(s) { s })
  // Same label + returns_scalar + inputs are equal even with different
  // closures — the function is opaque to equality.
  assert_eq(
    same_a,
    col("a").map_batches(label="m", fn(_s) { Series::from_ints("z", []) }),
  )
  // The label distinguishes.
  assert_not_eq(same_a, col("a").map_batches(label="n", fn(s) { s }))
  // The input distinguishes.
  assert_not_eq(same_a, col("b").map_batches(label="m", fn(s) { s }))
  // The `returns_scalar` flag distinguishes two otherwise-identical nodes.
  assert_not_eq(
    same_a,
    col("a").map_batches(label="m", returns_scalar=true, fn(s) { s }),
  )
  // Never equal to a non-`MapBatches` node — including a same-label `Map`
  // (the mismatched-variant fallthrough).
  assert_not_eq(same_a, col("a"))
  assert_not_eq(same_a, map_many(label="m", [col("a")], fn(vs) { vs[0] }))
}

///|
test "lit_series: equal when the embedded series is equal, distinct otherwise" {
  let s = Series::from_ints("v", [1, 2, 3])
  // Two literal-series nodes over equal series are equal nodes (`Series` has
  // structural `Eq`); a series differing by name, cells, or dtype is a
  // different node.
  assert_eq(lit_series(s), lit_series(Series::from_ints("v", [1, 2, 3])))
  assert_not_eq(lit_series(s), lit_series(Series::from_ints("w", [1, 2, 3])))
  assert_not_eq(lit_series(s), lit_series(Series::from_ints("v", [1, 2, 4])))
  assert_not_eq(
    lit_series(s),
    lit_series(Series::from_bools("v", [true, false, true])),
  )
  // A literal series is never equal to a non-`LitSeries` (the mismatched-
  // variant fallthrough).
  assert_not_eq(lit_series(s), col("v"))
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

///|
test "deep trees don't overflow structural equality: `==` is iterative" {
  // A left-nested tree this deep formerly overflowed the native stack and
  // aborted inside the handwritten `Eq` — reached by `==` / `assert_eq` and the
  // derived equality of any structure embedding an `Expr`. The explicit
  // work-stack compares any depth without aborting.
  let depth = 200000
  let mut a = col("a")
  let mut b = col("a")
  for _ in 0..<depth {
    a = a + col("a")
    b = b + col("a")
  }
  assert_true(a == b)
  // A single differing leaf under the same shape is still detected.
  assert_true(a != b + col("z"))
}

///|
test "equality: each variant is unequal to every other variant" {
  // One representative of each of the sixteen `Expr` variants. Comparing
  // every ordered pair of distinct variants exercises each per-variant arm of
  // the handwritten structural equality as the *first* operand — the arms a
  // future variant addition is forced to extend.
  let reps : ReadOnlyArray[Expr] = [
    col("a"),
    lit_int(1),
    lit_series(Series::from_ints("s", [1])),
    col("a") + col("b"),
    -col("a"),
    col("a").sum(),
    col("a").str_to_uppercase(),
    col("a").cast(@types.DataType::Float),
    col("a").with_alias("z"),
    when(col("c")).then(lit_int(1)).otherwise(lit_int(0)),
    col("a").fill_null(lit_int(0)),
    col("a").fill_nan(lit_float(0.0)),
    col("a").is_in([@types.Scalar::Int(1)]),
    col("a").is_between(lit_int(0), lit_int(10)),
    map_many(label="m", [col("a")], fn(vs) { vs[0] }),
    col("a").map_batches(label="mb", fn(s) { s }),
  ]
  for i in 0..<reps.length() {
    for j in 0..<reps.length() {
      if i != j {
        assert_not_eq(reps[i], reps[j])
      }
    }
  }
}

///|
test "equality: fill_null and fill_nan compare structurally, each its own kind" {
  // The two guard the same shape but are separate variants (not one shared
  // arm): each compares equal to itself, unequal on a differing value, and
  // unequal to the other kind even with identical operands.
  assert_eq(col("a").fill_null(lit_int(0)), col("a").fill_null(lit_int(0)))
  assert_eq(
    col("a").fill_nan(lit_float(0.0)),
    col("a").fill_nan(lit_float(0.0)),
  )
  assert_not_eq(col("a").fill_null(lit_int(0)), col("a").fill_null(lit_int(1)))
  assert_not_eq(
    col("a").fill_nan(lit_float(0.0)),
    col("a").fill_nan(lit_float(1.0)),
  )
  assert_not_eq(col("a").fill_null(lit_int(0)), col("a").fill_nan(lit_int(0)))
}

///|
test "equality: is_in compares operand and its literal set" {
  let a = col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)])
  assert_eq(a, col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)]))
  // A differing operand, a differing member, and a differing set length each
  // distinguish. The set is structural: `Int(2)` and `Float(2.0)` are distinct
  // members even though `is_in` would match either.
  assert_not_eq(
    a,
    col("b").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
  )
  assert_not_eq(
    a,
    col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Int(3)]),
  )
  assert_not_eq(a, col("a").is_in([@types.Scalar::Int(1)]))
  assert_not_eq(
    a,
    col("a").is_in([@types.Scalar::Int(1), @types.Scalar::Float(2.0)]),
  )
  // Never equal to a non-`IsIn` node (the mismatched-variant fallthrough).
  assert_not_eq(a, col("a"))
}

///|
test "equality: is_between compares operand and both bounds" {
  let a = col("a").is_between(lit_int(0), lit_int(10))
  assert_eq(a, col("a").is_between(lit_int(0), lit_int(10)))
  assert_not_eq(a, col("b").is_between(lit_int(0), lit_int(10)))
  assert_not_eq(a, col("a").is_between(lit_int(1), lit_int(10)))
  assert_not_eq(a, col("a").is_between(lit_int(0), lit_int(9)))
  // Never equal to a non-`IsBetween` node.
  assert_not_eq(a, col("a"))
}
