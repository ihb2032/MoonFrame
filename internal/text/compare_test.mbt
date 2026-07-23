// Direct tests for `@text.compare_string_lex` — the canonical code-point
// string ordering every user-facing sort / min / max routes through.

///|
test "compare_string_lex: dictionary order across the BMP" {
  assert_eq(compare_string_lex("apple", "banana"), -1)
  assert_eq(compare_string_lex("banana", "apple"), 1)
  assert_eq(compare_string_lex("ab", "ac"), -1)
  assert_eq(compare_string_lex("ab", "ab"), 0)
}

///|
test "compare_string_lex: a prefix sorts before the longer string" {
  assert_eq(compare_string_lex("ab", "abc"), -1)
  assert_eq(compare_string_lex("abc", "ab"), 1)
}

///|
test "compare_string_lex: supplementary-plane chars sort by code point, not surrogate unit" {
  // U+1F600 (😀, code point 128512) vs U+E000 (private-use, 57344). By true
  // code point the emoji is far larger; a raw UTF-16 comparison would instead
  // rank the emoji's leading surrogate 0xD83D (55357) *below* U+E000 (57344),
  // which is the bug this ordering fixes.
  let emoji = "\u{1F600}"
  let bmp = "\u{E000}"
  assert_eq(compare_string_lex(emoji, bmp), 1)
  assert_eq(compare_string_lex(bmp, emoji), -1)
  assert_eq(compare_string_lex(emoji, emoji), 0)
  // Two supplementary-plane chars order by their scalar value too.
  assert_eq(compare_string_lex("\u{1F600}", "\u{1F601}"), -1)
}
