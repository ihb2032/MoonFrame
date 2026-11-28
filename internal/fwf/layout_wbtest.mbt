// Whitebox tests of the layout itself and of the cut: what the layout from
// widths spells, the constructor's accepted shapes, what a line shorter
// than its fields cuts to, the separators inside a
// field, the rule that a position is a character, and a table written by
// the rule a writer of left-aligned cells uses and read back cell for cell.

///|
test "the layout from field widths lies end to end from the first character" {
  let layout = fwf_layout_of_widths([3, 0, 6, 5])
  assert_eq(layout.starts, [0, 3, 3, 9])
  assert_eq(layout.ends, [3, 3, 9, 14])
  assert_eq(layout.len(), 4)
  assert_eq(boundaries(layout), "(0, 3) (3, 3) (3, 9) (9, 14)")
  // no field is a layout
  let none = fwf_layout_of_widths([])
  assert_eq(none.len(), 0)
  assert_eq(none.starts, [])
  assert_eq(none.ends, [])
  assert_eq(fwf_cut("anything", none), [])
  // a width past every line that could be
  let far = fwf_layout_of_widths([2147483646, 1])
  assert_eq(far.ends, [2147483646, 2147483647])
  assert_eq(fwf_cut("x", far), ["x", ""])
  // the widths are read, not kept
  let widths = [2, 3]
  let kept = fwf_layout_of_widths(widths)
  widths[0] = 9
  assert_eq(kept.starts, [0, 2])
  assert_eq(kept.ends, [2, 5])
}

///|
test "the layout keeps its own copy of the arrays it was built from" {
  let starts = [0, 4]
  let ends = [3, 8]
  let layout = FwfLayout::FwfLayout(starts, ends)
  // the arrays the constructor was given are the caller's to change
  starts[0] = 9
  ends[1] = 1
  assert_eq(layout.starts, [0, 4])
  assert_eq(layout.ends, [3, 8])
  // `ef` lies at 6 and 7, inside the second field, 4 to 8
  assert_eq(fwf_cut("abcd  ef  ", layout), ["abc", "ef"])
  assert_eq(layout.len(), 2)
}

///|
test "the constructor accepts an empty field and a field past every line" {
  let layout = FwfLayout::FwfLayout([2, 2, 5], [2, 4, 5])
  assert_eq(boundaries(layout), "(2, 2) (2, 4) (5, 5)")
  assert_eq(fwf_cut("  ab ", layout), ["", "ab", ""])
  assert_eq(fwf_cut("", layout), ["", "", ""])
  assert_eq(fwf_cut("  a", layout), ["", "a", ""])
  let far = FwfLayout::FwfLayout([2147483646], [2147483647])
  assert_eq(fwf_cut("abc", far), [""])
  let none = FwfLayout::FwfLayout([], [])
  assert_eq(none.len(), 0)
  assert_eq(fwf_cut("abc", none), [])
}

///|
test "a cut keeps the separators inside a field and drops the ones around it" {
  let layout = FwfLayout::FwfLayout([0, 6], [6, 12])
  assert_eq(fwf_cut("a\tb c  x  y ", layout), ["a\tb c", "x  y"])
  // a line that ends inside a field, and one that ends before it
  assert_eq(fwf_cut("\t a \t", layout), ["a", ""])
  assert_eq(fwf_cut("  ab", layout), ["ab", ""])
  // a field of nothing but separators, and a line of them
  assert_eq(fwf_cut("      ", layout), ["", ""])
  assert_eq(fwf_cut("\t\r\n", layout), ["", ""])
  // spaces that are not separators to the cut are content
  assert_eq(fwf_cut("a\u{00A0}b   x\u{3000}y", layout), [
    "a\u{00A0}b", "x\u{3000}y",
  ])
  assert_eq(fwf_cut("x\u{000B}y   z", layout), ["x\u{000B}y", "z"])
}

