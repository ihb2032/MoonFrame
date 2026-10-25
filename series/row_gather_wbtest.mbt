// The coalesce gate's own battery: `Series::coalesce_columns` is a hidden
// engine seam, so the mismatch its dtype gate refuses compiles inside the
// package rather than beside it. The equal-dtype path is the join's, pinned
// by the join blackbox suite.

///|
test "coalesce_columns refuses a fill of another dtype" {
  // The merge reads `fill`'s raw I64 cells through `base`'s buffer, so a
  // dtype mismatch would re-type them silently — a decimal fill even
  // discards its scale. The gate makes the caller's precondition a checked
  // one.
  let base = Series::from_decimal_options(2, "k", [Some(5L), None])
  let off_scale = Series::from_decimal_options(3, "f", [Some(500L), None])
  let mismatch = Ok(base.coalesce_columns(off_scale, "k")) catch { e => Err(e) }
  assert_true(mismatch is Err(@types.DataError::TypeMismatch(_)))
  let wrong_variant = Series::from_ints("f", [1, 2])
  let retyped = Ok(base.coalesce_columns(wrong_variant, "k")) catch {
    e => Err(e)
  }
  assert_true(retyped is Err(@types.DataError::TypeMismatch(_)))
  // The equal-dtype merge itself is unchanged.
  let fill = Series::from_decimal_options(2, "f", [Some(500L), Some(7L)])
  let merged = base.coalesce_columns(fill, "k")
  assert_eq(merged.to_scalars(), [
    @types.Scalar::Decimal(2, 5L),
    @types.Scalar::Decimal(2, 7L),
  ])
}
