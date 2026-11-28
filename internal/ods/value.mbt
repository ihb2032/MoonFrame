// The values a cell's attributes spell: a number by the XML Schema double
// lexical space; a date, a date with a clock, and a UTC offset turned into
// a day count or a count of microseconds; a duration and a clock reading
// turned into a count of microseconds. Every one that does not parse
// refuses, naming the attribute and its byte.

///|
/// An attribute of the element being read, as a message needs it: its
/// name, its value as spelled, and the byte of content.xml it starts at.
priv struct Attr {
  name : String
  value : String
  byte : Int32
}

///|
/// The refusal for an attribute that does not spell what it should:
/// `ParseError` naming the attribute, its byte and — cut to 32 characters
/// when longer — its value.
fn Attr::refusal(self : Attr, wrong : String) -> @types.DataError {
  bad(
    "ods: content.xml byte \{self.byte}: the \{self.name} attribute \"\{cut(self.value, 32)}\" \{wrong}",
  )
}

///|
/// A string cut to its first `most` characters.
fn cut(text : String, most : Int32) -> String {
  let kept = StringBuilder()
  let mut count = 0
  for c in text {
    if count >= most {
      break
    }
    kept.write_char(c)
    count += 1
  }
  kept.to_string()
}

///|
/// The number an `office:value` attribute spells — the XML Schema double
/// lexical space: an optional sign; digits with an optional fraction, or
/// a fraction alone; an optional exponent — or exactly `INF`, `-INF` or
/// `NaN`. Whitespace around the number is not part of it. Anything else is
/// not a number, and so is a finite spelling too large for a double.
fn parse_number(text : String, attr : Attr) -> Double raise @types.DataError {
  let trimmed = text.trim()
  if trimmed == "INF" {
    return @double.infinity
  }
  if trimmed == "-INF" {
    return @double.neg_infinity
  }
  if trimmed == "NaN" {
    return @double.not_a_number
  }
  let units = trimmed.code_units()
  let length = units.length()
  let mut i = 0
  if i < length && (unit(units, i) == 0x2B || unit(units, i) == 0x2D) {
    i += 1
  }
  let from = i
  i = digits_end(units, i)
  let whole = i - from
  let mut fraction = 0
  if i < length && unit(units, i) == 0x2E {
    i += 1
    let from = i
    i = digits_end(units, i)
    fraction = i - from
  }
  if whole == 0 && fraction == 0 {
    raise attr.refusal("is not a number")
  }
  if i < length && (unit(units, i) == 0x65 || unit(units, i) == 0x45) {
    i += 1
    if i < length && (unit(units, i) == 0x2B || unit(units, i) == 0x2D) {
      i += 1
    }
    let from = i
    i = digits_end(units, i)
    if i == from {
      raise attr.refusal("is not a number")
    }
  }
  if i != length {
    raise attr.refusal("is not a number")
  }
  // The spelling is one the format defines; the parser does the rounding,
  // and refuses a finite magnitude no double holds.
  let parsed : Result[Double, _] = Ok(@string.parse_double(trimmed)) catch {
    _ => Err(())
  }
  match parsed {
    Ok(number) => number
    Err(_) => raise attr.refusal("is not a number")
  }
}

///|
/// A trimmed attribute value, read one ASCII code unit at a time.
priv struct Cursor {
  units : ArrayView[UInt16]
  mut at : Int32
}

///|
/// A cursor over an attribute's value with the whitespace around it cut.
fn cursor(text : String) -> Cursor {
  Cursor::{ units: text.trim().code_units(), at: 0, }
}

///|
/// The code unit at `at` as a number, or -1 past the end.
fn unit(units : ArrayView[UInt16], at : Int32) -> Int32 {
  if at < units.length() {
    units[at].to_int()
  } else {
    -1
  }
}

///|
/// Whether a code unit is an ASCII digit.
fn is_digit(code : Int32) -> Bool {
  code >= 0x30 && code <= 0x39
}

///|
/// Where the run of digits from `from` ends.
fn digits_end(units : ArrayView[UInt16], from : Int32) -> Int32 {
  let mut i = from
  while i < units.length() && is_digit(units[i].to_int()) {
    i += 1
  }
  i
}

///|
/// The code unit the cursor is at, or -1 past the end.
fn Cursor::peek(self : Cursor) -> Int32 {
  unit(self.units, self.at)
}

///|
/// Whether the cursor is at a character, and passes it when it is.
fn Cursor::eat(self : Cursor, code : Int32) -> Bool {
  if self.peek() == code {
    self.at += 1
    true
  } else {
    false
  }
}

///|
/// A run of exactly `count` digits as a number; nothing when the next
/// `count` code units are not all digits or there are fewer than that.
fn Cursor::fixed(self : Cursor, count : Int32) -> Int32? {
  let end = self.at + count
  if end > self.units.length() {
    return None
  }
  let mut value = 0
  for i in self.at..<end {
    let code = self.units[i].to_int()
    if !is_digit(code) {
      return None
    }
    value = value * 10 + (code - 0x30)
  }
  self.at = end
  Some(value)
}

