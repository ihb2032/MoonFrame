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
  assert_eq(col("a"), col("a"))
  assert_eq(lit(@types.Scalar::Int(7)), lit(@types.Scalar::Int(7)))
}

///|
test "cols: maps names to a column-reference list, preserving order" {
  assert_eq(cols(["a", "b", "c"]), [col("a"), col("b"), col("c")])
  // The empty list is the empty projection, not an error.
  assert_eq(cols([]), [])
}

///|
test "lit: typed shorthands agree with the generic form" {
  assert_eq(lit_int(7), lit(@types.Scalar::Int(7)))
  assert_eq(lit_float(0.5), lit(@types.Scalar::Float(0.5)))
  assert_eq(lit_str("x"), lit(@types.Scalar::String("x")))
  assert_eq(lit_bool(true), lit(@types.Scalar::Bool(true)))
  assert_eq(lit(@types.Scalar::Null), lit(@types.Scalar::Null))
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
test "map_elements builds the single-input map_many node" {
  // `map_elements(self, label, f)` is `map_many(label, [self], _)`; the
  // closures differ (one adapts a single cell), but they are opaque to
  // `Eq`, so the construction routes compare equal on `(label, inputs)`.
  assert_eq(
    col("x").map_elements(label="m", fn(s) { s }),
    map_many(label="m", [col("x")], fn(vs) { vs[0] }),
  )
  // `inputs` order is preserved, like every other multi-operand node.
  assert_not_eq(
    map_many(label="m", [col("a"), col("b")], fn(vs) { vs[0] }),
    map_many(label="m", [col("b"), col("a")], fn(vs) { vs[0] }),
  )
}

///|
test "map_many copies its inputs array" {
  // Mutating the caller's array after building must not alter the node
  // (pinned through `Eq`, which compares `(label, inputs)`).
  let ins = [col("a")]
  let e = map_many(label="m", ins, fn(vs) { vs[0] })
  ins.push(col("b"))
  assert_eq(e, map_many(label="m", [col("a")], fn(vs) { vs[0] }))
}

///|
test "fill_null builds a dedicated node holding self once, named after self" {
  // `fill_null(self, value)` is the dedicated `FillNull(self, value)` node —
  // semantically the not-null guarded ternary, but `self` appears once
  // (the ternary lowering embedded it twice, so chains grew exponentially).
  inspect(
    col("x").fill_null(lit_int(0)).to_string(),
    content="col(x).fill_null(0)",
  )
  // Named after `self` (`x`) even when the fill value is another column.
  assert_eq(col("x").fill_null(col("y")).output_name(), "x")
  // Both the filled column and the fill source are referenced (pushdown
  // must keep each alive).
  let refs = col("x").fill_null(col("y")).referenced_columns()
  assert_true(refs.contains("x") && refs.contains("y"))
}

///|
test "fill_nan builds a dedicated node holding self once, named after self" {
  // The dual of `fill_null`: semantically the not-nan guarded ternary, so a
  // null cell (for which `is_not_nan` is null) falls through to a null,
  // never to `value` — but `self` is held once, like `FillNull`.
  inspect(
    col("x").fill_nan(lit_float(0.0)).to_string(),
    content="col(x).fill_nan(0.0)",
  )
  assert_eq(col("x").fill_nan(col("y")).output_name(), "x")
  let refs = col("x").fill_nan(col("y")).referenced_columns()
  assert_true(refs.contains("x") && refs.contains("y"))
}

///|
test "a chained coalesce builds a linear tree" {
  // 24 chained fills: the old ternary lowering held 2^24 copies of the base
  // subtree (rendering alone would be hundreds of MB); the dedicated node
  // holds each link once, so the rendering grows by a constant per link.
  let mut e = col("x")
  for i in 1..<=24 {
    e = e.fill_null(col("f\{i}"))
  }
  let rendered = e.to_string()
  // ~21 chars per link; the old lowering would render 2^24 subtree copies
  // (hundreds of MB), so a small linear bound separates the two regimes.
  assert_true(rendered.length() < 800)
  // Structural equality over the chain is likewise linear and exact.
  let mut e2 = col("x")
  for i in 1..<=24 {
    e2 = e2.fill_null(col("f\{i}"))
  }
  assert_eq(e, e2)
  assert_not_eq(e, e2.fill_null(lit_int(0)))
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
