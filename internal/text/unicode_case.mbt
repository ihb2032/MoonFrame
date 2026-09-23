// The Unicode default case conversion and the `White_Space` property —
// the hand-written half of the case machinery; the sorted mapping tables
// it searches live in the generated file beside this one, regenerated from
// the UCD by the tracked generator script.

///|
/// The simple uppercase mapping of one code point, or the code point itself
/// when it has none — one binary search over the sorted generated table.
fn simple_upper(cp : UInt) -> UInt {
  case_lookup(unicode_simple_upper, cp)
}

///|
/// The simple lowercase mapping of one code point, or the code point itself
/// when it has none.
fn simple_lower(cp : UInt) -> UInt {
  case_lookup(unicode_simple_lower, cp)
}

///|
/// Binary search over a sorted `(from, to)` table: the mapped code point,
/// or `cp` itself when the table has no entry — the common case, since most
/// code points carry no case mapping at all.
fn case_lookup(table : Array[(UInt, UInt)], cp : UInt) -> UInt {
  let mut lo = 0
  let mut hi = table.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let (from, to) = table[mid]
    if cp == from {
      return to
    } else if cp < from {
      hi = mid - 1
    } else {
      lo = mid + 1
    }
  }
  cp
}

///|
/// Binary search over the sorted special table: the expanding mapping's
/// targets, or `None` when this code point's case conversion is the simple
/// one (or identity) — the table only carries where the default conversion
/// differs from the simple mapping.
fn special_lookup(
  table : Array[(UInt, Array[UInt])],
  cp : UInt,
) -> Array[UInt]? {
  let mut lo = 0
  let mut hi = table.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let (from, to) = table[mid]
    if cp == from {
      return Some(to)
    } else if cp < from {
      hi = mid - 1
    } else {
      lo = mid + 1
    }
  }
  None
}

///|
/// Map every character of a string through the Unicode **default case
/// conversion** — simple mappings one character to one character, plus the
/// SpecialCasing expansions where the default conversion is one-to-many
/// (`ß` uppercases to `SS`, the `ﬁ` ligature to `FI`). Characters without a
/// mapping pass through unchanged. The locale-conditional lines of
/// SpecialCasing are not in the table: this is the default conversion,
/// which carries no locale, so `İ` lowercases to `i` + combining dot above
/// everywhere, and the Turkish dotless rules stay a caller's rewrite.
pub fn map_case(s : String, upper~ : Bool) -> String {
  let specials = if upper {
    unicode_special_upper
  } else {
    unicode_special_lower
  }
  let buf = StringBuilder()
  for ch in s.iter() {
    let cp = ch.to_uint()
    match special_lookup(specials, cp) {
      Some(targets) =>
        for t in targets {
          // Safe by construction: the generated table maps Unicode
          // scalar values to Unicode scalar values.
          buf.write_char(t.reinterpret_as_int().unsafe_to_char())
        }
      None => {
        let mapped = if upper { simple_upper(cp) } else { simple_lower(cp) }
        // Safe by construction: a mapped code point is a Unicode scalar
        // value (the table only maps scalars to scalars), and an unmapped
        // one came from a `Char` in the first place.
        buf.write_char(mapped.reinterpret_as_int().unsafe_to_char())
      }
    }
  }
  buf.to_string()
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
