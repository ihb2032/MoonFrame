// Canonical string ordering for MoonFrame. MoonBit's built-in `<` /
// `Compare` on `String` is shortlex (length first, then code unit), which
// surprises users expecting dictionary order, so every user-facing ordering
// routes through the helper here instead. Kept in its own file — mirroring
// `parse.mbt`'s `is_decimal_int_literal` — rather than inside `scalar.mbt`,
// because it is a free string-ordering function, not part of the `Scalar`
// value type.
//
// One-file-one-test exemption: this free helper has no dedicated
// `compare_test.mbt`. It is covered through the `Scalar::lt`, `Series::min` /
// `max`, and `sort_by` tests that route their string ordering through it.

///|
/// Lexicographic string comparison by UTF-16 code unit, returning the
/// usual `-1` / `0` / `1`. MoonBit's built-in `<` / `Compare` on `String`
/// is **shortlex** (length first, then code unit) — e.g. `"fig" < "apple"`
/// is `true` because `"fig"` is shorter, which surprises users expecting
/// dictionary order. Every user-facing ordering in MoonFrame (`Scalar::lt`,
/// `Series::min` / `max`, `DataFrame::sort_by`) routes through this helper
/// instead of the built-in operator so they all agree.
///
/// Ordering is by UTF-16 code unit, so it matches pandas / SQL dictionary
/// order across the Basic Multilingual Plane (the common case). It can
/// diverge for supplementary-plane characters, whose surrogate code units
/// (`0xD800`–`0xDBFF`) sort *below* high-BMP code points rather than above
/// them — a code-point-accurate comparison is deferred to a later release.
pub fn compare_string_lex(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  for i in 0..<n {
    let ca = a[i]
    let cb = b[i]
    if ca < cb {
      return -1
    }
    if ca > cb {
      return 1
    }
  }
  if la < lb {
    -1
  } else if la > lb {
    1
  } else {
    0
  }
}
