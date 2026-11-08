// The rider dtypes' read parsers — the text forms the writers render, read
// back exactly. `Date`'s ISO `YYYY-MM-DD`, `Timestamp`'s
// `YYYY-MM-DDTHH:MM:SS.ffffff` (an optional trailing `Z`, the one
// real-world spelling the writer's own form admits), and `Decimal`'s plain
// sign-digits-point-digits (leading zeros admitted — `007` and `00.5`
// read as `7` and `0.5`, the one widening over the writer's exact form,
// and a value-neutral one): each parser accepts the text its writer emits
// — `Decimal`'s, that widening aside — and refuses everything else, so a
// written-back column pins back to its own dtype and no other form
// silently retypes. Inference never calls
// these — a rider dtype enters a frame only through an explicit `dtypes`
// pin — so their strictness is the pin's strictness, not inference's
// windowed guess. The calendar half is the shared pair
// `days_from_civil` / `date_days_to_civil`, whose round trip is the
// parser's own validity check.

///|
/// `Some(days)` when `s` is the ISO date form `YYYY-MM-DD` the `Date`
/// writer renders — an optional leading sign (`-` for years before
/// year 1, `+` for the positive years past the four-digit basic range,
/// where it is the writer's own spelling), never on year 0 itself (its
/// one form is the unsigned `0000`), a year of four or more digits (a
/// bare run past four digits is the unsigned expanded spelling earlier
/// writers emitted, and reads the same), then two-digit month and day —
/// naming a real calendar date; `None` for any other shape and for a
/// month or day the calendar itself refuses (February 30th, a non-leap
/// February 29th).
/// The last check is structural: the scanned `(year, month, day)` goes
/// through `days_from_civil` and back through `date_days_to_civil`, and is
/// accepted exactly when the round trip returns it unchanged — month
/// lengths and leap years need no second copy of the rules.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn parse_date_days_opt(s : String) -> Int64? {
  match scan_iso_date(s) {
    None => None
    Some((year, month, day, rest)) =>
      if rest != s.length() {
        None
      } else {
        let days = days_from_civil(year, month, day)
        if date_days_to_civil(days) == (year, month, day) {
          Some(days)
        } else {
          None
        }
      }
  }
}

///|
/// `Some(micros)` when `s` is the ISO timestamp form the `Timestamp`
/// writer renders — the `YYYY-MM-DD` date half, a literal `T`, then
/// `HH:MM:SS` with an optional `.` and one to six fraction digits (the
/// writer's own form is always six; a shorter one pads with zeros, which
/// is lossless, while a seventh digit is precision the microsecond count
/// cannot carry and refuses) — plus an optional trailing `Z` (the UTC
/// marker the writer's zone-free form is read back through in practice);
/// `None` for any other shape, including a time-zone offset. The clock
/// half is validated by range (`00–23` hours, `00–59` minutes and
/// seconds) and the date half by the round trip above; the composition is
/// checked, so no accepted form overflows the microsecond count.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn parse_timestamp_micros_opt(s : String) -> Int64? {
  match scan_iso_date(s) {
    None => None
    Some((year, month, day, rest)) =>
      if rest >= s.length() || s[rest] != 'T' {
        None
      } else {
        match scan_clock(s, rest + 1) {
          None => None
          Some(clock) => {
            let days = days_from_civil(year, month, day)
            if !(date_days_to_civil(days) == (year, month, day)) {
              None
            } else {
              // The validated ranges bound `clock` below one day, so
              // only the day scaling can leave the range.
              match @numeric.mul_checked(days, 86_400_000_000L) {
                Some(day_us) => @numeric.add_checked(day_us, clock)
                None => None
              }
            }
          }
        }
      }
  }
}

// ── scanning helpers ─────────────────────────────────────────────────

///|
/// `Some((year, month, day, next))` for the ISO date prefix at the start —
/// an optional sign (`-` before year 1, `+` on the positive expanded
/// years past the four-digit basic range, where it is the writer's own
/// spelling), four-or-more year digits (a bare run past four digits is
/// the unsigned expanded spelling earlier writers emitted, and reads the
/// same), `-`, two month digits, `-`, two day digits — with `next` the
/// index after the date; `None` for any other prefix, for either sign on
/// year 0 (the writer emits year 0 only unsigned), and for a `+` over a
/// four-digit year (the basic range is spelled unsigned). The month and
/// day are range-screened here (`01`–`12`, `01`–`31`) so an out-of-range
/// pair refuses without reaching the calendar round trip, which owns the
/// finer rules.
fn scan_iso_date(s : String) -> (Int64, Int64, Int64, Int32)? {
  let n = s.length()
  let mut i = 0
  // The expanded form's sign: `-` for years before year 1, `+` for the
  // positive years past the four-digit basic range (the writer's own
  // spelling for them).
  let mut sign = 0 // -1 negative, 1 expanded positive, 0 unsigned
  if i < n && (s[i] == '-' || s[i] == '+') {
    if s[i] == '-' {
      sign = -1
    } else {
      sign = 1
    }
    i = i + 1
  }
  let mut year = 0L
  let mut year_digits = 0
  let mut alive = true
  while alive && i < n {
    match digit_at(s, i) {
      Some(d) =>
        match checked_push(year, d) {
          Some(v) => {
            year = v
            i = i + 1
            year_digits = year_digits + 1
          }
          None => alive = false
        }
      None => break
    }
  }
  // The writer pads the basic-range year to four digits; a longer run is
  // an expanded year the rendering also emits, so four is the floor.
  if !alive || year_digits < 4 {
    return None
  }
  // Year 0 has one spelling, the unsigned `0000` — the writer's own, and
  // ISO 8601's (a signed zero names no year, either sign) — so a sign on
  // an all-zero run refuses here rather than reading as a second
  // spelling of it.
  if sign != 0 && year == 0L {
    return None
  }
  // The `+` is the expanded form's own sign: a year inside the basic
  // range is spelled unsigned, so a plus over four digits is not the
  // writer's form.
  if sign > 0 && year_digits == 4 {
    return None
  }
  if i >= n || s[i] != '-' {
    return None
  }
  match scan_two_digits(s, i + 1) {
    None => None
    Some((month, after_month)) =>
      if month < 1L || month > 12L || after_month >= n || s[after_month] != '-' {
        None
      } else {
        match scan_two_digits(s, after_month + 1) {
          None => None
          Some((day, after_day)) =>
            if day < 1L || day > 31L {
              None
            } else {
              let signed_year = if sign < 0 { -year } else { year }
              Some((signed_year, month, day, after_day))
            }
        }
      }
  }
}

