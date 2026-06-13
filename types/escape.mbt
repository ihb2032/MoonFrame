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
/// characters newline / carriage-return / tab become `\n` / `\r` / `\t` so
/// the quoted form stays unambiguous and on a single line. A single forward
/// pass, so a backslash introduced here is never itself re-escaped. Total —
/// pure string assembly, no failure path.
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
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}
