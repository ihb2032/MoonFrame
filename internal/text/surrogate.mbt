// Shared UTF-16 well-formedness guard for every serialiser that hands a
// MoonBit string to a UTF-8 encoder: the core encoder aborts on an
// unpaired surrogate, so each writer that can meet one checks first and
// refuses with its own located error instead — one copy of the predicate
// rather than one per serialiser, where a new writer could forget it.

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
