// Coverage pins for the series layer's remaining decimal arms, through
// the package's own spellings: the typed projection's off-dtype null,
// the mean factory's refusal over the Dec buffer, the arg-extremum Dec
// fold, and the mislabeled dtype-vs-buffer shape a hand-built column
// produces (the arithmetic's cell reader reads the buffer the column
// actually holds).

///|
test "the typed projection nulls an off-dtype decimal cell" {
  let s = scalars_to_series(@types.DataType::Decimal, "m", [
    @types.Scalar::Decimal(@types.Dec128::of_int64(1L)),
    @types.Scalar::Int(2),
  ])
  assert_true(s.get(0) is @types.Scalar::Decimal(_))
  assert_true(s.get(1) is @types.Scalar::Null)
}

///|
test "the mean factory refuses over the Dec buffer" {
  let s = Series::from_decimals("d", [Some(@types.Dec128::of_int64(1L))])
  assert_true(
    (Ok(ignore(s.mean())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "the arg-extremum Dec fold reads the total order" {
  // Through the reducer factory the window verbs use: ArgMin / ArgMax
  // over a decimal column name the extremum's window-local offset.
  let s = Series::from_decimals("d", [
    Some(@types.Dec128::parse_opt("2.5").unwrap()),
    Some(@types.Dec128::nan()),
    Some(@types.Dec128::parse_opt("1.5").unwrap()),
  ])
  let lo = (s.reducer_for(ReduceOp::ArgMin).0)(3, i => i)
  assert_eq(lo, @types.Scalar::Int(2L))
  let hi = (s.reducer_for(ReduceOp::ArgMax).0)(3, i => i)
  assert_eq(hi, @types.Scalar::Int(0L))
}
