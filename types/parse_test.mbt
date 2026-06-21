// Blackbox tests for `@types.is_decimal_int_literal` — the shared
// integer-literal screen the CSV / JSON readers and the `@column`
// String→Int cast all route through.

///|
test "is_decimal_int_literal: accepts plain and signed decimals" {
  assert_eq(is_decimal_int_literal("42"), true)
  assert_eq(is_decimal_int_literal("-7"), true)
  assert_eq(is_decimal_int_literal("+7"), true)
  assert_eq(is_decimal_int_literal("0"), true)
}

///|
test "is_decimal_int_literal: rejects base prefixes and underscores" {
  // `@string.parse_int` (base=0) would accept all of these; the screen
  // keeps them as strings, matching pandas / polars.
  assert_eq(is_decimal_int_literal("0xFF"), false)
  assert_eq(is_decimal_int_literal("0o17"), false)
  assert_eq(is_decimal_int_literal("0b101"), false)
  assert_eq(is_decimal_int_literal("1_000"), false)
}

///|
test "is_decimal_int_literal: rejects empty, sign-only, and non-numeric" {
  assert_eq(is_decimal_int_literal(""), false)
  assert_eq(is_decimal_int_literal("-"), false)
  assert_eq(is_decimal_int_literal("12a"), false)
  assert_eq(is_decimal_int_literal(" 42"), false)
}

///|
test "parse_plain_double_opt: an out-of-range finite literal overflows to signed Infinity" {
  // IEEE 754 overflow — the documented String→Float contract, matching the
  // explicit `inf` literal and pandas / polars rather than rejecting the cell.
  assert_eq(parse_plain_double_opt("1e999"), Some(@double.infinity))
  assert_eq(parse_plain_double_opt("1.8e308"), Some(@double.infinity))
  assert_eq(parse_plain_double_opt("-1e999"), Some(@double.neg_infinity))
  // In-range values are untouched; genuine non-numbers and underscore grouping
  // stay None.
  assert_eq(parse_plain_double_opt("1.5"), Some(1.5))
  assert_eq(parse_plain_double_opt("nope"), None)
  assert_eq(parse_plain_double_opt("1_000"), None)
}

///|
test "parse_decimal_int_opt pins the Int64 ceiling: max parses, past it is None" {
  // The int overflow boundary is asymmetric to the float one (which saturates to
  // Infinity): an Int64-overflowing literal drops to None so CSV inference keeps
  // it a String. Pinned at the exact ceiling, mirroring the double test above.
  assert_eq(
    parse_decimal_int_opt("9223372036854775807"),
    Some(9223372036854775807L),
  )
  assert_true(parse_decimal_int_opt("-9223372036854775808") is Some(_))
  assert_eq(parse_decimal_int_opt("9223372036854775808"), None)
  assert_eq(parse_decimal_int_opt("-9223372036854775809"), None)
}
