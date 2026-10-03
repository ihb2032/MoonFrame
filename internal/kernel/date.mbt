// The `dt_*` expression verbs — a `Date` column's calendar components,
// read through the value-type layer's one calendar math
// (`date_days_to_civil`, which the ISO rendering also composes, so the
// string a cell shows and the components the verbs extract cannot
// disagree). Every verb is `Date`-only (any other dtype is
// `TypeMismatch`), keeps null cells null, and emits an `Int` column.

///|
/// The shared fold: map each cell through `read` — a `Date` cell's day
/// count to its component — keeping nulls and rejecting every non-`Date`
/// dtype up front.
fn eval_dt_component(
  operand : Series,
  read : (Int64) -> Int64 raise @types.DataError,
) -> Series raise @types.DataError {
  if operand.dtype() != @types.DataType::Date {
    raise @types.DataError::TypeMismatch(
      @types.TypeMismatchDetail::Message(
        "dt component requires a Date operand, got \{operand.dtype()}",
      ),
    )
  }
  let name = operand.name()
  let out : Array[Int64?] = []
  for cell in operand.to_scalars() {
    match cell {
      @types.Scalar::Date(days) => out.push(Some(read(days)))
      // The dtype gate leaves only `Date` cells present and `Null` cells
      // missing — the null stays null.
      _ => out.push(None)
    }
  }
  @series.Series::from_int_options(name, out)
}

///|
/// The day counts the civil calendar conversion can name:
/// `date_days_to_civil` shifts by `719468` before its era arithmetic, and
/// a count whose magnitude leaves that shift no headroom wraps silently —
/// a wrong year with no error signal. The component verbs raise instead.
/// (The ISO rendering stays total over every `Int64` — display, not data
/// processing; and `weekday`'s pure modular arithmetic never wraps, so it
/// answers for any count.)
fn check_calendar_domain(days : Int64) -> Int64 raise @types.DataError {
  let limit = 9223372036854775807L - 719468L
  if days > limit || days < -limit {
    raise @types.DataError::InvalidOperation(
      "Date day count \{days} lies outside the calendar domain",
    )
  }
  days
}

///|
/// The calendar year of each `Date` cell (Polars' `dt.year`).
pub fn eval_dt_year(operand : Series) -> Series raise @types.DataError {
  eval_dt_component(operand, days => {
    let (year, _, _) = @types.date_days_to_civil(check_calendar_domain(days))
    year
  })
}

///|
/// The calendar month, `1`–`12` (Polars' `dt.month`).
pub fn eval_dt_month(operand : Series) -> Series raise @types.DataError {
  eval_dt_component(operand, days => {
    let (_, month, _) = @types.date_days_to_civil(check_calendar_domain(days))
    month
  })
}

///|
/// The day of the month, `1`–`31` (Polars' `dt.day`).
pub fn eval_dt_day(operand : Series) -> Series raise @types.DataError {
  eval_dt_component(operand, days => {
    let (_, _, day) = @types.date_days_to_civil(check_calendar_domain(days))
    day
  })
}

///|
/// The ISO weekday — Monday `1` through Sunday `7` (Polars' `dt.weekday`).
/// The epoch itself is a Thursday (`4`), and the modular arithmetic floors,
/// so dates before 1970 land on the right day too.
pub fn eval_dt_weekday(operand : Series) -> Series raise @types.DataError {
  eval_dt_component(operand, days => (days % 7L + 10L) % 7L + 1L)
}
