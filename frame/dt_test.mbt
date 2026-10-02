// Blackbox tests for the `dt_*` verbs — a `Date` column's calendar
// components, evaluated through `select`. Pinned: the epoch anchors (day 0
// is 1970-01-01, a Thursday; day 11016 is 2000-02-29, a Tuesday — the
// leap-day the calendar math must thread), dates before 1970, null cells,
// and the Date-only dtype gate.

///|
fn dates_df() -> DataFrame raise @types.DataError {
  // Day 0 (1970-01-01, Thursday), day 11016 (2000-02-29, Tuesday), a null,
  // and day -1 (1969-12-31, Wednesday) — the pre-epoch anchor.
  DataFrame::DataFrame([
    Series::from_scalars(
      "d",
      [
        @types.Scalar::Date(0L),
        @types.Scalar::Date(11016L),
        @types.Scalar::Null,
        @types.Scalar::Date(-1L),
      ],
      dtype=@types.DataType::Date,
    ),
  ])
}

///|
test "dt_year / dt_month / dt_day read what the cell displays" {
  let df = dates_df()
  assert_eq(
    df.select([@expr.col("d").dt_year()]).get_column("d").to_scalars(),
    [
      @types.Scalar::Int(1970),
      @types.Scalar::Int(2000),
      @types.Scalar::Null,
      @types.Scalar::Int(1969),
    ],
  )
  assert_eq(
    df.select([@expr.col("d").dt_month()]).get_column("d").to_scalars(),
    [
      @types.Scalar::Int(1),
      @types.Scalar::Int(2),
      @types.Scalar::Null,
      @types.Scalar::Int(12),
    ],
  )
  assert_eq(df.select([@expr.col("d").dt_day()]).get_column("d").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(29),
    @types.Scalar::Null,
    @types.Scalar::Int(31),
  ])
}

///|
test "dt_day_of_week is ISO: Monday 1 through Sunday 7" {
  assert_eq(
    dates_df()
    .select([@expr.col("d").dt_day_of_week()])
    .get_column("d")
    .to_scalars(),
    [
      @types.Scalar::Int(4), // 1970-01-01, a Thursday
      @types.Scalar::Int(2), // 2000-02-29, a Tuesday
      @types.Scalar::Null,
      @types.Scalar::Int(3), // 1969-12-31, a Wednesday
    ],
  )
}

///|
test "the dt verbs are Date-only" {
  let ints = DataFrame::DataFrame([Series::from_ints("i", [1])])
  assert_true(
    (Ok(ints.select([@expr.col("i").dt_year()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  let strings = DataFrame::DataFrame([Series::from_strings("s", ["a"])])
  assert_true(
    (Ok(strings.select([@expr.col("s").dt_day()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}
