///|
/// The layout the lines themselves spell, read off the first `infer_nrows`
/// of them: a field is a run of characters, in one line or across the
/// lines, where at least one of those lines has a character that is not a
/// separator. Leading separators name no field, and a line that is all
/// separators names none. It is the inference the reference reader makes,
/// boundary for boundary. `lines` are read, not kept: each is one line of
/// the table, the header among them, with or without its terminator.
///
/// Raises `InvalidOperation` when `infer_nrows` is zero or below — it
/// names how many lines the layout is read off — when there is no line to
/// read, and when the lines read hold no field because every character in
/// them is a separator; the last message says how many lines were read and
/// how long the longest was. Every text begins `fwf: `.
pub fn fwf_infer_layout(
  lines : Array[String],
  infer_nrows : Int32,
) -> FwfLayout raise @types.DataError {
  if infer_nrows <= 0 {
    raise @types.DataError::InvalidOperation(
      "fwf: infer_nrows is \{infer_nrows}: it names how many lines the layout is read off, one or more",
    )
  }
  let count = if infer_nrows < lines.length() {
    infer_nrows
  } else {
    lines.length()
  }
  if count == 0 {
    raise @types.DataError::InvalidOperation(
      "fwf: no line to read a layout from",
    )
  }
  // `held[p]` once a line has content at the character `p`. The array
  // grows to the longest line read, one entry a character.
  let held : Array[Bool] = []
  let mut longest = 0
  for i in 0..<count {
    let walk = Walk::Walk(lines[i])
    let mut reading = true
    while reading {
      let place = walk.place
      match walk.take() {
        None => reading = false
        Some(unit) =>
          if !is_separator(unit) {
            if place < held.length() {
              held[place] = true
            } else {
              // the separators just read leave the places before this one
              // unheld
              while held.length() < place {
                held.push(false)
              }
              held.push(true)
            }
          }
      }
    }
    if walk.place > longest {
      longest = walk.place
    }
  }
  if held.is_empty() {
    raise @types.DataError::InvalidOperation(
      "fwf: no field: \{count} lines read, the longest \{longest} characters, and every character a space, a tab, a carriage return or a line feed",
    )
  }
  // A field is a maximal run of held characters.
  let starts : Array[Int32] = []
  let ends : Array[Int32] = []
  let mut opening = -1
  for place in 0..<held.length() {
    if held[place] {
      if opening < 0 {
        opening = place
      }
    } else if opening >= 0 {
      starts.push(opening)
      ends.push(place)
      opening = -1
    }
  }
  if opening >= 0 {
    starts.push(opening)
    ends.push(held.length())
  }
  { starts, ends, }
}
