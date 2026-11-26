// The two facts of an Excel date: the serial number a date is stored as,
// and the number format that says a number is one at all. The serial is a
// count of days from the workbook's epoch — 1900-01-01 or, in the 1904
// date system, 1904-01-01 — with the time of day in its fraction. The
// 1900 calendar counts a 29 February 1900 that no year had, so every
// serial from 61 on sits one day past the calendar; the day 60 is read as
// the 28 February it displays over. A number format says a date by the
// letters of its code that stand outside quotes, brackets, and escapes.

///|
/// The serial of 1970-01-01 in the 1900 date system, from serial 61 on.
const EXCEL_EPOCH_1900 : Int64 = 25569L

///|
/// The serial of 1970-01-01 in the 1904 date system, whose day 0 is
/// 1904-01-01.
const EXCEL_EPOCH_1904 : Int64 = 24107L

///|
/// The microseconds of a day.
const EXCEL_DAY_MICROS : Int64 = 86_400_000_000L

///|
/// 9999-12-31 as a day count since the epoch: the last day the calendar
/// names, and the last a sheet's date can be.
const EXCEL_LAST_DAY : Int64 = 2932896L

///|
/// What a number format makes of the number it formats.
priv enum ExcelFormat {
  /// A number, whatever its format says about it.
  Plain
  /// A time of day: the serial's fraction.
  Time
  /// An elapsed time, the whole serial as a span from the epoch.
  Elapsed
  /// A calendar day — with its time of day when set.
  Date(Bool)
}

///|
/// What the workbook's builtin number format `id` makes of a number. The
/// date and time formats every locale shares are the ones read as such;
/// the formats a locale re-spells are read as plain numbers, since the
/// same id is a date in one locale's workbook and an accounting format
/// in another's.
fn excel_builtin_format(id : Int32) -> ExcelFormat {
  if id >= 14 && id <= 17 {
    Date(false)
  } else if id >= 18 && id <= 21 {
    Time
  } else if id == 22 {
    Date(true)
  } else if id == 45 || id == 47 {
    Time
  } else if id == 46 {
    Elapsed
  } else {
    Plain
  }
}

///|
/// Whether `text` spells `word` from `at`, either letter's case. The
/// word's letters are upper case.
fn excel_spells(text : Array[Char], at : Int32, word : String) -> Bool {
  let letters = word.to_array()
  if at + letters.length() > text.length() {
    return false
  }
  for i in 0..<letters.length() {
    if text[at + i] != letters[i] &&
      text[at + i].to_int() != letters[i].to_int() + 32 {
      return false
    }
  }
  true
}

///|
/// Whether the character is `lower`'s letter, in either case.
fn excel_is(c : Char, lower : Char) -> Bool {
  c == lower || c.to_int() == lower.to_int() - 32
}

///|
/// A custom number format's first section without what carries no date
/// letter: its quoted text, its bracketed conditions and locales, the
/// character an escape, a skip, or a repeat names, and its meridian.
fn excel_format_letters(code : String) -> Array[Char] {
  let chars = code.to_array()
  let length = chars.length()
  let out = StringBuilder()
  let mut index = 0
  let mut in_quote = false
  while index < length {
    let c = chars[index]
    if c == '"' {
      // A quote inside quoted text is written twice, and closes nothing.
      if in_quote && index + 1 < length && chars[index + 1] == '"' {
        index += 2
        continue
      }
      in_quote = !in_quote
      index += 1
    } else if in_quote {
      index += 1
    } else if c == ';' {
      // The sections after the first format the other signs.
      break
    } else if c == '[' {
      while index < length && chars[index] != ']' {
        index += 1
      }
      index += 1
    } else if c == '\\' || c == '_' || c == '*' {
      index += 2
    } else if excel_spells(chars, index, "AM/PM") {
      index += 5
    } else if excel_spells(chars, index, "A/P") {
      index += 3
    } else {
      out.write_char(c)
      index += 1
    }
  }
  out.to_string().to_array()
}

///|
/// Whether a custom number format's first section shows an elapsed time:
/// a bracketed `[h]`, `[m]`, or `[s]`, the hours, minutes, or seconds run
/// since the start — the whole serial a span, not the fraction a time of
/// day is.
fn excel_elapsed(code : String) -> Bool {
  let chars = code.to_array()
  let length = chars.length()
  let mut index = 0
  let mut in_quote = false
  let mut found = false
  while index < length && !found {
    let c = chars[index]
    if c == '"' {
      in_quote = !in_quote
      index += 1
    } else if in_quote {
      index += 1
    } else if c == ';' {
      break
    } else if c == '[' {
      // The bracket's content: one time letter, however many times.
      index += 1
      let mut letters = 0
      let mut one : Char = ' '
      while index < length && chars[index] != ']' {
        let inner = chars[index]
        if excel_is(inner, 'h') || excel_is(inner, 'm') || excel_is(inner, 's') {
          if letters == 0 {
            one = inner
          }
          letters += 1
          if !excel_same_letter(inner, one) {
            letters = -1
          }
        } else {
          letters = -1
        }
        index += 1
      }
      if letters > 0 {
        found = true
      }
      index += 1
    } else if c == '\\' || c == '_' || c == '*' {
      index += 2
    } else {
      index += 1
    }
  }
  found
}

