///|
/// `true` when `s` is an optional `+` / `-` sign followed by one or more
/// ASCII decimal digits and nothing else. Empty / sign-only strings,
/// `0x` / `0o` / `0b` base prefixes, and `1_000` underscore grouping all
/// return `false`.
///
/// Numeric recognition lives here, in `types`, so every layer agrees on
/// what counts as an integer literal: the CSV / JSON readers' type
/// inference and the `@column` String→`Int` cast all route through this
/// one predicate before handing the text to `@string.parse_int64`. That
/// parser defaults to `base = 0` and would otherwise silently accept hex
/// / octal / binary prefixes (`0xFF` → 255) and underscores (`1_000` →
/// 1000) — forms pandas / polars keep as strings. Sharing the screen (the
/// way every ordering routes through `compare_string_lex`) keeps an
/// explicit cast consistent with what the reader inferred for the same
/// text.
pub fn is_decimal_int_literal(s : String) -> Bool {
  let mut seen_digit = false
  let mut first = true
  for ch in s.iter() {
    if first && (ch == '+' || ch == '-') {
      first = false
      continue
    }
    first = false
    if ch < '0' || ch > '9' {
      return false
    }
    seen_digit = true
  }
  seen_digit
}
