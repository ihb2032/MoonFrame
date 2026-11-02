// Blackbox tests for the `dt_*` verbs — a `Date` or `Timestamp` column's
// calendar components and a `Timestamp` column's clock components,
// evaluated through `select`. Pinned: the epoch anchors (day 0 is
// 1970-01-01, a Thursday; day 11016 is 2000-02-29, a Tuesday — the
// leap-day the calendar math must thread), dates before 1970, null cells,
// the temporal-pair dtype gate of the calendar verbs, and the
// Timestamp-only gate of the clock verbs.

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
test "the dt calendar verbs take a Date or Timestamp only" {
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

///|
test "the calendar verbs read a Timestamp's date half" {
  // 2024-01-01T00:00:00 (a Monday) and 2024-01-02T15:04:20 — the clock
  // half must not leak into the calendar components.
  let df = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("t", @types.DataType::Timestamp)]),
    [
      [@types.Scalar::Timestamp(1_704_067_200_000_000L)],
      [@types.Scalar::Timestamp(1_704_153_860_000_000L)],
      [@types.Scalar::Null],
    ],
  )
  assert_eq(
    df.select([@expr.col("t").dt_year()]).get_column("t").to_scalars(),
    [@types.Scalar::Int(2024), @types.Scalar::Int(2024), @types.Scalar::Null],
  )
  assert_eq(
    df.select([@expr.col("t").dt_month()]).get_column("t").to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Int(1), @types.Scalar::Null],
  )
  assert_eq(df.select([@expr.col("t").dt_day()]).get_column("t").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Null,
  ])
  // 2024-01-01 is a Monday (ISO 1); 2024-01-02 a Tuesday (2).
  assert_eq(
    df.select([@expr.col("t").dt_day_of_week()]).get_column("t").to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Int(2), @types.Scalar::Null],
  )
}

///|
test "the dt clock verbs read back the six fraction digits" {
  // 2024-01-01T15:04:20.123456 and one microsecond before the epoch —
  // the pre-epoch instant's clock reads 23:59:59.999999, not -1.
  let df = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("t", @types.DataType::Timestamp)]),
    [
      [@types.Scalar::Timestamp(1_704_121_460_123_456L)],
      [@types.Scalar::Timestamp(-1L)],
      [@types.Scalar::Null],
    ],
  )
  assert_eq(
    df.select([@expr.col("t").dt_hour()]).get_column("t").to_scalars(),
    [@types.Scalar::Int(15), @types.Scalar::Int(23), @types.Scalar::Null],
  )
  assert_eq(
    df.select([@expr.col("t").dt_minute()]).get_column("t").to_scalars(),
    [@types.Scalar::Int(4), @types.Scalar::Int(59), @types.Scalar::Null],
  )
  assert_eq(
    df.select([@expr.col("t").dt_second()]).get_column("t").to_scalars(),
    [@types.Scalar::Int(20), @types.Scalar::Int(59), @types.Scalar::Null],
  )
  assert_eq(
    df.select([@expr.col("t").dt_microsecond()]).get_column("t").to_scalars(),
    [
      @types.Scalar::Int(123456),
      @types.Scalar::Int(999999),
      @types.Scalar::Null,
    ],
  )
}

///|
test "the dt clock verbs are Timestamp-only" {
  let dates = dates_df()
  assert_true(
    (Ok(dates.select([@expr.col("d").dt_hour()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  let ints = DataFrame::DataFrame([Series::from_ints("i", [1])])
  assert_true(
    (Ok(ints.select([@expr.col("i").dt_microsecond()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "the calendar verbs answer at the Int64 day-count extremes" {
  // The civil conversion is total over every `Int64` (the era arithmetic
  // takes its remainder first and never forms `days + 719468`), so the
  // component verbs read back exactly what the cell's own ISO rendering
  // shows — here the far end of the range, where an earlier domain gate
  // used to refuse; weekday's pure modular arithmetic answers for any
  // count (Int64::MAX mod 7 is 0 — a Thursday, like the epoch).
  let hostile = DataFrame::DataFrame([
    Series::from_scalars(
      "d",
      [@types.Scalar::Date(9223372036854775807L)],
      dtype=@types.DataType::Date,
    ),
  ])
  assert_eq(
    hostile
    .select([@expr.col("d").dt_year().with_alias("y")])
    .get_column("y")
    .to_scalars(),
    [@types.Scalar::Int(25252734927768524L)],
  )
  assert_eq(
    hostile
    .select([@expr.col("d").dt_month().with_alias("m")])
    .get_column("m")
    .to_scalars(),
    [@types.Scalar::Int(7)],
  )
  assert_eq(
    hostile
    .select([@expr.col("d").dt_day().with_alias("dd")])
    .get_column("dd")
    .to_scalars(),
    [@types.Scalar::Int(27)],
  )
  assert_eq(
    hostile
    .select([@expr.col("d").dt_day_of_week()])
    .get_column("d")
    .to_scalars(),
    [@types.Scalar::Int(4)],
  )
}
