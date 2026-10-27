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
test "map_case: Final_Sigma lowercases a word-final Σ to ς" {
  // The one contextual rule the default conversion carries, matching
  // Rust's `str::to_lowercase`: Σ maps to ς when preceded by a
  // cased letter and not followed by one (skipping Case_Ignorable
  // characters on both sides), to σ when medial or word-initial.
  assert_eq(map_case("ΟΔΟΣ", upper=false), "οδος") // final after Δ
  assert_eq(map_case("ΟΣΑ", upper=false), "οσα") // word-initial: no cased before
  assert_eq(map_case("ΑΣ,Σ", upper=false), "ας,σ") // the second starts a word
  assert_eq(map_case("ΑΣ\u{345}Α", upper=false), "ασ\u{345}α") // ignorable then cased: medial
  assert_eq(map_case("ΑΣ\u{345}.", upper=false), "ας\u{345}.") // ignorable then nothing: final
  assert_eq(map_case("Α\u{345}Σ", upper=false), "α\u{345}ς") // ignorable before: still final
  // Upper-casing never reads the context.
  assert_eq(map_case("οδος", upper=true), "ΟΔΟΣ")
}
