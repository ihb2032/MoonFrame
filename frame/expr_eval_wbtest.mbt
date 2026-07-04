// Whitebox pins for the evaluator's internal contracts.
//
// `broadcast_pair`'s `LengthMismatch` guard: for most operands both sides of
// a `Binary` evaluate under the same scope, so their lengths are drawn from
// `{1, |scope|}` and align; a `lit_series` evaluates at its own length, so a
// public `lit_series(len2) + lit_series(len3)` reaches the guard (also covered
// through the public surface by `lit_series_test.mbt`). Pinned here directly
// at the helper for a focused contract, the same rationale as
// `invariants_wbtest.mbt`.
//
// `eval_expr` under a partial scope: the whole-frame consumers pass the
// whole-frame scope; the group-subset behavior is the contract the grouped
// `agg` builds on, pinned here at the evaluator level.

///|
test "broadcast_pair: two incompatible non-unit lengths raise LengthMismatch" {
  let a = Series::from_ints("a", [1, 2])
  let b = Series::from_ints("b", [1, 2, 3])
  assert_true(
    (Ok(broadcast_pair(a, b)) catch { e => Err(e) })
    is Err(@types.DataError::LengthMismatch),
  )
}

///|
test "broadcast_series: a length neither 1 nor target raises LengthMismatch" {
  // The frame-tall broadcast (with_columns / select / filter)
  // trusts eval results to be length 1 or |scope|; the guard keeps it total
  // for any other length rather than gathering out of bounds.
  let s = Series::from_ints("s", [1, 2])
  assert_true(
    (Ok(broadcast_series(s, 3)) catch { e => Err(e) })
    is Err(@types.DataError::LengthMismatch),
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
  // the grouped `agg` leans on: rows 0 and 2 of `v` sum to 40, and `w`'s
  // nulls inside a scope are skipped as in any other reduction.
  let total = eval_expr(@expr.col("v").sum(), df, scope)
  assert_true(total.len() == 1)
  assert_true(total.to_scalars() == [@types.Scalar::Int(40)])
  let partial = eval_expr(@expr.col("w").sum(), df, [1, 2, 3])
  assert_true(partial.to_scalars() == [@types.Scalar::Int(3)])
}
