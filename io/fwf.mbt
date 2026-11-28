// The fixed-width interchange — a reader over the column logic in
// `internal/fwf`: where each line's fields start and end, inferred from the
// lines themselves or named by the caller, and how a line is cut into them.
// What a cut cell becomes in a frame is decided here, with the CSV reader's
// own rules — the first row names the columns under a header, a blank line
// is skipped, and each column takes the narrowest dtype holding its cells.

///|
/// Options that control how a fixed-width file is read into a `DataFrame`.
/// Fields are read-only outside the package — build them through
/// `FwfReadOptions::FwfReadOptions(...)`, naming only what differs from the
/// defaults. The array fields are copied, so mutating them afterwards cannot
/// alter the options; their accessors answer copies.
///
///   * `widths` — the width of each field, one a field, the fields lying end
///     to end from each line's first character. Empty by default.
///   * `colspecs` — each field's `(start, end)` character positions, the end
///     past the last character. Empty by default. Naming both `widths` and
///     `colspecs` refuses the read.
///   * `infer_nrows` — how many lines the inference reads when neither names
///     a layout: the first lines after the skipped ones, the header among
///     them. 100 by default.
///   * `has_header` — when `true` (the default) the first line after the
///     skipped ones names the columns; when `false` every line is data and
///     the columns are named `column1`, `column2`, … unless `names` names
///     them.
///   * `skiprows` — lines passed over at the head of the file, before the
///     header and the inference. 0 by default.
///   * `names` — the columns' names, in place of the header's or of the
///     generated ones. Empty by default.
pub struct FwfReadOptions {
  priv widths : Array[Int32]
  priv colspecs : Array[(Int32, Int32)]
  infer_nrows : Int32
  has_header : Bool
  skiprows : Int32
  priv names : Array[String]
}

///|
/// The options with their defaults: an inferred layout over a hundred
/// lines, a header, nothing skipped, no names. `widths`, `colspecs` and
/// `names` are copied, so mutating them afterwards cannot alter the options.
pub fn FwfReadOptions::FwfReadOptions(
  widths~ : Array[Int32] = [],
  colspecs~ : Array[(Int32, Int32)] = [],
  infer_nrows~ : Int32 = 100,
  has_header~ : Bool = true,
  skiprows~ : Int32 = 0,
  names~ : Array[String] = [],
) -> FwfReadOptions {
  {
    widths: widths.copy(),
    colspecs: colspecs.copy(),
    infer_nrows,
    has_header,
    skiprows,
    names: names.copy(),
  }
}

///|
/// The widths the options name. A copy, so mutating it cannot alter the
/// options.
pub fn FwfReadOptions::widths(self : FwfReadOptions) -> Array[Int32] {
  self.widths.copy()
}

///|
/// The fields' positions the options name. A copy, so mutating it cannot
/// alter the options.
pub fn FwfReadOptions::colspecs(self : FwfReadOptions) -> Array[(Int32, Int32)] {
  self.colspecs.copy()
}

///|
/// The names the options give the columns. A copy, so mutating it cannot
/// alter the options.
pub fn FwfReadOptions::names(self : FwfReadOptions) -> Array[String] {
  self.names.copy()
}

///|
/// Read a fixed-width file into a frame — each line a row, each of its
/// fields a cell. Raises the errors `parse_fwf` states; a path that cannot
/// be read raises `IoError`.
pub fn read_fwf(
  path : String,
  options? : FwfReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  parse_fwf(read_text(path), options?)
}

