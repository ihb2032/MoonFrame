// The column logic of a fixed-width text reader: where each line's fields
// start and end, and how a line is cut into them. It answers boundaries and
// strings only. Nothing here is typed, no null is recognised and no header
// is chosen: the reader that calls it does those with the cells it hands
// back.
//
// A position is a character counted from the line's first — a code point,
// the way the reference reader measures a line — never a byte and never a
// UTF-16 code unit. A string here is a sequence of code units, so every
// position is found by walking them: a well-formed surrogate pair is one
// character and an unpaired half is one character too, since a string may
// hold one and no line may stop the walk.

///|
/// The most a boundary names: a position is a 32-bit signed integer.
const FURTHEST : Int32 = 2147483647

///|
/// Whether a character separates fields, by the code unit it starts with:
/// a space, a tab, a carriage return or a line feed, and nothing else. The
/// other Unicode spaces and the other control characters are content. The
/// four are one code unit wide, so the first unit decides.
fn is_separator(unit : Int32) -> Bool {
  unit == 0x20 || unit == 0x09 || unit == 0x0D || unit == 0x0A
}

///|
/// A line under way, one character at a time: `unit` is where the next
/// character starts, in code units from the line's first, and `place` is
/// that position in characters.
priv struct Walk {
  units : ArrayView[UInt16]
  mut unit : Int32
  mut place : Int32
}

///|
/// A walk over `line`, before its first character.
fn Walk::Walk(line : String) -> Walk {
  { units: line.code_units(), unit: 0, place: 0, }
}

///|
/// The next character, as the code unit it starts with, stepping over it:
/// `None` once the line is read. A well-formed surrogate pair is stepped
/// over as one character. Every unit is read after the length has shown
/// it is there.
fn Walk::take(self : Walk) -> Int32? {
  let units = self.units
  let at = self.unit
  if at >= units.length() {
    None
  } else {
    let first = units[at]
    let pair = first.is_leading_surrogate() &&
      at + 1 < units.length() &&
      units[at + 1].is_trailing_surrogate()
    self.unit = if pair { at + 2 } else { at + 1 }
    self.place += 1
    Some(first.to_int())
  }
}

///|
/// The characters of the walk's line from `from` to `to` — two positions
/// in code units, as the walk answers them — with the separators at each
/// end cut: where the content of that stretch begins and ends. The two are
/// equal when the stretch holds nothing else.
fn Walk::trimmed(self : Walk, from : Int32, to : Int32) -> (Int32, Int32) {
  let units = self.units
  let mut first = from
  let mut last = to
  while first < last && is_separator(units[first].to_int()) {
    first += 1
  }
  while last > first && is_separator(units[last - 1].to_int()) {
    last -= 1
  }
  (first, last)
}
