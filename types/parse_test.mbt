// Blackbox tests for the rider parsers — the text forms the writers render,
// read back exactly, plus the refused forms. The round trips go through the
// renderers themselves (`Scalar::to_string`), so the parser and the writer
// are pinned to each other rather than to a hand-copied constant.

///|
test "parse_date_days_opt round-trips the renderer" {
  assert_eq(@types.parse_date_days_opt("1970-01-01"), Some(0L))
  assert_eq(@types.parse_date_days_opt("2000-02-29"), Some(11016L))
  assert_eq(@types.parse_date_days_opt("1969-12-31"), Some(-1L))
  assert_eq(@types.parse_date_days_opt("0001-01-01"), Some(-719_162L))
  assert_eq(@types.parse_date_days_opt("0000-01-01"), Some(-719_528L))
  assert_eq(@types.parse_date_days_opt("9999-12-31"), Some(2_932_896L))
  // Every renderer output parses back to the count it came from — the
  // padded-year, expanded-year, pre-year-1, and year-zero spellings
  // included (year zero rendered unsigned, its one form).
  for
    days in [
      0L, 11016L, -1L, -719_162L, -719_528L, 2_932_896L, 100_000L, -100_000L, -800_000L,
      9_223_372_036_854_775_807L,
    ] {
    let rendered = @types.Scalar::Date(days).to_string()
    assert_eq(@types.parse_date_days_opt(rendered), Some(days))
  }
  assert_eq(@types.Scalar::Date(0L).to_string(), "1970-01-01")
  assert_eq(@types.Scalar::Date(-719_162L).to_string(), "0001-01-01")
}

///|
test "parse_date_days_opt reads the expanded years in both spellings" {
  // The writer spells a year past the four-digit basic range in the
  // expanded form, sign first — `+10000-…` — and the parser reads that
  // spelling back. The bare digits are the spelling earlier writers
  // emitted (a legacy file's cell), value-identical, and read the same;
  // the negative side always carried its sign.
  assert_eq(@types.parse_date_days_opt("+10000-01-01"), Some(2_932_897L))
  assert_eq(@types.parse_date_days_opt("10000-01-01"), Some(2_932_897L))
  assert_eq(@types.parse_date_days_opt("+12345-06-15"), Some(3_789_556L))
  assert_eq(@types.parse_date_days_opt("12345-06-15"), Some(3_789_556L))
  assert_eq(@types.parse_date_days_opt("-194022-09-24"), Some(-71_584_342L))
  // The timestamp reader composes the same date scan: the expanded year
  // rides its clock half too.
  assert_eq(
    @types.parse_timestamp_micros_opt("+10000-01-01T00:00:00"),
    Some(2_932_897L * 86_400_000_000L),
  )
}

///|
test "parse_date_days_opt refuses the non-forms and non-dates" {
  // Not the writer's shape.
  assert_eq(@types.parse_date_days_opt(""), None)
  assert_eq(@types.parse_date_days_opt("2024-1-01"), None) // one-digit month
  assert_eq(@types.parse_date_days_opt("2024-01-1"), None) // one-digit day
  assert_eq(@types.parse_date_days_opt("24-01-01"), None) // short year
  assert_eq(@types.parse_date_days_opt("2024/01/01"), None)
  assert_eq(@types.parse_date_days_opt("2024-01-01 "), None) // trailing space
  assert_eq(@types.parse_date_days_opt(" 2024-01-01"), None)
  assert_eq(@types.parse_date_days_opt("2024-01-01T00:00:00.000000"), None) // a timestamp, not a date
  assert_eq(@types.parse_date_days_opt("+2024-01-01"), None) // a `+` rides the expanded years alone
  assert_eq(@types.parse_date_days_opt("+0000-01-01"), None) // signed year zero — its one form is unsigned
  assert_eq(@types.parse_date_days_opt("+00000-01-01"), None) // an all-zero run is year 0, either sign
  assert_eq(@types.parse_date_days_opt("-0000-01-01"), None) // signed year zero — its one form is unsigned
  assert_eq(@types.parse_date_days_opt("99999999999999999999-01-01"), None) // a year whose digits leave Int64
  // The calendar's own refusals.
  assert_eq(@types.parse_date_days_opt("2023-02-29"), None) // non-leap
  assert_eq(@types.parse_date_days_opt("2024-02-30"), None)
  assert_eq(@types.parse_date_days_opt("2024-04-31"), None) // April has 30
  assert_eq(@types.parse_date_days_opt("2024-13-01"), None)
  assert_eq(@types.parse_date_days_opt("2024-00-10"), None)
  assert_eq(@types.parse_date_days_opt("2024-01-00"), None)
  // A leap day that is one: 2024 is a leap year.
  assert_eq(@types.parse_date_days_opt("2024-02-29"), Some(19782L))
}

///|
test "parse_timestamp_micros_opt round-trips the renderer" {
  assert_eq(
    @types.parse_timestamp_micros_opt("1970-01-01T00:00:00.000000"),
    Some(0L),
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T15:04:20.123456"),
    Some(1_704_121_460_123_456L),
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("1969-12-31T23:59:59.999999"),
    Some(-1L),
  )
  // Every renderer output parses back: the fraction magnitudes one by one,
  // through the renderer itself.
  for frac in [1L, 12L, 123L, 1234L, 12345L, 123456L] {
    let micros = 1_704_067_200_000_000L + frac
    let rendered = @types.Scalar::Timestamp(micros).to_string()
    assert_eq(@types.parse_timestamp_micros_opt(rendered), Some(micros))
  }
}

