// The `dt_*` expression verbs — a `Date` or `Timestamp` column's calendar
// components, read through the value-type layer's one calendar math
// (`date_days_to_civil` and `timestamp_micros_to_day`, which the ISO
// renderings also compose, so the string a cell shows and the components
// the verbs extract cannot disagree). The calendar verbs (`dt_year` ..
// `dt_day_of_week`) read a `Date` cell's day count directly and a
// `Timestamp` cell's date half through the day floor; the clock verbs
// (`dt_hour` .. `dt_microsecond`) are `Timestamp`-only (a `Date` names no
// time of day). Any other dtype is `TypeMismatch`; every verb keeps null
// cells null and emits an `Int` column. The calendar math is total and
// correct over every `Int64` (its era arithmetic takes the remainder first
// and never forms `days + 719468`), so the verbs answer for any count a
// cell can carry — no domain gate stands between a cell and the components
// its own rendering shows.

///|
/// The calendar fold: map each cell through `read` — a `Date` cell's day
/// count, a `Timestamp` cell's date half (the day floor of its microsecond
/// count) — keeping nulls and rejecting every dtype outside the temporal
/// pair up front.
fn eval_dt_date_component(
  operand : Series,
  read : (Int64) -> Int64 raise @types.DataError,
) -> Series raise @types.DataError {
  let dtype = operand.dtype()
  if dtype != @types.DataType::Date && dtype != @types.DataType::Timestamp {
    raise @types.DataError::TypeMismatch(
      @types.TypeMismatchDetail::Message(
        "dt component requires a Date or Timestamp operand, got \{dtype}",
      ),
    )
  }
  let name = operand.name()
  let out : Array[Int64?] = []
  for cell in operand.to_scalars() {
    match cell {
      @types.Scalar::Date(days) => out.push(Some(read(days)))
      @types.Scalar::Timestamp(micros) =>
        out.push(Some(read(@types.timestamp_micros_to_day(micros).0)))
      // The dtype gate leaves only the two temporal cells present and
      // `Null` cells missing — the null stays null.
      _ => out.push(None)
    }
  }
  @series.Series::from_int_options(name, out)
}

///|
/// The clock fold: map each `Timestamp` cell's within-day microsecond
/// count (the `[0, 86_400_000_000)` remainder of the day floor) through
/// `read`, keeping nulls and rejecting every non-`Timestamp` dtype up
/// front — a `Date` names no time of day.
fn eval_dt_clock_component(
  operand : Series,
  read : (Int64) -> Int64 raise @types.DataError,
) -> Series raise @types.DataError {
  if operand.dtype() != @types.DataType::Timestamp {
    raise @types.DataError::TypeMismatch(
      @types.TypeMismatchDetail::Message(
        "dt clock component requires a Timestamp operand, got \{operand.dtype()}",
      ),
    )
  }
  let name = operand.name()
  let out : Array[Int64?] = []
  for cell in operand.to_scalars() {
    match cell {
      @types.Scalar::Timestamp(micros) =>
        out.push(Some(read(@types.timestamp_micros_to_day(micros).1)))
      _ => out.push(None)
    }
  }
  @series.Series::from_int_options(name, out)
}

///|
/// The calendar year of each `Date` or `Timestamp` cell.
fn eval_dt_year(operand : Series) -> Series raise @types.DataError {
  eval_dt_date_component(operand, days => {
    let (year, _, _) = @types.date_days_to_civil(days)
    year
  })
}

///|
/// The calendar month, `1`–`12`.
fn eval_dt_month(operand : Series) -> Series raise @types.DataError {
  eval_dt_date_component(operand, days => {
    let (_, month, _) = @types.date_days_to_civil(days)
    month
  })
}

///|
/// The day of the month, `1`–`31`.
fn eval_dt_day(operand : Series) -> Series raise @types.DataError {
  eval_dt_date_component(operand, days => {
    let (_, _, day) = @types.date_days_to_civil(days)
    day
  })
}

///|
/// The ISO weekday — Monday `1` through Sunday `7`.
/// The epoch itself is a Thursday (`4`), and the modular arithmetic floors,
/// so dates before 1970 land on the right day too; a `Timestamp` reads its
/// date half's day count.
fn eval_dt_weekday(operand : Series) -> Series raise @types.DataError {
  eval_dt_date_component(operand, days => (days % 7L + 10L) % 7L + 1L)
}

///|
/// The hour of the day, `0`–`23` — `Timestamp` only.
fn eval_dt_hour(operand : Series) -> Series raise @types.DataError {
  eval_dt_clock_component(operand, rem => @types.day_micros_to_clock(rem).0)
}

///|
/// The minute of the hour, `0`–`59` — `Timestamp` only.
fn eval_dt_minute(operand : Series) -> Series raise @types.DataError {
  eval_dt_clock_component(operand, rem => @types.day_micros_to_clock(rem).1)
}

///|
/// The second of the minute, `0`–`59` — `Timestamp` only.
fn eval_dt_second(operand : Series) -> Series raise @types.DataError {
  eval_dt_clock_component(operand, rem => @types.day_micros_to_clock(rem).2)
}

///|
/// The microsecond of the second, `0`–`999999` — `Timestamp` only. Together
/// with `dt_second` / `dt_minute` / `dt_hour` it reads back exactly the six
/// fraction digits a `Timestamp` cell's own rendering shows.
fn eval_dt_microsecond(operand : Series) -> Series raise @types.DataError {
  eval_dt_clock_component(operand, rem => @types.day_micros_to_clock(rem).3)
}
