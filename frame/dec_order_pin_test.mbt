// Coverage pin for the positional order statistics' decimal arm —
// rank and sort read the value comparator's Dec variant.

///|
test "a decimal column rides the positional order statistics" {
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::parse_opt("2.5").unwrap()),
      Some(@types.Dec128::parse_opt("1.5").unwrap()),
      Some(@types.Dec128::nan()),
    ]),
  ])
  let ranked = df.select([@expr.col("d").rank().with_alias("r")])
  assert_eq(ranked.get_column("r").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(3.0),
  ])
  let ordered = df.sort([(@expr.col("d"), false, false)])
  assert_true(
    ordered.item(0, "d") is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::parse_opt("1.5").unwrap()),
  )
}
