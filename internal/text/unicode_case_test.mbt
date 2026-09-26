// Direct tests for `map_case` — the Unicode default case conversion table.
// The BMP entries and the expanding SpecialCasing mappings are pinned by the
// string-operator suite that consumes this kernel (the `str_to_uppercase` /
// `str_to_lowercase` verbs); these pick the supplementary-plane scripts
// whose 1:1 mappings exercise the table beyond the BMP — code points a
// generator regression could silently drop with no other test failing —
// and pin the conditional-lines claim of the docstring.

///|
test "map_case: supplementary-plane scripts case-map through the table" {
  // Deseret (the U+10400 block): the block's own capital / small pair,
  // both directions.
  assert_eq(map_case("\u{10428}", upper=true), "\u{10400}")
  assert_eq(map_case("\u{10400}", upper=false), "\u{10428}")
  // Adlam and Cherokee: lower-case blocks mapping up into their capital
  // blocks — Cherokee's small script is the Unicode 8.0 addition whose
  // lower block (U+AB70) sits far from its capitals (U+13A0).
  assert_eq(map_case("\u{1E922}", upper=true), "\u{1E900}")
  assert_eq(map_case("\u{AB70}", upper=true), "\u{13A0}")
}

///|
test "map_case: the default conversion carries no context — a word-final Σ stays σ" {
  // A word-final Σ lowercases to ς only under SpecialCasing's
  // Final_Sigma condition, which the table skips: the default conversion
  // maps Σ → σ in every position, the reading Polars and Rust's
  // `char::to_lowercase` give.
  assert_eq(map_case("ΟΔΟΣ", upper=false), "οδοσ")
}
