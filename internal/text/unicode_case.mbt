// The Unicode default case conversion and the `White_Space` property —
// the hand-written half of the case machinery; the sorted mapping tables
// it searches live in the generated file beside this one, regenerated from
// the UCD by the tracked generator script.

///|
/// Index of the entry whose source code point is `cp`, in a table sorted
/// ascending by it — the shared search of the simple and special lookups,
/// stated once so the two cannot drift apart (a fix to one loop is a fix
/// to both).
fn[T] entry_index(table : Array[(UInt32, T)], cp : UInt32) -> Int32? {
  let mut lo = 0
  let mut hi = table.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let (from, _) = table[mid]
    if cp == from {
      return Some(mid)
    } else if cp < from {
      hi = mid - 1
    } else {
      lo = mid + 1
    }
  }
  None
}

///|
/// Binary search over a sorted `(from, to)` table: the mapped code point,
/// or `cp` itself when the table has no entry — the common case, since most
/// code points carry no case mapping at all.
fn case_lookup(table : Array[(UInt32, UInt32)], cp : UInt32) -> UInt32 {
  match entry_index(table, cp) {
    Some(i) => {
      let (_, to) = table[i]
      to
    }
    None => cp
  }
}

///|
/// Binary search over the sorted special table: the expanding mapping's
/// targets, or `None` when this code point has no special entry. A
/// one-to-one entry here repeats the simple mapping (the generator's
/// condition is not-identity, not differs-from-simple) — harmless: the
/// answer equals the simple one's exactly there.
fn special_lookup(
  table : Array[(UInt32, Array[UInt32])],
  cp : UInt32,
) -> Array[UInt32]? {
  match entry_index(table, cp) {
    Some(i) => {
      let (_, to) = table[i]
      Some(to)
    }
    None => None
  }
}

///|
/// Whether a code point falls inside one of the ascending, disjoint ranges
/// of a derived property — the membership test `Final_Sigma` reads off the
/// `Cased` and `Case_Ignorable` tables.
fn in_ranges(ranges : Array[(UInt32, UInt32)], cp : UInt32) -> Bool {
  let mut lo = 0
  let mut hi = ranges.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let (first, last) = ranges[mid]
    if cp < first {
      hi = mid - 1
    } else if cp > last {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// `Final_Sigma` (SpecialCasing.txt): `Σ` maps to `ς` iff it is preceded by
/// a cased letter and not followed by one, skipping `Case_Ignorable`
/// characters on both sides — the one contextual rule the *default* case
/// conversion carries (Rust's `str::to_lowercase` applies it too).
fn final_sigma(chars : Array[Char], i : Int32) -> Bool {
  // Backward from the sigma: the first non-ignorable character must be a
  // cased one ("ΟΔΟΣ" — Δ before the final sigma).
  let mut j = i - 1
  while j >= 0 && in_ranges(unicode_case_ignorable, chars[j].to_uint()) {
    j = j - 1
  }
  let cased_before = j >= 0 && in_ranges(unicode_cased, chars[j].to_uint())
  // Forward: a cased character behind any run of ignorables makes the
  // sigma medial.
  let mut k = i + 1
  while k < chars.length() &&
        in_ranges(unicode_case_ignorable, chars[k].to_uint()) {
    k = k + 1
  }
  let cased_after = k < chars.length() &&
    in_ranges(unicode_cased, chars[k].to_uint())
  cased_before && !cased_after
}

///|
/// Map every character of a string through the Unicode **default case
/// conversion** — simple mappings one character to one character, plus the
/// SpecialCasing expansions where the default conversion is one-to-many
/// (`ß` uppercases to `SS`, the `ﬁ` ligature to `FI`), plus the one
/// contextual rule the default conversion carries, `Final_Sigma`: a
/// word-final `Σ` lowercases to `ς`, a medial one to `σ`, by the cased /
/// case-ignorable characters around it. Characters without a mapping pass
/// through unchanged. The conditional *locale* lines of SpecialCasing —
/// the Turkish dotless rules — are not in the table: the default conversion
/// carries no locale, so `İ` lowercases to `i` + combining dot above
/// everywhere.
pub fn map_case(s : String, upper~ : Bool) -> String {
  let specials = if upper {
    unicode_special_upper
  } else {
    unicode_special_lower
  }
  let buf = StringBuilder()
  // `Final_Sigma` — the one contextual rule, lower direction only — reads
  // both neighbours of a capital sigma, so only a string that actually
  // carries one pays for the collected array its neighbour reads need;
  // everything else walks the iterator directly, allocating nothing per
  // character.
  let has_sigma = !upper && s.iter().any(ch => ch.to_uint() == 0x03A3)
  if has_sigma {
    let chars : Array[Char] = []
    for ch in s.iter() {
      chars.push(ch)
    }
    for i in 0..<chars.length() {
      let cp = chars[i].to_uint()
      if cp == 0x03A3 {
        // Final_Sigma answers \u{3C2} vs \u{3C3}; the simple table would
        // say \u{3C3} either way.
        let sigma : UInt32 = if final_sigma(chars, i) { 0x03C2 } else { 0x03C3 }
        // Safe by construction: both are Unicode scalar values.
        buf.write_char(sigma.reinterpret_as_int().unsafe_to_char())
        continue
      }
      append_case_char(buf, specials, cp, upper~)
    }
  } else {
    for ch in s.iter() {
      append_case_char(buf, specials, ch.to_uint(), upper~)
    }
  }
  buf.to_string()
}

///|
/// One character's case mapping appended to `buf`: ASCII takes the
/// arithmetic arm — the two lookup tables hold no ASCII *source* rows
/// (ASCII case is one-to-one and unconditional, `a`-`z` and `A`-`Z` are
// 32 apart, every other ASCII code point is its own mapping) — and the
// rest of the range consults the special expansions, then the simple

///|
/// table.
fn append_case_char(
  buf : StringBuilder,
  specials : Array[(UInt32, Array[UInt32])],
  cp : UInt32,
  upper~ : Bool,
) -> Unit {
  if cp < 0x80 {
    let letter : UInt32 = if upper && cp >= 0x61 && cp <= 0x7A {
      cp - 32
    } else if !upper && cp >= 0x41 && cp <= 0x5A {
      cp + 32
    } else {
      cp
    }
    // Safe by construction: an ASCII code point is a Unicode scalar value.
    buf.write_char(letter.reinterpret_as_int().unsafe_to_char())
    return
  }
  match special_lookup(specials, cp) {
    Some(targets) =>
      for t in targets {
        // Safe by construction: the generated table maps Unicode
        // scalar values to Unicode scalar values.
        buf.write_char(t.reinterpret_as_int().unsafe_to_char())
      }
    None => {
      let mapped = if upper {
        case_lookup(unicode_simple_upper, cp)
      } else {
        case_lookup(unicode_simple_lower, cp)
      }
      // Safe by construction: a mapped code point is a Unicode scalar
      // value (the table only maps scalars to scalars), and an unmapped
      // one came from a `Char` in the first place.
      buf.write_char(mapped.reinterpret_as_int().unsafe_to_char())
    }
  }
}

///|
/// The Unicode `White_Space` property as a charset string — the characters
/// the default `str_strip_chars` trims. A closed list, stable since Unicode
/// 6.3: the ASCII set (`\t` through `\r`, space) plus NEL, NBSP, OGHAM,
/// the typographic quads, the line / paragraph separators, the narrow and
/// mathematical spaces, and the ideographic space. The custom charset a
/// caller passes stays a caller's list.
pub fn unicode_white_space() -> String {
  "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{85}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"
}
