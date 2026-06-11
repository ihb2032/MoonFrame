// Whitebox pins for evaluator arms no public call chain can reach.
//
// `broadcast_pair`'s `LengthMismatch` guard: both operands of a `Binary`
// are evaluated under the same scope, so public callers only ever see
// operand lengths drawn from `{1, |scope|}`; the guard exists to keep the
// helper total — raise, never an out-of-bounds index — for any future
// caller.
//
// `expr_output_name` over the E1-only variants: `with_columns` evaluates
// before it names, and the interim evaluator stubs every E1-only form with
// `Unsupported`, so until E2 lands no public call reaches these naming
// arms. The rule they pin — alias wins, wrappers are transparent, a
// ternary names from its value branches — is the §0 naming contract E2's
// consumers inherit.
//
// Driving either requires calling the private helpers directly, the same
// rationale as `invariants_wbtest.mbt`.

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