///|
test "a position is a character: a line outside ASCII cuts by code point" {
  // Two CJK characters are two characters in two code units; an emoji is
  // one character in two code units, where a count of units would make the
  // field that holds it empty and push the letters after it out.
  let layout = FwfLayout::FwfLayout([0, 2, 3], [2, 3, 5])
  assert_eq(fwf_cut("東京😀ab", layout), ["東京", "😀", "ab"])
  // A combining mark is a character of its own: `e` and two marks fill a
  // field of three, though they are one grapheme.
  let marks = FwfLayout::FwfLayout([0], [3])
  assert_eq(fwf_cut("e\u{0301}\u{0302}x", marks), ["e\u{0301}\u{0302}"])
  assert_eq(fwf_cut("e\u{0301}\u{0302}", marks), ["e\u{0301}\u{0302}"])
  // The inference measures the same way: the header is ASCII, four and
  // five characters wide; a cell is four emoji, which are four characters
  // and eight code units, and the fields are 0 to 4 and 5 to 10.
  let lines = ["name value", "1    \u{1F600}\u{1F600}\u{1F600}\u{1F600}"]
  assert_eq(boundaries(fwf_infer_layout(lines, 100)), "(0, 4) (5, 10)")
  assert_eq(fwf_cut(lines[1], fwf_infer_layout(lines, 100)), [
    "1", "😀😀😀😀",
  ])
}

///|
/// A table as fixed-width lines by the rule a writer of left-aligned cells
/// uses: a column as wide as its widest cell, counted in characters, every
/// cell at its column's first character, one space between columns.
fn write_table(table : Array[Array[String]]) -> Array[String] {
  let columns = table[0].length()
  let widths : Array[Int32] = []
  for c in 0..<columns {
    let mut widest = 0
    for row in table {
      let length = row[c].iter().count()
      if length > widest {
        widest = length
      }
    }
    widths.push(widest)
  }
  table.map(row => {
    let out = StringBuilder()
    for c in 0..<columns {
      if c > 0 {
        out.write_char(' ')
      }
      out.write_string(row[c])
      for _ in row[c].iter().count()..<widths[c] {
        out.write_char(' ')
      }
    }
    out.to_string()
  })
}

///|
test "a table written left-aligned with a space between columns reads back cell for cell" {
  // What this codec carries is strings only: an empty cell is the missing
  // value, and a cell's extremes are one character and as many as its
  // column's widest. A separator inside a cell — the two spaces below —
  // reads back where another cell of the column lies across the same
  // position, and would split the field where none does.
  let wide = String::make(40, 'x')
  let table : Array[Array[String]] = [
    ["name", "note", "value"],
    ["Ada", "first row", "1"],
    ["Alan", "", "-2734"],
    ["田中", "naïve café", "3.5"],
    ["😀", "e\u{0301}\u{0302}", "true"],
    [wide, "two  spaces", "9223372036854775807"],
    ["", "", ""],
    ["七", "\u{00A0}\u{3000}\u{2003}", "０"],
  ]
  let lines = write_table(table)
  let layout = fwf_infer_layout(lines, 100)
  assert_eq(layout.len(), 3)
  for i, row in table {
    assert_eq(fwf_cut(lines[i], layout), row)
  }
  // the same with no header row to carry the empty columns: a column
  // empty in every line names no field, and the cells close up around it —
  // the middle column's cell sits at the first character after the gap
  let headerless = write_table([["", "7", ""], ["", "8", ""]])
  assert_eq(headerless, [" 7 ", " 8 "])
  let closed = fwf_infer_layout(headerless, 100)
  assert_eq(boundaries(closed), "(1, 2)")
  assert_eq(fwf_cut(headerless[1], closed), ["8"])
  // and a window that stops before the line that widens a column leaves
  // the column at the header's width
  let widening = write_table([["ab", "c"], ["d", "efgh"]])
  assert_eq(boundaries(fwf_infer_layout(widening, 2)), "(0, 2) (3, 7)")
  assert_eq(boundaries(fwf_infer_layout(widening, 1)), "(0, 2) (3, 4)")
}