///|
/// A run of digits as a count; nothing when none follows or more than
/// eighteen do, so a count never overflows what carries it.
fn Cursor::count(self : Cursor) -> Int64? {
  let end = digits_end(self.units, self.at)
  if end == self.at || end - self.at > 18 {
    return None
  }
  let mut value = 0L
  for i in self.at..<end {
    value = value * 10L + (self.units[i].to_int() - 0x30).to_int64()
  }
  self.at = end
  Some(value)
}

///|
/// The fraction of a second a run of digits spells, in microseconds: the
/// first six digits, the rest dropped; nothing when no digit follows.
fn Cursor::fraction(self : Cursor) -> Int64? {
  let end = digits_end(self.units, self.at)
  if end == self.at {
    return None
  }
  let mut micros = 0L
  let from = self.at
  let taken = if end - from < 6 { end - from } else { 6 }
  for i in from..<(from + taken) {
    micros = micros * 10L + (self.units[i].to_int() - 0x30).to_int64()
  }
  for _ in taken..<6 {
    micros = micros * 10L
  }
  self.at = end
  Some(micros)
}

///|
/// Whether the cursor has passed every code unit.
fn Cursor::done(self : Cursor) -> Bool {
  self.at >= self.units.length()
}

///|
/// The micros in a day.
const DAY_MICROS : Int64 = 86400000000L

///|
/// The largest count of microseconds a time value can hold.
const MOST_MICROS : Int64 = 9223372036854775807L

///|
/// A clock from a cursor — hours, a colon and minutes, then a colon,
/// seconds and a fraction optionally — in microseconds since midnight;
/// nothing when the cursor is not at a clock, or the clock has 24 hours
/// or more.
fn take_clock(c : Cursor) -> Int64? {
  let hours = match c.count() {
    Some(hours) => hours
    None => return None
  }
  if !c.eat(0x3A) {
    return None
  }
  let minutes = match c.fixed(2) {
    Some(minutes) => minutes
    None => return None
  }
  let mut seconds = 0
  let mut micros = 0L
  if c.eat(0x3A) {
    seconds = match c.fixed(2) {
      Some(seconds) => seconds
      None => return None
    }
    if c.eat(0x2E) {
      micros = match c.fraction() {
        Some(micros) => micros
        None => return None
      }
    }
  }
  if hours > 23L || minutes > 59 || seconds > 59 {
    return None
  }
  Some(
    (hours * 60L + minutes.to_int64()) * 60000000L +
    seconds.to_int64() * 1000000L +
    micros,
  )
}

///|
/// The value an `office:date-value` attribute spells: a calendar date —
/// four digits of year, a month and a day of the proleptic Gregorian
/// calendar — or that date with a clock after a `T`, a `t` or a space; and
/// last a UTC offset optionally — `Z`, or hours and minutes from it. A
/// fraction's digits past the sixth are dropped. A date with neither a
/// clock nor an offset is a `Day`; every other is the `Instant` it names.
fn parse_date(text : String, attr : Attr) -> OdsValue raise @types.DataError {
  let c = cursor(text)
  let year = match c.fixed(4) {
    Some(year) => year
    None => raise attr.refusal("is not a date")
  }
  if !c.eat(0x2D) {
    raise attr.refusal("is not a date")
  }
  let month = match c.fixed(2) {
    Some(month) => month
    None => raise attr.refusal("is not a date")
  }
  if !c.eat(0x2D) {
    raise attr.refusal("is not a date")
  }
  let day = match c.fixed(2) {
    Some(day) => day
    None => raise attr.refusal("is not a date")
  }
  if month < 1 || month > 12 || day < 1 || day > month_days(year, month) {
    raise attr.refusal("is not a date")
  }
  let days = days_from_civil(year, month, day)
  let mut clock = 0L
  let next = c.peek()
  if next == 0x54 || next == 0x74 || next == 0x20 {
    c.at += 1
    clock = match take_clock(c) {
      Some(clock) => clock
      None => raise attr.refusal("is not a date")
    }
  }
  let mut offset = 0L
  let mut zoned = false
  let next = c.peek()
  if next == 0x5A || next == 0x7A {
    c.at += 1
    zoned = true
  } else if next == 0x2B || next == 0x2D {
    c.at += 1
    let west = next == 0x2D
    let hours = match c.fixed(2) {
      Some(hours) => hours
      None => raise attr.refusal("is not a date")
    }
    if !c.eat(0x3A) {
      raise attr.refusal("is not a date")
    }
    let minutes = match c.fixed(2) {
      Some(minutes) => minutes
      None => raise attr.refusal("is not a date")
    }
    if hours > 23 || minutes > 59 {
      raise attr.refusal("is not a date")
    }
    offset = (hours * 60 + minutes).to_int64() * 60000000L
    if west {
      offset = -offset
    }
    zoned = true
  }
  if !c.done() {
    raise attr.refusal("is not a date")
  }
  if zoned || clock != 0L {
    OdsValue::Instant(days * DAY_MICROS + clock - offset)
  } else {
    OdsValue::Day(days)
  }
}

