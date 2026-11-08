// Whitebox coverage pins for the series layer's last decimal arms —
// the mislabeled dtype-vs-buffer fill refusal and the tolerant typed
// projection's off-dtype null, both reachable only through shapes the
// public constructors refuse but the in-package seams spell.

///|
test "a mislabeled Decimal dtype over an I64 buffer refuses the fill" {
  // The old fixed-point rider's shape: a Decimal dtype over an I64
  // buffer (Series::from_i64_options authors it). The Decimal fill
  // value matches the dtype, so the arm's own buffer guard refuses.
  let mis = Series::from_i64_options("d", @types.DataType::Decimal, [
    None,
    Some(5L),
  ])
  assert_true(
    (Ok(ignore(mis.fill_null(@types.Scalar::Decimal(@types.Dec128::zero())))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "the tolerant typed projections null an off-dtype decimal cell" {
  // The shared projection the reducers ride (`scalars_to_series`)
  // nulls the off-dtype minority; the constructor's own spelling
  // refuses it outright.
  let r = scalars_to_series(@types.DataType::Decimal, "m", [
    @types.Scalar::Decimal(@types.Dec128::of_int64(1L)),
    @types.Scalar::Int(2),
  ])
  assert_true(r.get(0) is @types.Scalar::Decimal(_))
  assert_true(r.get(1) is @types.Scalar::Null)
}
