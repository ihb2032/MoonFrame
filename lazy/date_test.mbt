// The `Date` dtype through the lazy engine: a date literal renders its ISO
// spelling in the plan (the shared literal formatter), and a predicate
// carrying one crosses an aggregate under the same group-cell-stability rule
// as any other literal — the Date arm of that rule is what the registry's
// Date row exercises here.

///|
fn date_df() -> LazyFrame raise @types.DataError {
  let df = @frame.DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("v", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Date(19723L), @types.Scalar::Int(1)],
      [@types.Scalar::Date(19753L), @types.Scalar::Int(2)],
    ],
  )
  LazyFrame::LazyFrame(df)
}

///|
test "a Date literal renders ISO in the plan" {
  let lf = date_df().filter(
    @expr.col("d").gt(@expr.lit(@types.Scalar::Date(19723L))),
  )
  let rendered = lf.explain()
  assert_true(rendered.contains("1970-01-01") == false)
  assert_true(rendered.contains("2024-01-01"))
}

///|
test "a Date literal crosses an aggregate like any other literal" {
  // `lit(Date) < col(d)` reads no column on its literal side and compares
  // date-wise: row-stable and group-cell-stable, so the filter sinks into
  // the aggregate and the collected rows agree with the eager equivalent.
  let plan = date_df()
    .group_by([@expr.col("v")])
    .agg([@expr.col("v").sum().with_alias("total")])
    .filter(
      @expr.lit(@types.Scalar::Date(0L)).lt(@expr.lit(@types.Scalar::Date(9L))),
    )
  let eager = date_df()
    .collect()
    .group_by([@expr.col("v")])
    .agg([@expr.col("v").sum().with_alias("total")])
    .filter(
      @expr.lit(@types.Scalar::Date(0L)).lt(@expr.lit(@types.Scalar::Date(9L))),
    )
  assert_eq(plan.collect().nrows(), eager.nrows())
}
