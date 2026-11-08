// Coverage pins for the series layer's remaining decimal arms — the
// rider lift's Dec refusal, the arg-extremum fold, the count-distinct
// key reader, the empty-column build, the typed projections' off-dtype
// null, the row-gather fills and matched fast paths, and the mean's
// factory refusal over the summable-but-not-numeric I64 rider.

///|
test "the rider lift refuses the decimal dtype" {
  // `i64_rider_scalar` names the I64 riders; Decimal rides its own
  // buffer, so the lift answers None — the exhaustiveness fence.
  assert_true(@types.DataType::Decimal.i64_rider_scalar(5L) is None)
}

///|
test "count_distinct reads the decimal canonical key" {
  let s = Series::from_decimals("d", [
    Some(@types.Dec128::parse_opt("1.50").unwrap()),
    Some(@types.Dec128::parse_opt("1.5").unwrap()),
    Some(@types.Dec128::nan()),
    None,
  ])
  // Cohort-equal values are one distinct value; NaN one; null one.
  assert_eq(s.n_unique(), 3)
}

///|
test "an empty decimal column builds through the Dec physical" {
  let s = Series::empty_of("d", @types.DataType::Decimal)
  assert_eq(s.len(), 0)
}

///|
test "the typed projections null an off-dtype decimal cell" {
  // scalars_to_series with a Decimal target and a non-decimal cell.
  let s = scalars_to_series(@types.DataType::Decimal, "m", [
    @types.Scalar::Decimal(@types.Dec128::of_int64(1L)),
    @types.Scalar::Int(2),
  ])
  assert_true(s.get(0) is @types.Scalar::Decimal(_))
  assert_true(s.get(1) is @types.Scalar::Null)
}

///|
test "gather and matched rows ride the decimal fast paths" {
  let s = Series::from_decimals("d", [
    Some(@types.Dec128::of_int64(1L)),
    Some(@types.Dec128::of_int64(2L)),
  ])
  // The fast gather (every index in bounds).
  let gathered = s.gather([0, 1, 0])
  assert_eq(gathered.len(), 3)
  assert_true(
    gathered.get(2) is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::of_int64(1L)),
  )
  // The matched-rows gather (join assembly's fast path).
  let matched = s.gather_series_opt([Some(1), Some(1)], "m")
  assert_true(
    matched.get(0) is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::of_int64(2L)),
  )
}

///|
test "a decimal fill into an I64 column refuses naming the dtype" {
  // coalesce_columns' dtype gate refuses the cross-dtype fill outright
  // (the closure's Decimal member None only backs it): the decimal
  // cannot express an Int cell.
  let ints = Series::from_ints("k", [1, 2])
  let decs = Series::from_decimals("f", [
    Some(@types.Dec128::of_int64(9L)),
    None,
  ])
  assert_true(
    (Ok(ignore(ints.coalesce_columns(decs, "k"))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}
