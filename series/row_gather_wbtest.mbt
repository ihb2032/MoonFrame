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
  let base = Series::from_decimals("k", [
    Some(@types.Dec128::of_int64_scale(5L, scale=2)),
    None,
  ])
  let same_dtype = Series::from_decimals("f", [
    Some(@types.Dec128::of_int64_scale(500L, scale=3)),
    None,
  ])
  let filled = Ok(base.coalesce_columns(same_dtype, "k")) catch { e => Err(e) }
  assert_true(filled is Ok(_))
  let wrong_variant = Series::from_ints("f", [1, 2])
  let retyped = Ok(base.coalesce_columns(wrong_variant, "k")) catch {
    e => Err(e)
  }
  assert_true(retyped is Err(@types.DataError::TypeMismatch(_)))
  // The equal-dtype merge itself is unchanged.
  let fill = Series::from_decimals("f", [
    Some(@types.Dec128::of_int64_scale(500L, scale=2)),
    Some(@types.Dec128::of_int64_scale(7L, scale=2)),
  ])
  let merged = base.coalesce_columns(fill, "k")
  assert_eq(merged.to_scalars(), [
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(5L, scale=2)),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(7L, scale=2)),
  ])
}

///|
test "coalesce_columns refuses a fill shorter than the column" {
  // The equal-length half of the contract, checked like the dtype half: a
  // shorter fill would index past its own cells. Public API (the join
  // assembly) builds equal-length sides, so the branch lives here.
  let base = Series::from_int_options("k", [Some(1), None, Some(3)])
  let short = Series::from_ints("k", [9])
  assert_true(
    (Ok(base.coalesce_columns(short, "k")) catch { e => Err(e) })
    is Err(@types.DataError::LengthMismatch(_, _)),
  )
}