///|
/// The value an `office:time-value` attribute spells: a duration since
/// midnight — `P`, days optionally, then `T` and hours, minutes and
/// seconds optionally, in that order and at least one of them when `T` is
/// written; at least one part altogether. Seconds take a fraction, the
/// digits past the sixth dropped. No sign, and no years, months or weeks:
/// a time of day has none. A count of microseconds no 64-bit integer holds
/// is not a time value.
fn parse_duration(text : String, attr : Attr) -> Int64 raise @types.DataError {
  let c = cursor(text)
  if !c.eat(0x50) {
    raise attr.refusal("is not a time value")
  }
  let mut total = 0L
  let mut any = false
  if is_digit(c.peek()) {
    // Days: a count, then `D`.
    let days = match c.count() {
      Some(days) => days
      None => raise attr.refusal("is not a time value")
    }
    if !c.eat(0x44) {
      raise attr.refusal("is not a time value")
    }
    total = scaled(total, days, DAY_MICROS, attr)
    any = true
  }
  if c.eat(0x54) {
    // A count and its unit, hours then minutes then seconds — each left
    // out, none repeated and none out of order — the seconds alone taking
    // a fraction.
    let mut stage = 0
    while is_digit(c.peek()) || c.peek() == 0x2E {
      let count = if is_digit(c.peek()) {
        match c.count() {
          Some(count) => count
          None => raise attr.refusal("is not a time value")
        }
      } else {
        0L
      }
      let fraction = if c.eat(0x2E) {
        match c.fraction() {
          Some(fraction) => Some(fraction)
          None => raise attr.refusal("is not a time value")
        }
      } else {
        None
      }
      let unit = c.peek()
      if unit == 0x48 && stage == 0 && fraction is None {
        total = scaled(total, count, 3600000000L, attr)
        stage = 1
      } else if unit == 0x4D && stage < 2 && fraction is None {
        total = scaled(total, count, 60000000L, attr)
        stage = 2
      } else if unit == 0x53 {
        total = scaled(total, count, 1000000L, attr)
        if fraction is Some(fraction) {
          total = added(total, fraction, attr)
        }
        stage = 3
      } else {
        raise attr.refusal("is not a time value")
      }
      c.at += 1
      any = true
      if stage == 3 {
        break
      }
    }
    if stage == 0 {
      raise attr.refusal("is not a time value")
    }
  }
  if !any || !c.done() {
    raise attr.refusal("is not a time value")
  }
  total
}

///|
/// `total` with `count` units of `unit` microseconds added, refusing a
/// count that would carry the sum past what a 64-bit integer holds.
fn scaled(
  total : Int64,
  count : Int64,
  unit : Int64,
  attr : Attr,
) -> Int64 raise @types.DataError {
  if count > (MOST_MICROS - total) / unit {
    raise attr.refusal("is not a time value")
  }
  total + count * unit
}

///|
/// `total` with `more` added, refusing a sum a 64-bit integer cannot hold.
fn added(
  total : Int64,
  more : Int64,
  attr : Attr,
) -> Int64 raise @types.DataError {
  if more > MOST_MICROS - total {
    raise attr.refusal("is not a time value")
  }
  total + more
}

///|
/// The time a cell's text spells when the cell carries no time value: a
/// clock reading — hours, a colon and minutes, then seconds and a fraction
/// optionally — with the whitespace around it not part of the reading.
/// Anything else refuses, naming the cell's byte and its text.
fn parse_clock_text(
  text : String,
  byte : Int32,
) -> Int64 raise @types.DataError {
  let c = cursor(text)
  let wrong = "ods: content.xml byte \{byte}: the text of a time cell, \"\{cut(text, 32)}\", is not a clock reading"
  let micros = match take_clock(c) {
    Some(micros) => micros
    None => raise bad(wrong)
  }
  if !c.done() {
    raise bad(wrong)
  }
  micros
}

///|
/// The days in a month of the proleptic Gregorian calendar.
fn month_days(year : Int32, month : Int32) -> Int32 {
  let common : ReadOnlyArray[Int32] = [
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
  ]
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  if month == 2 && leap {
    29
  } else {
    common[month - 1]
  }
}

///|
/// The days from 1970-01-01 to a date of the proleptic Gregorian calendar,
/// negative before it.
fn days_from_civil(year : Int32, month : Int32, day : Int32) -> Int64 {
  // March starts the year here, so that a leap day is a year's last.
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = (month + 9) % 12
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  (era * 146097 + doe - 719468).to_int64()
}
