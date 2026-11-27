// What a numeric column's display format makes of its cells: a number, a
// count of days since 1960-01-01, a count of seconds since midnight, or
// a count of seconds since 1960-01-01 — and the one conversion each goes
// through to the library's day and microsecond counts.

///|
/// What a display format makes of a numeric column's cells.
priv enum Family {
  Number
  Days
  Clock
  Instant
}

///|
/// The date formats: each prints a date value, a count of days since
/// 1960-01-01. Matched exactly, as the file spells the name.
let date_formats : ReadOnlyArray[String] = [
  "B8601DA", "DATE", "DAY", "DDMMYY", "DDMMYYB", "DDMMYYC", "DDMMYYD", "DDMMYYN",
  "DDMMYYP", "DDMMYYS", "DOWNAME", "E8601DA", "IS8601DA", "JULDAY", "JULIAN", "MINGUO",
  "MMDDYY", "MMDDYYB", "MMDDYYC", "MMDDYYD", "MMDDYYN", "MMDDYYP", "MMDDYYS", "MMYY",
  "MMYYC", "MMYYD", "MMYYN", "MMYYP", "MMYYS", "MONNAME", "MONTH", "MONYY", "NENGO",
  "QTR", "QTRR", "WEEKDATE", "WEEKDATX", "WEEKDAY", "WEEKV", "WORDDATE", "WORDDATX",
  "YEAR", "YYMM", "YYMMC", "YYMMD", "YYMMDDB", "YYMMDDC", "YYMMDDD", "YYMMDDN", "YYMMDDP",
  "YYMMDDS", "YYMMN", "YYMMP", "YYMMS", "YYMON", "YYMMDD", "YYQ", "YYQC", "YYQD",
  "YYQN", "YYQP", "YYQS", "YYQR", "YYQRC", "YYQRD", "YYQRN", "YYQRP", "YYQRS",
]

///|
/// The time formats: each prints a time value, a count of seconds since
/// midnight.
let time_formats : ReadOnlyArray[String] = [
  "B8601TM", "E8601TM", "HHMM", "HOUR", "IS8601TM", "MMSS", "TIME", "TIMEAMPM", "TOD",
]

///|
/// The datetime formats: each prints a datetime value, a count of seconds
/// since 1960-01-01.
let datetime_formats : ReadOnlyArray[String] = [
  "B8601DN", "B8601DT", "B8601DX", "B8601DZ", "B8601LX", "DATEAMPM", "DATETIME",
  "DTDATE", "DTMONYY", "DTWKDATX", "DTYEAR", "E8601DN", "E8601DT", "E8601DX", "E8601DZ",
  "E8601LX", "IS8601DT", "MDYAMPM",
]

///|
/// Whether `names` holds `format`.
fn named(names : ReadOnlyArray[String], format : String) -> Bool {
  let mut found = false
  for name in names {
    if name == format {
      found = true
    }
  }
  found
}

///|
/// The family a display format belongs to: the name exactly as the file
/// spells it, or none.
fn family_of(format : String) -> Family {
  if named(date_formats, format) {
    Family::Days
  } else if named(time_formats, format) {
    Family::Clock
  } else if named(datetime_formats, format) {
    Family::Instant
  } else {
    Family::Number
  }
}

///|
/// Days from 1960-01-01 to 1970-01-01.
const EPOCH_DAYS : Int64 = 3653L

///|
/// Microseconds from 1960-01-01 to 1970-01-01.
const EPOCH_MICROS : Int64 = 315619200000000L

///|
/// The day count of 1 March in the year 4000 and in the year 8000, as the
/// format's calendar counts them: it leaves 29 February out of every
/// year divisible by 4000, so a count that has passed either of these
/// days is one day short of the calendar's date for each.
const SAS_MARCH_4000 : Int64 = 745154L

///|
const SAS_MARCH_8000 : Int64 = 2206123L

///|
/// A day count since 1960-01-01 as the format's calendar spells it, as a
/// day count since 1970-01-01 in the proleptic Gregorian calendar.
fn gregorian_day(day : Int64) -> Int64 {
  let mut days = day
  if day >= SAS_MARCH_4000 {
    days += 1L
  }
  if day >= SAS_MARCH_8000 {
    days += 1L
  }
  days - EPOCH_DAYS
}

///|
/// A date value as a day count since 1970-01-01, when its double is a
/// whole number of days a signed 64-bit count holds; otherwise `Err`.
fn to_day(value : Double) -> Result[Int64, Unit] {
  if value != value.floor() ||
    value > 9000000000000000000.0 ||
    value < -9000000000000000000.0 {
    Err(())
  } else {
    Ok(gregorian_day(value.to_int64()))
  }
}

///|
/// A second count as a microsecond count, when its double spells that
/// count without loss: `value * 10^6` in double arithmetic is a whole
/// number, a signed 64-bit count holds it, and divided by `10^6` again it
/// is the same double. A value with a part below a microsecond that its
/// double can tell from zero fails the last test, so it is `Err`, and no
/// such part is ever rounded away.
fn whole_micros(value : Double) -> Result[Int64, Unit] {
  let scaled = value * 1000000.0
  if scaled != scaled.floor() ||
    scaled > 9000000000000000000.0 ||
    scaled < -9000000000000000000.0 ||
    scaled / 1000000.0 != value {
    Err(())
  } else {
    Ok(scaled.to_int64())
  }
}

///|
/// A datetime value as a microsecond count since 1970-01-01, when its
/// double spells a whole number of microseconds; otherwise `Err`. The
/// two days the format's calendar leaves out are put back.
fn to_instant(value : Double) -> Result[Int64, Unit] {
  let micros = whole_micros(value)
  match micros {
    Err(_) => Err(())
    Ok(count) => {
      let mut total = count
      if value >= SAS_MARCH_4000.to_double() * 86400.0 {
        total += 86400000000L
      }
      if value >= SAS_MARCH_8000.to_double() * 86400.0 {
        total += 86400000000L
      }
      Ok(total - EPOCH_MICROS)
    }
  }
}

///|
/// A numeric column as counts, each present cell through `convert`, when
/// every present cell converts; otherwise `Err`, and the column keeps its
/// numbers.
fn column_values(
  cells : Array[Double?],
  convert : (Double) -> Result[Int64, Unit],
) -> Result[Array[Int64?], Unit] {
  let out : Array[Int64?] = []
  for cell in cells {
    match cell {
      None => out.push(None)
      Some(value) =>
        match convert(value) {
          Ok(count) => out.push(Some(count))
          Err(_) => return Err(())
        }
    }
  }
  Ok(out)
}
