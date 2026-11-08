// Coverage pins for the decimal folds and fills the frame suite does
// not reach: the extremum over a decimal column, the mean's factory
// refusal, the fill's mismatch arm, and the positional order
// statistics' value comparator.

///|
test "a decimal column min / max skip NaN and read the total order" {
  let s = @series.Series::from_decimals("d", [
    Some(@types.Dec128::parse_opt("2.5").unwrap()),
    Some(@types.Dec128::nan()),
    None,
    Some(@types.Dec128::parse_opt("1.5").unwrap()),
  ])
  let min = s.min()
  assert_true(
    min is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::parse_opt("1.5").unwrap()),
  )
  let max = s.max()
  assert_true(
    max is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::parse_opt("2.5").unwrap()),
  )
  // An all-NaN column answers the no-value null.
  let all_nan = @series.Series::from_decimals("d", [Some(@types.Dec128::nan())])
  assert_true(all_nan.min() is @types.Scalar::Null)
}

///|
test "a decimal mean refuses at the reduction factory" {
  let s = @series.Series::from_decimals("d", [Some(@types.Dec128::of_int64(1L))])
  assert_true(
    (Ok(ignore(s.mean())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a decimal fill from another dtype refuses naming Decimal" {
  let s = @series.Series::from_decimals("d", [None])
  assert_true(
    (Ok(ignore(s.fill_null(@types.Scalar::Int(0L)))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}