///|
/// `Some(within_day)` for the clock suffix `HH:MM:SS.ffffff` starting at
/// `from` — two range-checked digits per field, a literal separator
/// between each, exactly six fraction digits, then end-of-string or the
/// one admitted variant, a trailing `Z`; anything else (an offset, a
/// shorter or longer fraction, a missing field) is `None`. The validated
/// ranges bound the answer below one day's microseconds.
fn scan_clock(s : String, from : Int32) -> Int64? {
  match scan_two_digits(s, from) {
    None => None
    Some((hour, after_hour)) =>
      if hour > 23L || after_hour >= s.length() || s[after_hour] != ':' {
        None
      } else {
        match scan_two_digits(s, after_hour + 1) {
          None => None
          Some((minute, after_minute)) =>
            if minute > 59L ||
              after_minute >= s.length() ||
              s[after_minute] != ':' {
              None
            } else {
              match scan_two_digits(s, after_minute + 1) {
                None => None
                Some((second, after_second)) =>
                  if second > 59L {
                    None
                  } else {
                    scan_fraction_tail(s, after_second, hour, minute, second)
                  }
              }
            }
        }
      }
  }
}

///|
/// The fraction tail of the clock scan, starting at the position the
/// seconds field ends: an optional `.` with one to six fraction digits (a
/// bare point with none refuses; a seventh digit is precision the
/// microsecond count cannot carry), then end of string or the one
/// admitted variant, a trailing `Z` — composed with the already-validated
/// fields into the within-day microsecond count.
fn scan_fraction_tail(
  s : String,
  from : Int32,
  hour : Int64,
  minute : Int64,
  second : Int64,
) -> Int64? {
  let n = s.length()
  let mut i = from
  let mut frac = 0L
  let mut digits = 0
  if i < n && s[i] == '.' {
    i = i + 1
    while i < n {
      match digit_at(s, i) {
        Some(d) => {
          digits = digits + 1
          if digits > 6 {
            return None
          }
          frac = frac * 10L + d
          i = i + 1
        }
        None => break
      }
    }
    if digits == 0 {
      return None
    }
    // A shorter fraction pads right, its value unchanged — `"0.5"`
    // seconds is 500000 microseconds.
    for _ in digits..<6 {
      frac = frac * 10L
    }
  }
  if i < n && (s[i] != 'Z' || i + 1 != n) {
    return None
  }
  Some(
    hour * 3_600_000_000L + minute * 60_000_000L + second * 1_000_000L + frac,
  )
}

///|
/// `Some((value, next))` for exactly two ASCII digits at `start`.
fn scan_two_digits(s : String, start : Int32) -> (Int64, Int32)? {
  if start + 1 >= s.length() {
    return None
  }
  match (digit_at(s, start), digit_at(s, start + 1)) {
    (Some(tens), Some(ones)) => Some((tens * 10L + ones, start + 2))
    _ => None
  }
}

///|
/// `Some(d)` when the UTF-16 unit at `i` is an ASCII digit. Every caller
/// bounds-checks its index before calling (string indexing is the
/// aborting kind), so the only refusal here is the non-digit unit.
fn digit_at(s : String, i : Int32) -> Int64? {
  let u = s[i].to_int()
  if u >= 48 && u <= 57 {
    Some((u - 48).to_int64())
  } else {
    None
  }
}

///|
/// The checked `Int64` push a digit run accumulates by — the digit
/// carrying its run's sign, so a negative run descends from zero and
/// lands on `MIN` where the same digits climbed as positives would
/// overflow — riding the numeric package's own checked multiply and add
/// (the layering allows the import; this package once carried line copies
/// of both beside them). A `None` is the parser's refusal (a digit run
/// whose value leaves `Int64`), never a wrap into a confidently wrong
/// count.
fn checked_push(v : Int64, d : Int64) -> Int64? {
  match @numeric.mul_checked(v, 10L) {
    Some(t) => @numeric.add_checked(t, d)
    None => None
  }
}
