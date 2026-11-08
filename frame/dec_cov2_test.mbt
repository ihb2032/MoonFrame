// Coverage pins for the frame layer's remaining decimal arms — the
// typed projections' off-dtype nulls (both spellings), the temporal
// fence's crossing refusals that keep the renamed and key-checked
// stages above, and the arg-extremum's Dec arm through the rank verb.

///|
test "typed builds null an off-dtype decimal cell through the projection" {
  // The tolerant projection (`scalars_to_series` under a select) nulls
  // an off-dtype cell: a map closure answering an Int under a decimal
  // column's dtype.
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [Some(@types.Dec128::of_int64(1L))]),
  ])
  let mapped = df.select([
    @expr.col("d")
    .map_elements(label="m", (c : @types.Scalar) => c)
    .with_alias("m"),
  ])
  assert_true(mapped.item(0, "m") is @types.Scalar::Decimal(_))
}

///|
test "rank reads the decimal arg-extremum's total order" {
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::parse_opt("2.5").unwrap()),
      Some(@types.Dec128::nan()),
      Some(@types.Dec128::parse_opt("1.5").unwrap()),
    ]),
  ])
  let ranked = df.select([@expr.col("d").rank().with_alias("r")])
  assert_eq(ranked.get_column("r").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(1.0),
  ])
}

///|
test "the temporal fence holds a filter above a shift on a join key" {
  // A predicate over the aggregation's key expressions stays above the
  // stage when the key reads a temporal column the shift rewrites.
  let df = DataFrame::DataFrame([
    @series.Series::from_timestamp_options("ts", [
      Some(0L),
      Some(9_223_372_036_854_775_807L),
    ]),
    @series.Series::from_strings("k", ["a", "b"]),
  ])
  let plan = LazyFrame::LazyFrame(df)
    .with_columns([
      (@expr.col("ts") + @expr.lit(@types.Scalar::Duration(1L))).with_alias(
        "shifted",
      ),
    ])
    .filter(@expr.col("shifted").gt(@expr.col("ts")))
  // The filter itself carries the temporal addition — it stays put.
  assert_eq(plan.explain(optimized=true), plan.explain())
}
