// Coverage pins for the reshape's last arms: the typed row projection's
// off-dtype null (frame's own file), the predicate pass' temporal
// crossing refusals, and the group key's value-fence gate.

///|
test "a decimal-typed row build answers its null and refusal shapes" {
  // A Null row cell under a Decimal field projects as the column's own
  // null; an Int cell reaches the projection's off-dtype screen and
  // refuses with the expected-dtype mismatch.
  let df = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("d", @types.DataType::Decimal)]),
    [
      [@types.Scalar::Decimal(@types.Dec128::of_int64(1L))],
      [@types.Scalar::Null],
    ],
  )
  assert_true(df.item(0, "d") is @types.Scalar::Decimal(_))
  assert_true(df.item(1, "d") is @types.Scalar::Null)
  assert_true(
    (Ok(
      ignore(
        DataFrame::from_rows(
          @types.Schema::Schema([
            @types.Field::Field("d", @types.DataType::Decimal),
          ]),
          [[@types.Scalar::Int(2)]],
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a temporal predicate stays above the stage it refuses on" {
  // The predicate itself shifts temporal cells: it stays put through
  // the place-filter's value-raise arm.
  let df = DataFrame::DataFrame([
    @series.Series::from_timestamp_options("ts", [
      Some(0L),
      Some(9_223_372_036_854_775_807L),
    ]),
  ])
  let predicate = (@expr.col("ts") + @expr.lit(@types.Scalar::Duration(1L))).gt(
    @expr.col("ts"),
  )
  let plan = LazyFrame::LazyFrame(df).filter(predicate)
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "a group key the value fence refuses keeps the aggregate in place" {
  // A key expression the temporal fence refuses on values (a shift)
  // keeps the group filter above the aggregation through the key-gate
  // arm.
  let df = DataFrame::DataFrame([
    @series.Series::from_strings("k", ["a", "b"]),
    @series.Series::from_timestamp_options("ts", [
      Some(0L),
      Some(9_223_372_036_854_775_807L),
    ]),
  ])
  // The shifted key refuses at collect on the extreme instant — the
  // key-gate arm keeps the filter above the aggregation, so the lazy
  // plan raises the same refusal the eager one does (the
  // error-faithfulness parity the fence exists to keep).
  let shifted = (@expr.col("ts") + @expr.lit(@types.Scalar::Duration(1L))).with_alias(
    "shifted",
  )
  let plan = LazyFrame::LazyFrame(df)
    .group_by([shifted])
    .agg([@expr.col("k").count().with_alias("n")])
    .filter(@expr.col("n").gt(@expr.lit_int(0)))
  assert_true(
    (Ok(ignore(plan.collect())) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a join whose keys shift temporal cells keeps the predicate above" {
  // The join-split gate's value-fence arm: a key expression the
  // temporal fence refuses on values (a shift) keeps the predicate
  // from sinking into either side.
  let l = DataFrame::DataFrame([
    @series.Series::from_strings("k", ["a", "b"]),
    @series.Series::from_timestamp_options("ts", [
      Some(0L),
      Some(9_223_372_036_854_775_807L),
    ]),
  ])
  let r = DataFrame::DataFrame([
    @series.Series::from_strings("k", ["a", "b"]),
    @series.Series::from_ints("w", [1, 2]),
  ])
  let shifted = (@expr.col("ts") + @expr.lit(@types.Scalar::Duration(1L))).with_alias(
    "shifted",
  )
  let predicate = @expr.col("w").gt(@expr.lit_int(0))
  let plan = LazyFrame::LazyFrame(l)
    .join(LazyFrame::LazyFrame(r), JoinOptions::on([shifted]))
    .filter(predicate)
  // The shifted key refuses at collect on the extreme instant — the
  // key-gate arm keeps the predicate above the join, so the lazy plan
  // raises the same refusal the eager one does.
  assert_true(
    (Ok(ignore(plan.collect())) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
