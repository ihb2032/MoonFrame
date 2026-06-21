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

///|
/// Parse a plain base-10 integer, or `None`. Screens out `0x` / `0o` / `0b`
/// prefixes and `1_000` underscore grouping via `is_decimal_int_literal` (the
/// forms pandas / polars keep as strings), then hands the text to
/// `@string.parse_int64`, mapping its failure (a value beyond `Int64`'s range,
/// say) to `None`. The shared routine behind the CSV reader's `Int` inference
/// and the `@column` String→`Int` cast, so an inferred column and an explicit
/// cast agree on what text is an integer.
pub fn parse_decimal_int_opt(s : String) -> Int64? {
  if !is_decimal_int_literal(s) {
    return None
  }
  try @string.parse_int64(s.view()) catch {
    _ => None
  } noraise {
    n => Some(n)
  }
}

///|
/// Parse a "plain" `Double`, or `None`. Rejects `1_000`-style underscore
/// grouping up front (`@string.parse_double` would accept it, but pandas /
/// polars keep such cells as strings), then hands the text to
/// `@string.parse_double`. The `nan` / `inf` / `infinity` literals it
/// recognises are returned as-is — the caller decides whether to keep them (the
/// CSV reader gates them behind `allow_nonfinite`; the `@column` String→`Float`
/// cast accepts them). A finite literal beyond the `Double` range collapses to
/// a signed `Infinity` (IEEE 754 overflow), exactly like the explicit `inf`
/// literal — so it too is gated by `allow_nonfinite` on the CSV path, rather
/// than being rejected as unparseable. Shared so inference and an explicit cast
/// agree on what text is a `Float`.
pub fn parse_plain_double_opt(s : String) -> Double? {
  if s.iter().any(c => c == '_') {
    return None
  }
  try @string.parse_double(s.view()) catch {
    // A finite literal past the `Double` range raises "value out of range"; per
    // IEEE 754 (and the documented String→Float contract) that rounds to a
    // signed `Infinity` rather than failing. The sign is a leading `-`
    // (`parse_double` accepts no leading whitespace). Any other failure
    // ("invalid syntax") is a genuine non-number and stays `None`.
    //
    // Coupling note: this matches the exact message string `@string.parse_double`
    // raises today (`@internal/strconv`'s `range_err_str`). It is load-bearing —
    // were the stdlib to reword that message or switch to a typed error, an
    // overflowing literal would fall through to `None` and silently flip CSV
    // inference / the String→Float cast. The boundary cases in `parse_test.mbt`
    // (`1e999` / `1.8e308` / `-1e999` → signed `Infinity`) pin this, so such a
    // drift fails loudly in CI rather than silently here.
    Failure::Failure("value out of range") =>
      Some(
        if s.view().get_char(0) == Some('-') {
          @double.neg_infinity
        } else {
          @double.infinity
        },
      )
    _ => None
  } noraise {
    x => Some(x)
  }
}
