// Whitebox pins for the evaluator's internal contracts.
//
// `broadcast_pair`'s `LengthMismatch` guard: both operands of a `Binary`
// are evaluated under the same scope, so public callers only ever see
// operand lengths drawn from `{1, |scope|}`; the guard exists to keep the
// helper total — raise, never an out-of-bounds index — for any future
// caller. No public call chain reaches it, so it is pinned here directly,
// the same rationale as `invariants_wbtest.mbt`.
//
// `expr_output_name`: the §0 naming rule — alias wins, wrappers are
// transparent, a ternary names from its value branches — spelled directly
// against the private helper, one assertion per clause (the public
// surface exercises it only through whole `with_columns` calls).
//
// `eval_expr` under a partial scope: the public consumers all pass the
// whole-frame scope today; the group-subset behavior is the contract
// `agg_exprs` (E4) builds on, so it is pinned before it gains a public
// caller.

///|
test "broadcast_pair: two incompatible non-unit lengths raise LengthMismatch" {
  let a = Series::from_ints("a", [1, 2])
  let b = Series::from_ints("b", [1, 2, 3])
  assert_true(
    (try? broadcast_pair(a, b)) is Err(@types.DataError::LengthMismatch),
  )
}

///|
test "expr_output_name: alias wins anywhere on the naming path" {
  assert_true(
    expr_output_name((@expr.col("a") + @expr.col("b")).with_alias("net")) ==
    "net",
  )
  // A nested alias on the leftmost path outranks the column beneath it.
  assert_true(
    expr_output_name(@expr.col("a").with_alias("x") + @expr.col("b")) == "x",
  )
}

///|
test "expr_output_name: unary, aggregation, and cast wrappers are transparent" {
  assert_true(expr_output_name(-@expr.col("a")) == "a")
  assert_true(expr_output_name(@expr.col("a").sum()) == "a")
  assert_true(
    expr_output_name(@expr.col("a").cast(@types.DataType::Float)) == "a",
  )
}

///|
test "eval_expr under a group-subset scope: gathers and reduces only those rows" {
  let df = DataFrame::new([
    Series::from_ints("v", [10, 20, 30, 40]),
    Series::from_int_options("w", [Some(1), None, Some(3), None]),
  ])
  let scope = [0, 2]
  // A column reference gathers exactly the scope rows, in scope order.
  assert_true(
    eval_expr(@expr.col("v"), df, scope).to_scalars() ==
    [@types.Scalar::Int(10), @types.Scalar::Int(30)],
  )
  // An aggregation reduces over the scope alone — the per-group semantics
  // `agg_exprs` (E4) will lean on: rows 0 and 2 of `v` sum to 40, and
  // `w`'s nulls inside a scope are skipped as in any other reduction.
  let total = eval_expr(@expr.col("v").sum(), df, scope)
  assert_true(total.len() == 1)
  assert_true(total.to_scalars() == [@types.Scalar::Int(40)])
  let partial = eval_expr(@expr.col("w").sum(), df, [1, 2, 3])
  assert_true(partial.to_scalars() == [@types.Scalar::Int(3)])
}

///|
test "expr_output_name: ternary names from then, falls back to otherwise, never the condition" {
  let cond = @expr.col("c").gt(@expr.lit_int(0))
  assert_true(
    expr_output_name(
      @expr.when(cond).then(@expr.col("t")).otherwise(@expr.col("f")),
    ) ==
    "t",
  )
  assert_true(
    expr_output_name(
      @expr.when(cond).then(@expr.lit_int(1)).otherwise(@expr.col("f")),
    ) ==
    "f",
  )
  assert_true(
    expr_output_name(
      @expr.when(cond).then(@expr.lit_int(1)).otherwise(@expr.lit_int(0)),
    ) ==
    "literal",
  )
}
