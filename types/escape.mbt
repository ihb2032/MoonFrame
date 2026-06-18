// Debug-rendering helper shared by the handwritten `Show` impls in this
// package (`Scalar`, `DataError`, and `Field` — and through `Field`, the
// `Schema`). Those impls wrap a string payload in double quotes
// (`String("ab")`, `ColumnNotFound("age")`, `Field { name: "age", ... }`),
// so a payload that itself contains a `"` or `\` would otherwise render
// ambiguously and non-round-trippably (`String("a"b")`). Escaping `\`, `"`,
// and the control characters `\n` / `\r` / `\t` keeps the quoted form
// unambiguous and on one line, the way a debug renderer escapes a
// string literal. The value-form rendering (`Scalar::to_string`) does not
// quote, so it is deliberately left untouched — only the variant / struct
// `Show` forms escape.
//
// One-file-one-test exemption: this helper has no dedicated
// `escape_test.mbt`. It is covered through the `Scalar` / `DataError` /
// `Field` `Show` tests that render payloads containing `"` and `\`.

///|
/// Escape `s` for embedding inside a double-quoted debug rendering: a
/// backslash becomes `\\`, a double quote becomes `\"`, and the control
/// characters newline / carriage-return / tab become `\n` / `\r` / `\t`.
/// Every other control character — the rest of the C0 range, `DEL`, and the
/// Unicode line/paragraph separators `NEL` / `LS` / `PS` — becomes a `\uXXXX`
/// escape, so a hostile payload (e.g. an `ESC` from a malformed CSV header)
/// cannot inject a newline or forge an extra line into the quoted form. (The
/// escape set targets line injection; the C1 range 0x80–0x9F is left as-is —
/// harmless under UTF-8 output, which emits it as multi-byte sequences rather
/// than raw 8-bit controls.) A single forward pass, so a backslash introduced
/// here is never itself re-escaped. Total — pure string assembly, no failure
/// path.
fn escape_debug(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s.iter() {
    if ch == '\\' {
      buf.write_char('\\')
      buf.write_char('\\')
    } else if ch == '"' {
      buf.write_char('\\')
      buf.write_char('"')
    } else if ch == '\n' {
      buf.write_char('\\')
      buf.write_char('n')
    } else if ch == '\r' {
      buf.write_char('\\')
      buf.write_char('r')
    } else if ch == '\t' {
      buf.write_char('\\')
      buf.write_char('t')
    } else if is_control_char(ch) {
      write_unicode_escape(buf, ch)
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// Whether `ch` is a control character that must be `\uXXXX`-escaped in a
/// debug rendering (the C0 range, `DEL`, and the Unicode line/paragraph
/// separators). `\n` / `\r` / `\t` are handled by their own short escapes
/// before this is consulted.
fn is_control_char(ch : Char) -> Bool {
  let cp = ch.to_int()
  cp < 0x20 || cp == 0x7f || cp == 0x85 || cp == 0x2028 || cp == 0x2029
}

///|
/// Append the `\uXXXX` (four lowercase hex digits) escape of `ch` to `buf`.
/// Every escaped code point (C0 / DEL / the separators) is below `U+10000`,
/// so four digits suffice.
fn write_unicode_escape(buf : StringBuilder, ch : Char) -> Unit {
  let digits = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let cp = ch.to_int()
  buf.write_char('\\')
  buf.write_char('u')
  buf.write_char(digits[(cp >> 12) & 0xF])
  buf.write_char(digits[(cp >> 8) & 0xF])
  buf.write_char(digits[(cp >> 4) & 0xF])
  buf.write_char(digits[cp & 0xF])
}
