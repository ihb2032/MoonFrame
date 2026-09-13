// Whitebox tests for `NumericColumn`'s reduction fast path (the folds in
// `numeric_reduce.mbt`). Reductions inherit the library's Polars-aligned NaN
// semantics: `NaN` propagates through `sum` / `mean` (it is a value, not
// missing) but is skipped by `min` / `max` (treated as missing, like `sort`).

// ── Reductions: sum (all-valid fast path) ─────────────────────────────

///|
test "sum: folds raw array per dtype, total, identity on empty" {
  assert_eq(
    NumericColumn::from_ints([1, 2, 3, 4]).sum(),
    @types.Scalar::Int(10),
  )
  // Empty → additive identity, no raise (unlike Series::sum on non-numeric).
  assert_eq(NumericColumn::from_ints([]).sum(), @types.Scalar::Int(0))
  // Accumulates in Int64 — a sum past the 32-bit ceiling does not overflow.
  assert_eq(
    NumericColumn::from_ints([2147483647, 2147483647, 2147483647]).sum(),
    @types.Scalar::Int(6442450941),
  )
  assert_eq(
    NumericColumn::from_floats([1.5, 2.5, 4.0]).sum(),
    @types.Scalar::Float(8.0),
  )
  assert_eq(NumericColumn::from_floats([]).sum(), @types.Scalar::Float(0.0))
}

///|
test "sum: Float NaN propagates (NaN is a value, not missing)" {
  let nan : Double = @double.not_a_number
  match NumericColumn::from_floats([1.0, nan, 2.0]).sum() {
    @types.Scalar::Float(v) => assert_true(v.is_nan())
    _ => assert_true(false)
  }
}

///|
test "sum equals the widened BuiltinColumn's reduction (cross-check)" {
  // The numeric fast path must agree value-for-value with reducing the
  // materialised Builtin column over its valid cells.
  let xs : Array[Int64] = [5, -3, 8, 0, 12]
  let numeric_sum = NumericColumn::from_ints(xs).sum()
  let (data, validity) = int_cells(NumericColumn::from_ints(xs).to_builtin())
  let valid = validity.to_bools()
  let mut acc : Int64 = 0
  for i in 0..<data.length() {
    if valid[i] {
      acc = acc + data[i]
    }
  }
  assert_eq(numeric_sum, @types.Scalar::Int(acc))
}

// ── Reductions: mean (raises on empty) ────────────────────────────────

///|
test "mean: arithmetic mean per dtype, as Double" {
  assert_eq(NumericColumn::from_ints([1, 2, 3]).mean(), 2.0)
  assert_eq(NumericColumn::from_ints([2, 4]).mean(), 3.0)
  assert_eq(NumericColumn::from_floats([1.0, 2.0, 6.0]).mean(), 3.0)
}

///|
test "mean: large Int64 values accumulate in Double, no Int64 wrap" {
  // 2^62 + 2^62 = 2^63 wraps an Int64 accumulator to Int64::MIN; the mean must
  // remain 2^62 rather than flipping negative.
  let two_62 : Int64 = 4611686018427387904
  assert_eq(
    NumericColumn::from_ints([two_62, two_62]).mean(),
    two_62.to_double(),
  )
}

///|
test "mean: empty column raises InvalidOperation (0/0 is undefined)" {
  assert_eq(
    Ok(NumericColumn::from_ints([]).mean()) catch {
      e => Err(e)
    },
    Err(@types.DataError::InvalidOperation("mean of empty column")),
  )
  assert_eq(
    Ok(NumericColumn::from_floats([]).mean()) catch {
      e => Err(e)
    },
    Err(@types.DataError::InvalidOperation("mean of empty column")),
  )
}

///|
test "mean: Float NaN propagates to a NaN mean" {
  let nan : Double = @double.not_a_number
  assert_true(NumericColumn::from_floats([1.0, nan]).mean().is_nan())
}

// ── Reductions: min / max (skip NaN, total) ───────────────

///|
test "min / max: Int, both fold branches, empty → Null" {
  let col = NumericColumn::from_ints([3, 1, 2])
  // min: None→Some(3); 1<3 replaces; 2<1 keeps — exercises both fold arms.
  assert_eq(col.min(), @types.Scalar::Int(1))
  assert_eq(col.max(), @types.Scalar::Int(3))
  // Empty column → Null on both reductions.
  assert_eq(NumericColumn::from_ints([]).min(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_ints([]).max(), @types.Scalar::Null)
}

///|
test "min / max: Float skips NaN, all-NaN / empty → Null" {
  let nan : Double = @double.not_a_number
  let col = NumericColumn::from_floats([3.0, nan, 1.0, 2.0])
  // NaN is skipped (treated as missing), unlike sum / mean where it
  // propagates — exactly Polars' regular min / max.
  assert_eq(col.min(), @types.Scalar::Float(1.0))
  assert_eq(col.max(), @types.Scalar::Float(3.0))
  // Every cell skipped → Null (all-NaN, and empty).
  assert_eq(NumericColumn::from_floats([nan, nan]).min(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_floats([nan, nan]).max(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_floats([]).min(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_floats([]).max(), @types.Scalar::Null)
}
