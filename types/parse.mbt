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
    // `@string.parse_double` fails for two disjoint reasons: a genuine
    // non-number, or a finite literal whose magnitude overflows `Double`. Per
    // IEEE 754 (and the documented String→Float contract) the overflow case
    // rounds to a signed `Infinity` rather than failing — matching the explicit
    // `inf` literal and pandas / polars — while a genuine non-number stays
    // `None`. We tell them apart *structurally*: if `s` is valid finite-decimal
    // syntax yet parsing failed, an overflow past `Double::MAX` is the only
    // possible cause. This deliberately avoids matching the stdlib's
    // human-readable error text (previously the load-bearing
    // `"value out of range"`), so a reworded or typed stdlib error can no longer
    // silently flip an overflowing literal to `None`. The sign is a leading `-`
    // (`parse_double` accepts no leading whitespace).
    _ =>
      if is_finite_decimal_literal(s) {
        Some(
          if s.view().get_char(0) == Some('-') {
            @double.neg_infinity
          } else {
            @double.infinity
          },
        )
      } else {
        None
      }
  } noraise {
    x => Some(x)
  }
}

///|
/// `true` when `s` is a syntactically valid **finite** decimal float literal —
/// an optional `+` / `-` sign, a mantissa carrying at least one digit (`123`,
/// `1.5`, `1.`, `.5`), and an optional `e` / `E` exponent whose own sign is
/// optional but which needs at least one digit. It deliberately rejects the
/// `nan` / `inf` / `infinity` forms (those *parse*, so never reach the caller's
/// failure path), the `0x…` hex-float form (`@string.parse_double` rejects it
/// too), and `1_000` underscore grouping (screened earlier). The grammar is a
/// subset of what `parse_double` accepts as a finite number, so a `true` result
/// guarantees the parse failure was overflow, never a syntax error. Backs
/// `parse_plain_double_opt`'s structural overflow / non-number split, replacing
/// a match on the stdlib's error message.
fn is_finite_decimal_literal(s : String) -> Bool {
  let n = s.length()
  let mut i = 0
  if i < n && (s[i] == '+' || s[i] == '-') {
    i = i + 1
  }
  let mut mantissa_digits = 0
  while i < n && s[i] >= '0' && s[i] <= '9' {
    i = i + 1
    mantissa_digits = mantissa_digits + 1
  }
  if i < n && s[i] == '.' {
    i = i + 1
    while i < n && s[i] >= '0' && s[i] <= '9' {
      i = i + 1
      mantissa_digits = mantissa_digits + 1
    }
  }
  if mantissa_digits == 0 {
    return false
  }
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    i = i + 1
    if i < n && (s[i] == '+' || s[i] == '-') {
      i = i + 1
    }
    let mut exp_digits = 0
    while i < n && s[i] >= '0' && s[i] <= '9' {
      i = i + 1
      exp_digits = exp_digits + 1
    }
    if exp_digits == 0 {
      return false
    }
  }
  i == n
}
