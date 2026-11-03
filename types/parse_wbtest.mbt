// Whitebox tests for the calendar inverse — `days_from_civil` is private
// (its only production callers are the parsers in this package), so its
// inverse property against the pub `date_days_to_civil` is asserted here,
// inside the package, rather than through a seam nothing else needs.

///|
test "days_from_civil inverts date_days_to_civil over the calendar range" {
  for
    days in [
      0L, 1L, -1L, 11016L, 19724L, -719_162L, 2_932_896L, 100_000L, -100_000L, 4_102_444_800L,
    ] {
    let (y, m, d) = date_days_to_civil(days)
    assert_eq(days_from_civil(y, m, d), days)
  }
  // Named anchors, both directions.
  assert_eq(days_from_civil(1970, 1, 1), 0L)
  assert_eq(days_from_civil(2000, 2, 29), 11016L)
  assert_eq(days_from_civil(2024, 1, 2), 19724L)
  assert_eq(days_from_civil(1, 1, 1), -719_162L)
  assert_eq(days_from_civil(9999, 12, 31), 2_932_896L)
  assert_eq(days_from_civil(1969, 12, 31), -1L)
  assert_eq(date_days_to_civil(days_from_civil(800, 1, 1)), (800, 1, 1))
  assert_eq(date_days_to_civil(days_from_civil(-1, 1, 1)), (-1, 1, 1))
}

///|
test "days_from_civil threads the leap-year rules" {
  // The century rules: 2000 leaps (divisible by 400), 1900 does not.
  assert_eq(days_from_civil(2000, 3, 1) - days_from_civil(2000, 2, 1), 29L)
  assert_eq(days_from_civil(1900, 3, 1) - days_from_civil(1900, 2, 1), 28L)
  assert_eq(days_from_civil(2024, 3, 1) - days_from_civil(2024, 2, 1), 29L)
  assert_eq(days_from_civil(2023, 3, 1) - days_from_civil(2023, 2, 1), 28L)
  // The year seam: year 5 spans December of 4 into January of 5.
  assert_eq(days_from_civil(5, 1, 1) - days_from_civil(4, 12, 31), 1L)
}