///|
/// Whether two letters are the same one, in either case.
fn excel_same_letter(a : Char, b : Char) -> Bool {
  a == b || a.to_int() == b.to_int() + 32 || a.to_int() + 32 == b.to_int()
}

///|
/// The letter of a format nearest to `index` on one side that is not
/// `c` over again: a run of one letter (`mm`) is one token, so the
/// letters around a token are those of the tokens beside it. `step` is
/// `-1` for the letters before it and `1` for the ones after; `outside`
/// answers when there is none.
fn excel_neighbour(
  letters : Array[Char],
  index : Int32,
  step : Int32,
  c : Char,
  outside : Char,
) -> Char {
  let mut j = index + step
  while j >= 0 && j < letters.length() {
    let other = letters[j]
    if other.is_ascii_alphabetic() && !excel_same_letter(other, c) {
      return other
    }
    j += step
  }
  outside
}

///|
/// What a custom number format's code makes of a number: `d` and `y`
/// name a day, `h` and `s` a time, and an `m` is a minute when it
/// follows an hour or precedes a second, and a month otherwise. A day
/// letter among them makes a date — with a time when a time letter is
/// there too; time letters alone make a time; a bracketed time unit
/// makes an elapsed time; and none at all leaves the number a number.
fn excel_custom_format(code : String) -> ExcelFormat {
  if excel_elapsed(code) {
    return Elapsed
  }
  let letters = excel_format_letters(code)
  let mut day = false
  let mut time = false
  for index, c in letters {
    if c.is_ascii_alphabetic() {
      if excel_is(c, 'd') || excel_is(c, 'y') {
        day = true
      } else if excel_is(c, 'h') || excel_is(c, 's') {
        time = true
      } else if excel_is(c, 'm') {
        // A minute when the token before it is an hour or the token
        // after it a second, and a month otherwise.
        let before = excel_neighbour(letters, index, -1, c, ' ')
        let after = excel_neighbour(letters, index, 1, c, ' ')
        if excel_is(before, 'h') || excel_is(after, 's') {
          time = true
        } else {
          day = true
        }
      }
    }
  }
  if day {
    Date(time)
  } else if time {
    Time
  } else {
    Plain
  }
}

///|
/// The serial's whole days, refused when the serial names none: one
/// before the first day of its date system, or one that is not a number.
fn excel_whole_days(
  serial : Double,
  cell : String,
) -> Int64 raise @types.DataError {
  if serial.is_nan() || serial < 0.0 {
    raise @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "excel: cell \{cell} carries a date \{serial}, before the first day its calendar names",
      ),
    )
  }
  serial.floor().to_int64()
}

///|
/// The day count since 1970-01-01 a date's whole serial names, in the
/// workbook's date system.
fn excel_day_count(whole : Int64, date1904 : Bool) -> Int64 {
  if date1904 {
    whole - EXCEL_EPOCH_1904
  } else if whole >= 60L {
    whole - EXCEL_EPOCH_1900
  } else {
    // Before the phantom day the calendar is one day shorter: day 1 is
    // 1900-01-01, the epoch's 25567th day before it.
    whole - 25568L
  }
}

///|
/// The day a date's serial names: its whole days, the fraction a format
/// with no time does not show left behind — within the days the calendar
/// names, a serial past the last of them refused as one before the first
/// is.
fn excel_day(
  serial : Double,
  date1904 : Bool,
  cell : String,
) -> Int64 raise @types.DataError {
  let days = excel_day_count(excel_whole_days(serial, cell), date1904)
  if days > EXCEL_LAST_DAY {
    raise @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "excel: cell \{cell} carries a date \{serial}, past 9999-12-31, the last day its calendar names",
      ),
    )
  }
  days
}

///|
/// The microseconds since the epoch an instant's serial names: its whole
/// days in the workbook's date system, and its fraction as the time of
/// day to the nearest microsecond — a fraction that rounds up to a whole
/// day being the next day's midnight.
fn excel_instant(
  serial : Double,
  date1904 : Bool,
  cell : String,
) -> Int64 raise @types.DataError {
  ignore(excel_day(serial, date1904, cell))
  let mut days = excel_day_count(excel_whole_days(serial, cell), date1904)
  // The fraction of a double at least one is exact, and its product with
  // the day is a number no larger than the day, so the rounding is within
  // a fraction of a microsecond.
  let fraction = serial - excel_whole_days(serial, cell).to_double()
  let mut micros = excel_micros(fraction)
  if micros == EXCEL_DAY_MICROS {
    days += 1L
    micros = 0L
  }
  days * EXCEL_DAY_MICROS + micros
}

