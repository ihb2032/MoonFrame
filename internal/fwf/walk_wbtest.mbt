// Whitebox tests of the character walk — the one place a string's code
// units are read — and of the separator rule: a well-formed pair is one
// character, an unpaired half is one, the separators are four, and a
// stretch is trimmed of them at each end. The rest of the suite meets no
// string holding a surrogate half, since no file does; these do.

///|
/// A string of code units, built unit by unit — the way a string holding
/// an unpaired surrogate half can be made at all, since no literal spells
/// one.
fn of_units(units : ReadOnlyArray[Int32]) -> String {
  let out = StringBuilder()
  for unit in units {
    out.write_char(unit.unsafe_to_char())
  }
  out.to_string()
}

///|
test "the walk reads a pair as one character and an unpaired half as one" {
  // a, a pair, b, a lone high half, c, a lone low half, d
  let walk = Walk::Walk(
    of_units([0x61, 0xD83D, 0xDE00, 0x62, 0xD800, 0x63, 0xDE00, 0x64]),
  )
  assert_eq(walk.unit, 0)
  assert_eq(walk.place, 0)
  assert_eq(walk.take(), Some(0x61))
  assert_eq(walk.unit, 1)
  assert_eq(walk.place, 1)
  assert_eq(walk.take(), Some(0xD83D))
  assert_eq(walk.unit, 3)
  assert_eq(walk.place, 2)
  assert_eq(walk.take(), Some(0x62))
  assert_eq(walk.take(), Some(0xD800))
  assert_eq(walk.unit, 5)
  assert_eq(walk.place, 4)
  assert_eq(walk.take(), Some(0x63))
  assert_eq(walk.take(), Some(0xDE00))
  assert_eq(walk.take(), Some(0x64))
  // eight code units, seven characters
  assert_eq(walk.unit, 8)
  assert_eq(walk.place, 7)
  // at the end it answers None and stays
  assert_eq(walk.take(), None)
  assert_eq(walk.take(), None)
  assert_eq(walk.unit, 8)
  assert_eq(walk.place, 7)
  // an empty line
  let empty = Walk::Walk("")
  assert_eq(empty.take(), None)
  assert_eq(empty.unit, 0)
  assert_eq(empty.place, 0)
  // a high half that is the last unit has nothing to pair with
  let last = Walk::Walk(of_units([0xD83D]))
  assert_eq(last.take(), Some(0xD83D))
  assert_eq(last.unit, 1)
  assert_eq(last.take(), None)
  // a high half followed by a high half is two characters
  let two = Walk::Walk(of_units([0xD83D, 0xD83D, 0xDE00]))
  assert_eq(two.take(), Some(0xD83D))
  assert_eq(two.unit, 1)
  assert_eq(two.take(), Some(0xD83D))
  assert_eq(two.unit, 3)
  assert_eq(two.take(), None)
}

///|
test "four characters separate a field, and nothing else does" {
  assert_eq(is_separator(0x20), true)
  assert_eq(is_separator(0x09), true)
  assert_eq(is_separator(0x0D), true)
  assert_eq(is_separator(0x0A), true)
  for
    other in [
      0, 0x0B, 0x0C, 0x1C, 0x2C, 0x7F, 0x85, 0xA0, 0x2028, 0x3000, 0xD83D,
    ] {
    assert_eq(is_separator(other), false)
  }
}

///|
test "a stretch is trimmed of the separators at each end and of nothing inside" {
  // the units are: space space a space b space tab space
  let walk = Walk::Walk("  a b \t ")
  assert_eq(walk.unit, 0)
  assert_eq(walk.trimmed(0, 8), (2, 5))
  assert_eq(walk.trimmed(0, 2), (2, 2))
  assert_eq(walk.trimmed(2, 2), (2, 2))
  // a stretch of nothing but separators: the first ones are passed and
  // the two meet at its end
  assert_eq(walk.trimmed(6, 7), (7, 7))
  assert_eq(walk.trimmed(0, 3), (2, 3))
  // from the space after `a`: that space is passed, `b` is the content
  assert_eq(walk.trimmed(3, 8), (4, 5))
  // from `b` to before the tab: only the space after `b` goes
  assert_eq(walk.trimmed(4, 6), (4, 5))
  assert_eq(Walk::Walk("").trimmed(0, 0), (0, 0))
  assert_eq(Walk::Walk("\t\r\n ").trimmed(0, 4), (4, 4))
}

///|
test "a line holding a surrogate half infers and cuts by character" {
  // space, a lone high half, space, a pair: four characters, two fields
  let line = of_units([0x20, 0xD800, 0x20, 0xD83D, 0xDE00])
  let layout = fwf_infer_layout([line, " x y"], 100)
  assert_eq(layout.starts, [1, 3])
  assert_eq(layout.ends, [2, 4])
  let cells = fwf_cut(line, layout)
  assert_eq(cells.length(), 2)
  assert_eq(cells[0].length(), 1)
  assert_eq(cells[0].code_units()[0].to_int(), 0xD800)
  assert_eq(cells[1], "😀")
  // a half inside a field stays in the cell
  let inner = fwf_cut(
    of_units([0x61, 0xD800, 0x62]),
    FwfLayout::FwfLayout([0], [3]),
  )
  assert_eq(inner, [of_units([0x61, 0xD800, 0x62])])
  // and a field that starts on the second unit of a pair is never asked
  // for: positions are characters, so a field begins at a character
  assert_eq(fwf_cut("😀😀", FwfLayout::FwfLayout([1], [2])), ["😀"])
}