///|
test "parse_timestamp_micros_opt admits the fraction variants and refuses the rest" {
  assert_eq(
    @types.parse_timestamp_micros_opt("1970-01-01T00:00:00.000000Z"),
    Some(0L),
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("1970-01-01T00:00:00Z"), // no fraction
    Some(0L),
  )
  // A shorter fraction pads right: `.123` seconds is 123000 micros.
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T00:00:00.123"),
    Some(1_704_067_200_123_000L),
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T00:00:00.1234567"), // 7 digits
    None,
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T00:00:00."), // bare point
    None,
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T00:00:00.000000+08:00"),
    None,
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01 00:00:00.000000"),
    None,
  ) // space separator
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T24:00:00.000000"),
    None,
  ) // hour 24
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T00:60:00.000000"),
    None,
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2024-01-01T00:00:60.000000"),
    None,
  )
  assert_eq(
    @types.parse_timestamp_micros_opt("2023-02-29T00:00:00.000000"),
    None,
  ) // non-date half
  assert_eq(@types.parse_timestamp_micros_opt("nope"), None) // no date half at all
  assert_eq(@types.parse_timestamp_micros_opt("-0000-01-01T00:00:00"), None) // signed year zero, the date half's own refusal
  assert_eq(@types.parse_timestamp_micros_opt("2024-01-01T0:00:00"), None) // a torn clock field
  assert_eq(@types.parse_timestamp_micros_opt("2024-01-01T00:"), None) // cut at the minute
  assert_eq(@types.parse_timestamp_micros_opt("2024-01-01T00:00:"), None) // cut at the second
  // A year whose day count, scaled to microseconds, leaves `Int64`.
  assert_eq(
    @types.parse_timestamp_micros_opt("9999999999-01-01T00:00:00"),
    None,
  )
}

///|
test "parse_decimal_unscaled_opt reads the writer's form at the pin's scale" {
  assert_eq(@types.parse_decimal_unscaled_opt("1.50", 2), Some(150L))
  assert_eq(@types.parse_decimal_unscaled_opt("1.5", 2), Some(150L)) // pads
  assert_eq(@types.parse_decimal_unscaled_opt("3", 2), Some(300L)) // bare integer
  assert_eq(@types.parse_decimal_unscaled_opt("3", 0), Some(3L))
  assert_eq(@types.parse_decimal_unscaled_opt("-0.05", 2), Some(-5L))
  assert_eq(@types.parse_decimal_unscaled_opt("0.00", 2), Some(0L))
  // The renderer's own output round-trips at its own scale.
  for
    unscaled in [
      1L, -1L, 12345L, -12345L, 9_223_372_036_854_775_807L, -9_223_372_036_854_775_808L,
    ] {
    let rendered = @types.Scalar::Decimal(4, unscaled).to_string()
    assert_eq(@types.parse_decimal_unscaled_opt(rendered, 4), Some(unscaled))
  }
  // `Int64::MIN` at the other scale shapes the writer gives it: the
  // magnitude's digits are one past `MAX`, so they read only because the
  // negative side accumulates in its own sign — bare integer and split
  // fraction alike.
  let min = -9_223_372_036_854_775_808L
  let rendered_bare = @types.Scalar::Decimal(0, min).to_string()
  assert_eq(@types.parse_decimal_unscaled_opt(rendered_bare, 0), Some(min))
  let rendered_split = @types.Scalar::Decimal(1, min).to_string()
  assert_eq(@types.parse_decimal_unscaled_opt(rendered_split, 1), Some(min))
}

///|
test "parse_decimal_unscaled_opt refuses what the pin cannot hold" {
  assert_eq(@types.parse_decimal_unscaled_opt("1.555", 2), None) // precision beyond the pin
  assert_eq(@types.parse_decimal_unscaled_opt("1.", 2), None) // empty fraction
  assert_eq(@types.parse_decimal_unscaled_opt(".5", 2), None) // empty integer part
  assert_eq(@types.parse_decimal_unscaled_opt("", 2), None)
  assert_eq(@types.parse_decimal_unscaled_opt("-", 2), None)
  assert_eq(@types.parse_decimal_unscaled_opt("1.5e3", 2), None) // no exponent form
  assert_eq(@types.parse_decimal_unscaled_opt("1_000.0", 2), None) // no grouping
  assert_eq(@types.parse_decimal_unscaled_opt("1.5", -1), None) // scale outside the envelope
  assert_eq(@types.parse_decimal_unscaled_opt("1.5", 19), None)
  assert_eq(
    @types.parse_decimal_unscaled_opt("1.9999999999999999999", 18),
    None,
  ) // a fraction whose digits leave Int64
  // A magnitude whose digits leave Int64 at the pin's scale.
  assert_eq(
    @types.parse_decimal_unscaled_opt("9223372036854775808.00", 2),
    None,
  )
  // The shift itself can leave the range where the digit run parses:
  // 922337203685477 x 10^6 exceeds `Int64`, as does a sum that fits only
  // before the fraction joins.
  assert_eq(@types.parse_decimal_unscaled_opt("922337203685477", 6), None)
  assert_eq(@types.parse_decimal_unscaled_opt("9223372036854775.808", 3), None)
  // ...while the same parts one unit of fraction lower fit exactly.
  assert_eq(
    @types.parse_decimal_unscaled_opt("9223372036854775.807", 3),
    Some(9_223_372_036_854_775_807L),
  )
  // The negative side's own overflow: one unit past `Int64::MIN`.
  assert_eq(@types.parse_decimal_unscaled_opt("-9223372036854775809", 0), None)
}