///|
/// The microseconds of a serial's fraction of a day, to the nearest one.
fn excel_micros(fraction : Double) -> Int64 {
  (fraction * EXCEL_DAY_MICROS.to_double() + 0.5).floor().to_int64()
}

///|
/// The time of day a time format makes of a serial: its fraction, as the
/// microseconds past the epoch's midnight — the day a time of day alone
/// reads on.
fn excel_time(serial : Double, cell : String) -> Int64 raise @types.DataError {
  let fraction = serial - excel_whole_days(serial, cell).to_double()
  let micros = excel_micros(fraction)
  if micros == EXCEL_DAY_MICROS {
    0L
  } else {
    micros
  }
}

///|
/// A number cell under its format: the day or the instant a date format
/// makes of its serial, the time of day a time format makes of its
/// fraction — read on 1970-01-01, the day a time of day alone has — the
/// span an elapsed format makes of the whole serial, or the number
/// itself.
fn excel_number(
  serial : Double,
  format : ExcelFormat,
  date1904 : Bool,
  cell : String,
) -> ExcelCell raise @types.DataError {
  match format {
    Plain => Number(serial)
    Time => Instant(excel_time(serial, cell))
    Elapsed => Instant(excel_span(serial, cell))
    Date(false) =>
      // A fraction a date format does not show is a time of day all the
      // same, kept as the instant it names.
      if serial == serial.floor() {
        Day(excel_day(serial, date1904, cell))
      } else {
        Instant(excel_instant(serial, date1904, cell))
      }
    Date(true) => Instant(excel_instant(serial, date1904, cell))
  }
}

///|
/// The span an elapsed format makes of a serial: the whole serial as
/// microseconds from the epoch, to the nearest one — the instant a span
/// reads as, counted from 1970-01-01.
fn excel_span(serial : Double, cell : String) -> Int64 raise @types.DataError {
  ignore(excel_whole_days(serial, cell))
  (serial * EXCEL_DAY_MICROS.to_double() + 0.5).floor().to_int64()
}

///|
/// The serial of a day count: the day's number in the workbook's date
/// system. A day before the system's first, or past the calendar's last,
/// is refused, naming the column: no cell of the calendar holds it.
fn excel_day_serial(
  days : Int64,
  date1904 : Bool,
  column : String,
) -> Double raise @types.DataError {
  if days > EXCEL_LAST_DAY {
    raise @types.DataError::Unsupported(
      "excel: column \"\{column}\" holds a day past 9999-12-31, the last day the calendar names",
    )
  }
  if date1904 {
    if days < -EXCEL_EPOCH_1904 {
      raise @types.DataError::Unsupported(
        "excel: column \"\{column}\" holds a day before 1904-01-01, the first day the 1904 calendar names",
      )
    }
    (days + EXCEL_EPOCH_1904).to_double()
  } else if days >= 61L - EXCEL_EPOCH_1900 {
    (days + EXCEL_EPOCH_1900).to_double()
  } else {
    let early = days + 25568L
    if early < 1L {
      raise @types.DataError::Unsupported(
        "excel: column \"\{column}\" holds a day before 1900-01-01, the first day the 1900 calendar names",
      )
    }
    early.to_double()
  }
}

///|
/// The serial of an instant: its day's serial, with its time of day as
/// the fraction — to the microsecond, which the double holds for every
/// day before 2149. The serial is checked against the instant it must
/// read back as: past those days a sheet's number holds a coarser
/// instant, and one it cannot hold refuses rather than being written
/// another instant.
fn excel_instant_serial(
  micros : Int64,
  date1904 : Bool,
  column : String,
) -> Double raise @types.DataError {
  let (day, within) = @types.timestamp_micros_to_day(micros)
  let serial = excel_day_serial(day, date1904, column) +
    within.to_double() / EXCEL_DAY_MICROS.to_double()
  let back = excel_instant(serial, date1904, "the cell") catch { _ => -1L }
  if back != micros {
    raise @types.DataError::Unsupported(
      "excel: column \"\{column}\" holds \{@types.Scalar::Timestamp(micros).to_string()}, finer than the number a sheet's date holds it by; cast the column to String",
    )
  }
  serial
}

///|
/// A cell's place, for the refusals that name one.
fn excel_place(row : Int32, col : Int32) -> String {
  "at row \{row}, column \{col}"
}
