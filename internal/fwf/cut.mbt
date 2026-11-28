///|
/// One line's fields under a layout: each with the separators around it
/// cut. A field the line does not reach is the empty string, and so is the
/// part of a field that lies past the line's end; a separator inside a
/// field stays. Nothing here raises.
pub fn fwf_cut(line : String, layout : FwfLayout) -> Array[String] {
  let cells : Array[String] = []
  let walk = Walk::Walk(line)
  for c in 0..<layout.starts.length() {
    // Up to the field's first character; a line that ends first leaves
    // the walk at its end.
    while walk.place < layout.starts[c] {
      if walk.take() is None {
        break
      }
    }
    let from = walk.unit
    while walk.place < layout.ends[c] {
      if walk.take() is None {
        break
      }
    }
    let to = walk.unit
    let (first, last) = walk.trimmed(from, to)
    cells.push(line[first:last].to_owned())
  }
  cells
}
