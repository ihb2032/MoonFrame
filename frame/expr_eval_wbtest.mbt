// Whitebox pin for the single evaluator arm no public call chain can
// reach: `broadcast_pair`'s `LengthMismatch` guard. Both operands of a
// `Binary` are evaluated under the same scope, so public callers only ever
// see operand lengths drawn from `{1, |scope|}`; the guard exists to keep
// the helper total — raise, never an out-of-bounds index — for any future
// caller. Driving it requires calling the private helper directly, the
// same rationale as `invariants_wbtest.mbt`.

///|
test "broadcast_pair: two incompatible non-unit lengths raise LengthMismatch" {
  let a = Series::from_ints("a", [1, 2])
  let b = Series::from_ints("b", [1, 2, 3])
  assert_true(
    (try? broadcast_pair(a, b)) is Err(@types.DataError::LengthMismatch),
  )
}