///|
/// Parse a fixed-width file's text into a frame — `read_fwf`'s
/// string-level counterpart, for text already in memory.
///
/// A field is a run of a line's characters between two boundaries: named by
/// `options.widths` or `options.colspecs`, or — when neither names a layout
/// — inferred from the first `options.infer_nrows` lines after the
/// `options.skiprows` skipped ones, the header among them. The boundaries
/// are counted in characters from the line's first, and the whitespace
/// around a field is not part of its cell. A line shorter than a field
/// leaves that cell empty.
///
/// The first line after the skipped ones names the columns under
/// `options.has_header`, and `options.names` names them in its place; with
/// no header and no names the columns are `column1`, `column2`, … A line
/// that is empty or whitespace alone is skipped. Each column takes the
/// narrowest dtype holding its cells — `Int`, `Float`, `Bool`, `String`, in
/// the CSV reader's order — and an empty cell is null.
///
/// A text with no line to read answers the `0×0` frame. Raises
/// `InvalidOperation` when `options.widths` and `options.colspecs` both
/// name a layout, and for a layout the lines do not spell — no field found,
/// a width that is negative, positions that overlap or start before the
/// line's first character. Raises `DuplicateColumn(name)` for a header
/// naming one column twice.
pub fn parse_fwf(
  text : String,
  options? : FwfReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  let chosen = match options {
    Some(given) => given
    None => FwfReadOptions::FwfReadOptions()
  }
  // The lines after the skipped ones.
  let lines = fwf_lines(text)
  let body : Array[String] = []
  for i in 0..<lines.length() {
    if i >= chosen.skiprows {
      body.push(lines[i])
    }
  }
  let layout = if fwf_named(chosen) {
    fwf_layout(body, chosen)
  } else if fwf_every_line_blank(body) {
    // Nothing to read a layout from is nothing to read: the `0×0` frame,
    // as the CSV reader answers an empty file.
    return @frame.DataFrame::from_parts([], 0)
  } else {
    fwf_layout(body, chosen)
  }
  // Every line that holds a character, cut into its cells.
  let cells : Array[Array[String]] = []
  for line in body {
    if !line.trim().is_empty() {
      cells.push(@fwf.fwf_cut(line, layout))
    }
  }
  // No line to read is nothing to read; a header alone names its
  // columns over no row.
  if cells.is_empty() {
    return @frame.DataFrame::from_parts([], 0)
  }
  // The header's cells leave the rows under a header.
  let first = if chosen.has_header { 1 } else { 0 }
  let columns : Array[@series.Series] = []
  for c in 0..<layout.len() {
    let name = if c < chosen.names.length() {
      chosen.names[c]
    } else if chosen.has_header {
      cells[0][c]
    } else {
      "column\{c + 1}"
    }
    let column : Array[String?] = []
    for r in first..<cells.length() {
      let cell = cells[r][c]
      if cell == "" {
        column.push(None)
      } else {
        column.push(Some(cell))
      }
    }
    columns.push(probed_text_column(name, column))
  }
  @frame.DataFrame::from_parts(columns, cells.length() - first)
}

///|
/// The file's lines: a line ends at a line feed, and the carriage return
/// before one is not part of it; a byte-order mark at the head of the text
/// is not part of the first; a final line without a line feed is a line.
fn fwf_lines(text : String) -> Array[String] {
  let body = if text.has_prefix("\u{FEFF}") {
    text[1:].to_owned()
  } else {
    text
  }
  let lines : Array[String] = []
  let mut current = StringBuilder()
  for ch in body.iter() {
    if ch == '\n' {
      lines.push(fwf_unwrap_cr(current.to_string()))
      current = StringBuilder()
    } else {
      current.write_char(ch)
    }
  }
  if current.to_string() != "" {
    lines.push(fwf_unwrap_cr(current.to_string()))
  }
  lines
}

///|
/// The line without the carriage return a Windows terminator left on it.
fn fwf_unwrap_cr(line : String) -> String {
  if line.has_suffix("\r") {
    line[0:line.length() - 1].to_owned()
  } else {
    line
  }
}

///|
/// Whether the options name a layout themselves, leaving nothing to infer.
fn fwf_named(options : FwfReadOptions) -> Bool {
  options.widths.length() > 0 || options.colspecs.length() > 0
}

///|
/// Whether every line is empty or whitespace alone — or there is none.
fn fwf_every_line_blank(lines : Array[String]) -> Bool {
  for line in lines {
    if !line.trim().is_empty() {
      return false
    }
  }
  true
}

///|
/// The layout the options name: the widths', the positions', or the one the
/// lines spell.
fn fwf_layout(
  lines : Array[String],
  options : FwfReadOptions,
) -> @fwf.FwfLayout raise @types.DataError {
  if options.widths.length() > 0 && options.colspecs.length() > 0 {
    raise @types.DataError::InvalidOperation(
      "fwf: widths and colspecs both name a layout; name one",
    )
  }
  if options.widths.length() > 0 {
    return @fwf.fwf_layout_of_widths(options.widths)
  }
  if options.colspecs.length() > 0 {
    let starts : Array[Int32] = []
    let ends : Array[Int32] = []
    for pair in options.colspecs {
      starts.push(pair.0)
      ends.push(pair.1)
    }
    return @fwf.FwfLayout::FwfLayout(starts, ends)
  }
  @fwf.fwf_infer_layout(lines, options.infer_nrows)
}
