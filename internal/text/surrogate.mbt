// Shared UTF-16 well-formedness guard for every serialiser that hands a
// MoonBit string to a UTF-8 encoder: the core encoder aborts on an
// unpaired surrogate, so each writer that can meet one checks first and
// refuses with its own located error instead — one copy of the predicate
// rather than one per serialiser, where a new writer could forget it.

///|
/// Count the characters of `content` the way this engine's WTF-8 readers
/// do: a well-formed surrogate pair counts as one, and an unpaired
/// surrogate half counts as one of its own. Core's `String::char_length`
/// cannot be used here — it aborts on a high surrogate followed by a
/// non-low unit, and MoonBit strings legally hold such halves.
pub fn char_count_wtf8(content : String) -> Int32 {
  let units = content.code_units()
  let n = units.length()
  let mut i = 0
  let mut count = 0
  while i < n {
    if units[i].is_leading_surrogate() &&
      i + 1 < n &&
      units[i + 1].is_trailing_surrogate() {
      i += 2
    } else {
      i += 1
    }
    count += 1
  }
  count
}

///|
/// Return the code-unit index of the first unpaired UTF-16 surrogate in
/// `content`, or `None` when the string is well-formed. A high surrogate
/// (`0xD800`–`0xDBFF`) must be immediately followed by a low surrogate
/// (`0xDC00`–`0xDFFF`); a low surrogate anywhere else is unpaired.
pub fn find_unpaired_surrogate(content : String) -> Int32? {
  let units = content.code_units()
  let n = units.length()
  let mut i = 0
  while i < n {
    let cu = units[i]
    if cu.is_leading_surrogate() {
      if i + 1 < n && units[i + 1].is_trailing_surrogate() {
        i += 2
        continue
      }
      return Some(i)
    }
    if cu.is_trailing_surrogate() {
      return Some(i)
    }
    i += 1
  }
  None
}
