///|
/// Where a table's fields lie: `starts[c]` and `ends[c]` name the first
/// character each field occupies and the one past its last, in characters
/// counted from the line's first (not bytes, not UTF-16 units). The fields
/// are in rising order and do not overlap. A field may be empty
/// (`start == end`) and may lie past the end of every line. A layout of no
/// field is a value: a line is cut into nothing under it.
pub struct FwfLayout {
  priv starts : Array[Int32]
  priv ends : Array[Int32]
}

///|
/// The layout two boundary lists spell: `starts[c]` and `ends[c]` for each
/// field `c`, as `FwfLayout` describes. Both lists are copied, so changing
/// one afterwards cannot move a field. In a message a field is counted
/// from 1.
///
/// Raises `InvalidOperation` — its text begins `fwf: ` — when the two
/// lists name different numbers of fields; when a field starts before the
/// line's first character; when a field ends before it starts; or when a
/// field starts before the one before it ends, which is a field out of
/// order and two fields overlapping alike.
pub fn FwfLayout::FwfLayout(
  starts : Array[Int32],
  ends : Array[Int32],
) -> FwfLayout raise @types.DataError {
  check_boundaries(starts, ends)
  { starts: starts.copy(), ends: ends.copy(), }
}

///|
/// How many fields a line is cut into under the layout.
pub fn FwfLayout::len(self : FwfLayout) -> Int32 {
  self.starts.length()
}

///|
/// Refuse two boundary lists that do not spell a layout, in the order
/// `FwfLayout::FwfLayout` states: a field is counted from 1 in a message.
fn check_boundaries(
  starts : Array[Int32],
  ends : Array[Int32],
) -> Unit raise @types.DataError {
  let count = starts.length()
  if ends.length() != count {
    raise @types.DataError::InvalidOperation(
      "fwf: \{count} starts and \{ends.length()} ends: a field needs one of each",
    )
  }
  for c in 0..<count {
    let start = starts[c]
    let end = ends[c]
    if start < 0 {
      raise @types.DataError::InvalidOperation(
        "fwf: field \{c + 1} starts at \{start}, before the line's first character",
      )
    }
    if end < start {
      raise @types.DataError::InvalidOperation(
        "fwf: field \{c + 1} ends at \{end} before it starts at \{start}",
      )
    }
    if c > 0 && start < ends[c - 1] {
      raise @types.DataError::InvalidOperation(
        "fwf: field \{c + 1} starts at \{start}, before field \{c} ends at \{ends[c - 1]}",
      )
    }
  }
}

///|
/// The layout from field widths, one a field: the fields lie end to end
/// from the line's first character, so field `c` starts where the one
/// before it ends and runs `widths[c]` characters. `widths` is read, not
/// kept.
///
/// Raises `InvalidOperation` for a width below zero, and for widths whose
/// sum runs past what a boundary can name; in a message a field is counted
/// from 1, and every text begins `fwf: `.
pub fn fwf_layout_of_widths(
  widths : Array[Int32],
) -> FwfLayout raise @types.DataError {
  let starts : Array[Int32] = []
  let ends : Array[Int32] = []
  let mut edge = 0
  for c, width in widths {
    if width < 0 {
      raise @types.DataError::InvalidOperation(
        "fwf: the width of field \{c + 1} is \{width}, below zero",
      )
    }
    if width > FURTHEST - edge {
      raise @types.DataError::InvalidOperation(
        "fwf: the widths of \{c + 1} fields run past \{FURTHEST} characters, which no boundary names",
      )
    }
    starts.push(edge)
    edge += width
    ends.push(edge)
  }
  { starts, ends, }
}
