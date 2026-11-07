// Direct tests for `compare_string_lex` — the canonical code-point
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
  // The empty string is a prefix of everything, so it sorts first.
  assert_eq(compare_string_lex("", "a"), -1)
}

///|
test "compare_string_lex: dictionary order where the built-in shortlex disagrees" {
  // The reason this helper exists: MoonBit's built-in `<` on `String` is
  // shortlex — length first — so it calls "fig" < "apple"; the dictionary
  // order every user-facing sort routes through says the opposite.
  assert_true("fig" < "apple")
  assert_eq(compare_string_lex("fig", "apple"), 1)
}

///|
/// One-code-unit string holding an isolated UTF-16 surrogate half —
/// moonc rejects `\u{D800}` in a literal, so the raw unit is assembled
/// directly (the same route the io corpus's surrogate fixtures take).
fn lone_surrogate_str(code_unit : Int32) -> String {
  let b = StringBuilder()
  b.write_char(Int32::unsafe_to_char(code_unit))
  b.to_string()
}

///|
test "compare_string_lex: an isolated surrogate orders by its code-unit value" {
  // A lone half is a code point of its own code-unit value — 0xD800
  // (55296) and 0xDFFF (57343) both sort below U+E000 (57344) — while the
  // same leading unit in a *pair* recombines to U+10000 (65536) and sorts
  // above it: the pair walk and the lone-unit walk disagree, by design.
  assert_eq(compare_string_lex(lone_surrogate_str(0xD800), "\u{E000}"), -1)
  assert_eq(compare_string_lex(lone_surrogate_str(0xDFFF), "\u{E000}"), -1)
  assert_eq(compare_string_lex("\u{10000}", "\u{E000}"), 1)
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
