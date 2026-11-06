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
/// writer renders — an optional leading `-` for years before year 1,
/// never on year 0 itself (its one form is the unsigned `0000`), a
/// year of four or more digits, then two-digit month and day — naming a
/// real calendar date; `None` for any other shape and for a month or day
/// the calendar itself refuses (February 30th, a non-leap February 29th).
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
              match checked_mul(days, 86_400_000_000L) {
                Some(day_us) => checked_add(day_us, clock)
                None => None
              }
            }
          }
        }
      }
  }
}

///|
/// `Some(unscaled)` when `s` is the plain decimal form the `Decimal`
/// writer renders — an optional `-`, integer digits, and an optional `.`
/// with fraction digits — expressed at `scale` (the value is
/// `unscaled x 10^-scale`); `None` for any other shape, for a `scale`
/// outside the dtype's `[0, 18]` envelope, for a fraction carrying more
/// digits than `scale` names (a precision the pin cannot hold exactly —
/// truncating it would be a silent misreading), and for a value outside
/// the signed `Int64` range. The digits accumulate in the value's own
/// sign, so the negative extreme — `Int64::MIN`, whose magnitude runs one
/// past `MAX` and could never be formed as a positive magnitude first —
/// reads back in every spelling the writer gives it. A fraction with
/// fewer digits than `scale` pads with zeros (`"1.5"` at scale 2 is
/// `1.50`); a bare integer is the same padding applied to the whole
/// fraction.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn parse_decimal_unscaled_opt(s : String, scale : Int32) -> Int64? {
  if scale < 0 || scale > 18 {
    return None
  }
  let n = s.length()
  let mut i = 0
  let neg = if i < n && s[i] == '-' {
    i = i + 1
    true
  } else {
    false
  }
  match scan_digit_run(s, i, neg) {
    None => None
    Some((int_part, int_digits, after_int)) =>
      if int_digits == 0 {
        None
      } else {
        match scan_fraction(s, after_int, scale) {
          None => None
          Some((frac_part, frac_digits, end)) =>
            if end != n {
              None
            } else {
              express_at_scale(int_part, frac_part, frac_digits, scale, neg)
            }
        }
      }
  }
}

// ── scanning helpers ─────────────────────────────────────────────────

///|
/// `Some((year, month, day, next))` for the ISO date prefix at the start —
/// an optional `-`, four-or-more year digits, `-`, two month digits, `-`,
/// two day digits — with `next` the index after the date; `None` for any
/// other prefix, and for a `-` on year 0 itself (the writer emits year 0
/// only unsigned). The month and day are range-screened here (`01`–`12`,
/// `01`–`31`) so an out-of-range pair refuses without reaching the
/// calendar round trip, which owns the finer rules.
fn scan_iso_date(s : String) -> (Int64, Int64, Int64, Int32)? {
  let n = s.length()
  let mut i = 0
  let neg_year = if i < n && s[i] == '-' {
    i = i + 1
    true
  } else {
    false
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
  // ISO 8601's (a signed zero names no year) — so a `-` on an all-zero
  // run refuses here rather than reading as a second spelling of it.
  if neg_year && year == 0L {
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
              let signed_year = if neg_year { -year } else { year }
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
/// `Some((value, digits, next))` for a maximal run of ASCII digits at
/// `start` (an empty run allowed — the callers decide whether zero digits
/// is their form), the value accumulated checked — in the run's own sign
/// under `neg`, so the negative side reaches `Int64::MIN`, whose digits
/// as a positive magnitude would run one past `MAX`.
fn scan_digit_run(
  s : String,
  start : Int32,
  neg : Bool,
) -> (Int64, Int32, Int32)? {
  let n = s.length()
  let mut v = 0L
  let mut digits = 0
  let mut i = start
  let mut alive = true
  while alive && i < n {
    match digit_at(s, i) {
      Some(d) =>
        match checked_push(v, if neg { -d } else { d }) {
          Some(pushed) => {
            v = pushed
            i = i + 1
            digits = digits + 1
          }
          None => alive = false
        }
      None => break
    }
  }
  if alive {
    Some((v, digits, i))
  } else {
    None
  }
}

///|
/// The decimal scan's fraction half: when the character at `from` is a
/// point, a run of one-or-more digits after it carrying at most `scale`
/// digits (more is a precision the pin cannot hold); when it is not, no
/// fraction at all. The run is a magnitude — scanned unsigned, whatever
/// sign the whole form carries. `next` is the index the whole form ends
/// at.
fn scan_fraction(
  s : String,
  from : Int32,
  scale : Int32,
) -> (Int64, Int32, Int32)? {
  let n = s.length()
  if from >= n || s[from] != '.' {
    return Some((0L, 0, from))
  }
  match scan_digit_run(s, from + 1, false) {
    None => None
    Some((frac, digits, next)) =>
      if digits == 0 || digits > scale {
        None
      } else {
        Some((frac, digits, next))
      }
  }
}

///|
/// Express an `(integer part, fraction part at its own digit count)`
/// pair at `scale`: the integer part shifts the full width, the fraction
/// the digits it has, the gap zeros. The parts join in the value's sign —
/// the integer part arrives from the signed scan, the fraction (a
/// magnitude, always below `10^18`) takes its sign from `neg` — so the
/// composition reaches the negative extreme a positive magnitude could
/// not. The fraction carries at most `scale` ≤ 18 digits, so its shift
/// lands below `10^18` — plain arithmetic, no check to need — while the
/// integer part's shift and the sum can leave the range and are checked,
/// so a value that would wrap refuses instead.
fn express_at_scale(
  int_part : Int64,
  frac_part : Int64,
  frac_digits : Int32,
  scale : Int32,
  neg : Bool,
) -> Int64? {
  let mut frac = frac_part
  for _ in frac_digits..<scale {
    frac = frac * 10L
  }
  let signed_frac = if neg { -frac } else { frac }
  let mut whole = int_part
  for _ in 0..<scale {
    match checked_mul(whole, 10L) {
      Some(v) => whole = v
      None => return None
    }
  }
  checked_add(whole, signed_frac)
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
/// overflow — the same range tests the decimal dtype's own envelope
/// rides, spelled here because the value-type package sits below the
/// numeric package that owns the other copy. A `None` is the parser's
/// refusal (a digit run whose value leaves `Int64`), never a wrap into a
/// confidently wrong count.
fn checked_push(v : Int64, d : Int64) -> Int64? {
  match checked_mul(v, 10L) {
    Some(t) => checked_add(t, d)
    None => None
  }
}

///|
fn checked_add(a : Int64, b : Int64) -> Int64? {
  let r = a + b
  if (a >= 0L && b >= 0L && r < 0L) || (a < 0L && b < 0L && r >= 0L) {
    None
  } else {
    Some(r)
  }
}

///|
/// The multiplier is positive at every call site (a digit push's `10`,
/// the day-to-microsecond bound), so the divide-back verification sees no
/// trapping division and no wraparound it could miss.
fn checked_mul(a : Int64, b : Int64) -> Int64? {
  if a == 0L || b == 0L {
    return Some(0L)
  }
  let r = a * b
  if r / a != b || r / b != a {
    None
  } else {
    Some(r)
  }
}
