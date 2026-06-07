// Blackbox tests for `NumericColumn` (S0 spike, PLAN_v0.3.md §3 S0). These
// exercise the validation point 3 — the all-valid numeric backend has a
// real, testable difference from `BuiltinColumn`, not an empty abstraction:
//   • construction stores only the data array (no validity `Bitmap`), so
//     `null_count` is structural (`0`) with no popcount;
//   • `sum` folds the raw array with no validity materialisation/branch;
//   • `to_builtin` widening is exactly `BuiltinColumn::from_ints` (the
//     bitmap allocation the numeric path avoided), and is value-preserving.

// ── Construction + inspection ─────────────────────────────────────────

///|
test "from_int64s: structural all-valid, no bitmap" {
  let col = NumericColumn::from_int64s([10, 20, 30])
  assert_eq(col.len(), 3)
  assert_eq(col.dtype(), @types.DataType::Int)
  // null_count is 0 by construction — no validity buffer to consult.
  assert_eq(col.null_count(), 0)
  assert_true(NumericColumn::from_int64s([]).is_empty())
  assert_true(!col.is_empty())
}

///|
test "data() exposes the shared raw array as ColumnData::Int" {
  let col = NumericColumn::from_int64s([1, 2, 3])
  assert_eq(col.data(), ColumnData::Int([1, 2, 3]))
}

// ── get ───────────────────────────────────────────────────────────────

///|
test "get: in-bounds reads value, out-of-bounds raises (no null branch)" {
  let col = NumericColumn::from_int64s([7, 8, 9])
  assert_eq(col.get(0), @types.Scalar::Int(7))
  assert_eq(col.get(2), @types.Scalar::Int(9))
  // Both out-of-bounds directions raise; there is no null slot to report.
  assert_eq(try? col.get(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(try? col.get(3), Err(@types.DataError::IndexOutOfBounds(3)))
}

// ── sum (all-valid fast path) ─────────────────────────────────────────

///|
test "sum: folds raw array, total, identity on empty" {
  assert_eq(
    NumericColumn::from_int64s([1, 2, 3, 4]).sum(),
    @types.Scalar::Int(10),
  )
  // Empty → additive identity, no raise (unlike Series::sum on non-numeric).
  assert_eq(NumericColumn::from_int64s([]).sum(), @types.Scalar::Int(0))
  // Accumulates in Int64 — a sum past the 32-bit ceiling does not overflow.
  let big = NumericColumn::from_int64s([2147483647, 2147483647, 2147483647])
  assert_eq(big.sum(), @types.Scalar::Int(6442450941))
}

// ── to_builtin (lossless widening + equivalence) ──────────────────────

///|
test "to_builtin: equals BuiltinColumn::from_ints (the bitmap alloc avoided)" {
  let xs : Array[Int64] = [3, 1, 4, 1, 5]
  let widened = NumericColumn::from_int64s(xs).to_builtin()
  // The numeric column carried no bitmap; widening materialises exactly the
  // all-valid Builtin column — and `derive(Eq)` proves it cell-for-cell.
  assert_eq(widened, BuiltinColumn::from_ints(xs))
  assert_eq(widened.dtype(), @types.DataType::Int)
  assert_eq(widened.null_count(), 0)
}

///|
test "sum equals the widened BuiltinColumn's reduction (cross-check)" {
  // The numeric fast path must agree value-for-value with reducing the
  // materialised Builtin column over its valid cells.
  let xs : Array[Int64] = [5, -3, 8, 0, 12]
  let numeric_sum = NumericColumn::from_int64s(xs).sum()
  let widened = NumericColumn::from_int64s(xs).to_builtin()
  let (data, validity) = widened.int_values()
  let valid = validity.to_bools()
  let mut acc : Int64 = 0
  for i in 0..<data.length() {
    if valid[i] {
      acc = acc + data[i]
    }
  }
  assert_eq(numeric_sum, @types.Scalar::Int(acc))
}

// ── Eq derive ─────────────────────────────────────────────────────────

///|
test "Eq derive" {
  let a = NumericColumn::from_int64s([1, 2])
  assert_eq(a, NumericColumn::from_int64s([1, 2]))
  assert_not_eq(a, NumericColumn::from_int64s([1, 3]))
}
