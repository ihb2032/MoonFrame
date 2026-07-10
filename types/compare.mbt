// Canonical string ordering for MoonFrame. MoonBit's built-in `<` /
// `Compare` on `String` is shortlex (length first, then code unit), which
// surprises users expecting dictionary order, so every user-facing ordering
// routes through the helper here instead. Kept in its own file — mirroring
// `parse.mbt`'s `is_decimal_int_literal` — rather than inside `scalar.mbt`,
// because it is a free string-ordering function, not part of the `Scalar`
// value type.
//
// Direct tests live in `compare_test.mbt` (code-point ordering, surrogate-pair
// recombination, prefix / equality); the `Scalar::lt`, `Series::min` / `max`,
// and `sort` tests additionally exercise it end-to-end.

///|
/// Lexicographic string comparison by **Unicode code point**, returning the
/// usual `-1` / `0` / `1`. MoonBit's built-in `<` / `Compare` on `String` is
/// **shortlex** (length first, then code unit) — e.g. `"fig" < "apple"` is
/// `true` because `"fig"` is shorter, which surprises users expecting
/// dictionary order. Every user-facing ordering in MoonFrame (`Scalar::lt`,
/// `Series::min` / `max`, `DataFrame::sort`) routes through this helper
/// instead of the built-in operator so they all agree.
///
/// Comparison is by Unicode scalar value, so it matches pandas / SQL
/// dictionary order across the whole code space, **including the supplementary
/// planes**: each `String` is walked one code point at a time (surrogate pairs
/// recombined via `code_point_at`), so an emoji (`U+1F600`) sorts *above* a
/// high-BMP character (`U+E000`) by its true scalar value — where a raw UTF-16
/// code-unit comparison ranked the emoji's leading surrogate (`0xD83D`) below
/// it. The walk allocates nothing and stops at the first differing code point,
/// or when the shorter string (a prefix of the longer) runs out.
pub fn compare_string_lex(a : String, b : String) -> Int {
  let na = a.length()
  let nb = b.length()
  let mut ia = 0
  let mut ib = 0
  while ia < na && ib < nb {
    let (ca, ia_next) = code_point_at(a, ia)
    let (cb, ib_next) = code_point_at(b, ib)
    if ca < cb {
      return -1
    }
    if ca > cb {
      return 1
    }
    ia = ia_next
    ib = ib_next
  }
  // The loop stops once at least one string is exhausted. Whichever still has
  // code units left has more code points (the other is its prefix), so it
  // sorts after; both exhausted together means equal.
  if ia < na {
    1
  } else if ib < nb {
    -1
  } else {
    0
  }
}

///|
/// Decode the Unicode code point beginning at UTF-16 code-unit index `i` of
/// `s`, returning `(code_point, next_index)`. A high surrogate
/// (`0xD800`–`0xDBFF`) immediately followed by a low surrogate
/// (`0xDC00`–`0xDFFF`) recombines into one supplementary code point
/// (`≥ U+10000`); a lone surrogate or an ordinary BMP unit is returned as-is,
/// advancing a single unit. Lets `compare_string_lex` order by code point
/// without materialising a `Char` array per comparison.
fn code_point_at(s : String, i : Int) -> (Int, Int) {
  let hi = s[i].to_int()
  if hi >= 0xD800 && hi <= 0xDBFF && i + 1 < s.length() {
    let lo = s[i + 1].to_int()
    if lo >= 0xDC00 && lo <= 0xDFFF {
      return ((hi - 0xD800) * 0x400 + (lo - 0xDC00) + 0x10000, i + 2)
    }
  }
  (hi, i + 1)
}
