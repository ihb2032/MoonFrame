// The HTML table reader: a tokenizer that walks a document once, the
// tables it opens and the cells they hold, and the frames those lay out
// as — a table a frame, in the order the document opens them, the header
// row or rows naming the columns.

///|
/// The most positions one table's grid may hold — what its rows and
/// columns multiply to once spans are laid out. A cell's spans are the
/// document's word for how far it reaches, and a cell claiming more than
/// the table could hold would lay out a grid out of proportion to the
/// document: past this the table refuses.
const HTML_GRID_LIMIT : Int64 = 33554432L

///|
/// The most rows a cell may span, and the most columns: what a browser
/// clamps a larger span to.
const ROW_SPAN_MOST : Int32 = 65534

///|
const COL_SPAN_MOST : Int32 = 1000

///|
/// What a `<` opens: text after all; a construct stepped over whole — a
/// comment, a declaration, a tag the document ends inside; a start tag
/// with its name and the spans its attributes name; or an end tag.
priv enum Token {
  Text
  Skip(Int32)
  Start(String, Int32, Int32, Int32)
  End(String, Int32)
}

///|
/// A cell while it is read: its text, how far it reaches, and whether a
/// `th` opened it.
priv struct Cell {
  text : StringBuilder
  row_span : Int32
  col_span : Int32
  header : Bool
}

///|
/// One row as the document lays it out.
priv struct Row {
  cells : Array[Cell]
  // Read inside a `thead`, which makes it a header row whatever its cells.
  in_head : Bool
}

///|
/// A table while it is read: its rows in document order, the row and the
/// cell still open in it, and whether rows are being read inside a head.
priv struct Table {
  // Where the frame goes among the document's, by where the table opens.
  index : Int32
  rows : Array[Row]
  mut row : Row
  mut row_open : Bool
  mut cell_open : Bool
  mut in_head : Bool
}

///|
/// The document while it is read: the tables still open, the outermost
/// first; every table by where it opens, filled in as each closes; and the
/// text of every cell still open, the innermost last.
priv struct Reading {
  tables : Array[Table]
  order : Array[Table]
  sinks : Array[StringBuilder]
}

///|
/// The code unit at `at`, or `-1` past the document's end.
fn peek(units : ArrayView[UInt16], at : Int32) -> Int32 {
  if at < units.length() {
    units[at].to_int()
  } else {
    -1
  }
}

///|
/// Whether a code unit is an ASCII letter.
fn is_letter(c : Int32) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}

///|
/// Whether a code unit is an ASCII digit.
fn is_digit(c : Int32) -> Bool {
  c >= 48 && c <= 57
}

///|
/// Whether a code unit is HTML's whitespace: a space, a tab, a line feed,
/// a form feed, or a carriage return.
fn is_html_space(c : Int32) -> Bool {
  c == 32 || (c >= 9 && c <= 13)
}

///|
/// The whitespace a cell's text is cleaned of: HTML's own, the control
/// separators, and the Unicode spaces — all of them single code units, a
/// surrogate half none of them.
fn is_space(c : Int32) -> Bool {
  (c >= 9 && c <= 13) ||
  c == 32 ||
  c == 133 ||
  (c >= 28 && c <= 31) ||
  c == 160 ||
  c == 5760 ||
  (c >= 8192 && c <= 8202) ||
  c == 8232 ||
  c == 8233 ||
  c == 8239 ||
  c == 8287 ||
  c == 12288
}

///|
/// Whether a code unit may be part of a name: an ASCII letter, a digit,
/// `-`, `_`, `:`, or `.`.
fn is_name_char(c : Int32) -> Bool {
  is_letter(c) || is_digit(c) || c == 45 || c == 95 || c == 58 || c == 46
}

///|
/// The name that starts at `from` and runs to the first code unit a name
/// cannot hold, upper-case letters folded when `fold`, and where it ends.
fn read_name(
  units : ArrayView[UInt16],
  from : Int32,
  fold~ : Bool,
) -> (String, Int32) {
  let out = StringBuilder()
  let mut i = from
  while ({
          let c = peek(units, i)
          if is_name_char(c) {
            // A name holds ASCII code units only: each is a character whole.
            let letter = if fold && c >= 65 && c <= 90 { c + 32 } else { c }
            out.write_char(letter.unsafe_to_char())
            true
          } else {
            false
          }
        }) {
    i += 1
  }
  (out.to_string(), i)
}

///|
/// Where the construct that holds `from` ends: past the next `>`, or
/// where the document does.
fn after(units : ArrayView[UInt16], from : Int32) -> Int32 {
  let mut i = from
  while i < units.length() && units[i].to_int() != 62 {
    i += 1
  }
  if i < units.length() {
    i + 1
  } else {
    units.length()
  }
}

///|
/// The span an attribute's value names: its leading digits, one for a
/// value with none or with a zero, and no more than `most`.
fn span_of(
  units : ArrayView[UInt16],
  from : Int32,
  upto : Int32,
  most : Int32,
) -> Int32 {
  let mut value = 0
  for i in from..<upto {
    let c = units[i].to_int()
    if !is_digit(c) {
      break
    }
    if value < most {
      value = value * 10 + (c - 48)
    }
  }
  if value < 1 {
    1
  } else if value > most {
    most
  } else {
    value
  }
}

///|
/// The construct a `<` at `at` opens, read to where it ends. A `<` that
/// opens none of them is text, and the document is read on from the next
/// code unit. A start tag's `rowspan` and `colspan` are read off it; the
/// other attributes are stepped over.
fn token_at(units : ArrayView[UInt16], at : Int32) -> Token {
  let next = peek(units, at + 1)
  if next == 33 {
    if peek(units, at + 2) == 45 && peek(units, at + 3) == 45 {
      // A comment ends at `-->`, or where the document does.
      let mut i = at + 4
      while i < units.length() &&
            !(units[i].to_int() == 45 &&
            peek(units, i + 1) == 45 &&
            peek(units, i + 2) == 62) {
        i += 1
      }
      return Skip(if i < units.length() { i + 3 } else { units.length() })
    }
    return Skip(after(units, at + 2))
  }
  if next == 63 {
    return Skip(after(units, at + 2))
  }
  if next == 47 {
    if !is_letter(peek(units, at + 2)) {
      return Text
    }
    let (name, i) = read_name(units, at + 2, fold=true)
    return End(name, after(units, i))
  }
  if !is_letter(next) {
    return Text
  }
  let (name, name_end) = read_name(units, at + 1, fold=true)
  let mut i = name_end
  let mut row_span = 1
  let mut col_span = 1
  while true {
    while is_html_space(peek(units, i)) {
      i += 1
    }
    let c = peek(units, i)
    if c == -1 {
      return Skip(units.length())
    }
    if c == 62 {
      i += 1
      break
    }
    if c == 47 {
      i += 1
      continue
    }
    let start = i
    let (attribute, j) = read_name(units, i, fold=true)
    i = j
    while is_html_space(peek(units, i)) {
      i += 1
    }
    if peek(units, i) == 61 {
      i += 1
      while is_html_space(peek(units, i)) {
        i += 1
      }
      let quote = peek(units, i)
      let (from, stop) = if quote == 34 || quote == 39 {
        (i + 1, quote)
      } else {
        (i, -1)
      }
      let mut k = from
      while ({
              let c = peek(units, k)
              c != -1 &&
              c != stop &&
              (stop != -1 || (!is_html_space(c) && c != 62))
            }) {
        k += 1
      }
      if attribute == "rowspan" {
        row_span = span_of(units, from, k, ROW_SPAN_MOST)
      }
      if attribute == "colspan" {
        col_span = span_of(units, from, k, COL_SPAN_MOST)
      }
      i = if stop == -1 { k } else { k + 1 }
    } else if i == start {
      // A nameless attribute: step over what would otherwise be read again.
      i += 1
    }
  }
  Start(name, row_span, col_span, i)
}

///|
/// Where the raw text a `script` or `style` element holds ends: past its
/// end tag, or where the document does.
fn raw_end(units : ArrayView[UInt16], from : Int32, name : String) -> Int32 {
  let wanted = name.code_units()
  let count = wanted.length()
  let mut i = from
  while i + 2 + count <= units.length() {
    if units[i].to_int() == 60 && units[i + 1].to_int() == 47 {
      let mut same = true
      for j in 0..<count {
        let c = units[i + 2 + j].to_int()
        let letter = if c >= 65 && c <= 90 { c + 32 } else { c }
        if letter != wanted[j].to_int() {
          same = false
        }
      }
      if same {
        let next = peek(units, i + 2 + count)
        if next == -1 || is_html_space(next) || next == 62 || next == 47 {
          return after(units, i + 2 + count)
        }
      }
    }
    i += 1
  }
  units.length()
}

///|
/// The value of a digit in a numeric reference — decimal, or hexadecimal
/// when `hex` — or `-1` for any other code unit.
fn digit_value(c : Int32, hex~ : Bool) -> Int32 {
  if is_digit(c) {
    c - 48
  } else if hex && c >= 97 && c <= 102 {
    c - 87
  } else if hex && c >= 65 && c <= 70 {
    c - 55
  } else {
    -1
  }
}

///|
/// The text a code point stands for — the replacement character where the
/// code point is none: zero, past the format's range, or a surrogate half.
fn code_point_text(code : Int64) -> String {
  if code < 1L || code > 0x10FFFFL || (code >= 0xD800L && code <= 0xDFFFL) {
    "\u{FFFD}"
  } else {
    // The range and the surrogates are excluded above.
    code.to_int().unsafe_to_char().to_string()
  }
}

///|
/// The text a named reference stands for, among the names this reader
/// decodes.
fn named_reference(name : String) -> String? {
  let mut low = 0
  let mut high = named_references.length() - 1
  while low <= high {
    let mid = (low + high) / 2
    let order = name.lexical_compare(named_references[mid].0)
    if order == 0 {
      return Some(named_references[mid].1)
    }
    if order < 0 {
      high = mid - 1
    } else {
      low = mid + 1
    }
  }
  None
}

///|
/// The character reference an `&` at `at` names: its text, and where it
/// ends. `None` when it names none — no digits, no semicolon, a name this
/// reader does not decode, a name past thirty-one code units — leaving
/// the `&` as text.
fn reference_at(units : ArrayView[UInt16], at : Int32) -> (String, Int32)? {
  let mut i = at + 1
  if peek(units, i) == 35 {
    i += 1
    let marker = peek(units, i)
    let hex = marker == 120 || marker == 88
    if hex {
      i += 1
    }
    let from = i
    let mut code = 0L
    while ({
            let digit = digit_value(peek(units, i), hex~)
            if digit >= 0 {
              if code < 0x110000L {
                code = code * (if hex { 16L } else { 10L }) + digit.to_int64()
              }
              true
            } else {
              false
            }
          }) {
      i += 1
    }
    if i == from || peek(units, i) != 59 {
      return None
    }
    Some((code_point_text(code), i + 1))
  } else {
    let from = i
    while i - from < 32 && is_name_char(peek(units, i)) {
      i += 1
    }
    if i == from || peek(units, i) != 59 {
      return None
    }
    let (name, _) = read_name(units, from, fold=false)
    match named_reference(name) {
      Some(text) => Some((text, i + 1))
      None => None
    }
  }
}

///|
/// Text into every cell still open — a table nested in a cell writes into
/// that cell too, whose text is everything in it; text outside every cell
/// is not a table's.
fn write(st : Reading, text : StringView) -> Unit {
  for sink in st.sinks {
    sink.write_stringview(text)
  }
}

///|
/// The document's text from `from` to `upto`, into the cell open last.
fn flush(st : Reading, text : String, from : Int32, upto : Int32) -> Unit {
  if upto > from {
    write(st, text[from:upto])
  }
}

///|
/// A table of no row: the shape a place among the document's tables is
/// held in, and a row's before any cell is read into it.
fn empty_row() -> Row {
  Row::{ cells: [], in_head: false, }
}

///|
/// A table opens: it joins the tables still open and takes a place among
/// the document's.
fn start_table(st : Reading) -> Unit {
  st.tables.push(Table::{
    index: st.order.length(),
    rows: [],
    row: empty_row(),
    row_open: false,
    cell_open: false,
    in_head: false,
  })
  // The place is held by a table of nothing until the real one closes in.
  st.order.push(Table::{
    index: 0,
    rows: [],
    row: empty_row(),
    row_open: false,
    cell_open: false,
    in_head: false,
  })
}

///|
/// A table's end: its open row and cell end first, then it takes its place
/// among the document's tables. With none open there is nothing to end.
fn end_table(st : Reading) -> Unit {
  end_row(st)
  if st.tables.is_empty() {
    return
  }
  let table = st.tables[st.tables.length() - 1]
  let _ = st.tables.pop()
  st.order[table.index] = table
}

///|
/// A row's end: its open cell ends first, then the row joins the table's.
/// With no row open, or no table, there is nothing to end.
fn end_row(st : Reading) -> Unit {
  if st.tables.is_empty() {
    return
  }
  let top = st.tables.length() - 1
  end_cell(st)
  if st.tables[top].row_open {
    st.tables[top].rows.push(st.tables[top].row)
    st.tables[top].row = empty_row()
    st.tables[top].row_open = false
  }
}

///|
/// A row's start inside the table open last: the row open in it, if any,
/// ends first. Outside every table there is nothing to start.
fn start_row(st : Reading) -> Unit {
  if st.tables.is_empty() {
    return
  }
  end_row(st)
  let top = st.tables.length() - 1
  st.tables[top].row = Row::{ cells: [], in_head: st.tables[top].in_head, }
  st.tables[top].row_open = true
}

///|
/// A cell's end inside the table open last: its text stops being the one
/// the document writes into. With no cell open, or no table, there is
/// nothing to end.
fn end_cell(st : Reading) -> Unit {
  if st.tables.is_empty() {
    return
  }
  let top = st.tables.length() - 1
  if st.tables[top].cell_open {
    let _ = st.sinks.pop()
    st.tables[top].cell_open = false
  }
}

///|
/// A cell's start inside the table open last — in a row of its own when
/// none is open — with the cell open in it, if any, ended first. Outside
/// every table there is nothing to start.
fn start_cell(
  st : Reading,
  header : Bool,
  row_span : Int32,
  col_span : Int32,
) -> Unit {
  if st.tables.is_empty() {
    return
  }
  if !st.tables[st.tables.length() - 1].row_open {
    start_row(st)
  }
  end_cell(st)
  let top = st.tables.length() - 1
  // One builder is both the cell's text and the place the document writes
  // into while the cell is open.
  let text = StringBuilder()
  st.tables[top].row.cells.push(Cell::{ text, row_span, col_span, header, })
  st.sinks.push(text)
  st.tables[top].cell_open = true
}

///|
/// What a start tag does to the tables being read: the table elements
/// open, close, and group rows and cells; a line break is written into the
/// cell open last; every other tag is stepped over.
fn start_tag(
  st : Reading,
  name : String,
  row_span : Int32,
  col_span : Int32,
) -> Unit {
  match name {
    "table" => start_table(st)
    "thead" =>
      if !st.tables.is_empty() {
        st.tables[st.tables.length() - 1].in_head = true
      }
    "tbody" | "tfoot" =>
      if !st.tables.is_empty() {
        st.tables[st.tables.length() - 1].in_head = false
      }
    "tr" => start_row(st)
    "td" => start_cell(st, false, row_span, col_span)
    "th" => start_cell(st, true, row_span, col_span)
    "br" => write(st, "\n")
    _ => ()
  }
}

///|
/// What an end tag does to the tables being read: a table, a row, and a
/// cell end, and a row group closes; every other tag is stepped over.
fn end_tag(st : Reading, name : String) -> Unit {
  match name {
    "table" => end_table(st)
    "thead" | "tbody" | "tfoot" =>
      if !st.tables.is_empty() {
        st.tables[st.tables.length() - 1].in_head = false
      }
    "tr" => end_row(st)
    "td" | "th" => end_cell(st)
    _ => ()
  }
}

///|
/// The tables a document holds, by where each opens, each read to its
/// last row. The document is walked once: a tag, a comment, or a character
/// reference ends the text before it, which goes into the cell open last;
/// whatever is still open ends with the document.
fn html_tables(text : String) -> Array[Table] {
  let units = text.code_units()
  let st : Reading = Reading::{ tables: [], order: [], sinks: [], }
  let mut i = 0
  let mut run = 0
  while i < units.length() {
    let c = units[i].to_int()
    if c == 60 {
      match token_at(units, i) {
        Text => i += 1
        Skip(to) => {
          flush(st, text, run, i)
          i = to
          run = i
        }
        End(name, to) => {
          flush(st, text, run, i)
          end_tag(st, name)
          i = to
          run = i
        }
        Start(name, row_span, col_span, to) => {
          flush(st, text, run, i)
          i = to
          run = i
          if name == "script" || name == "style" {
            // Raw text: nothing in it is markup, to the element's end.
            i = raw_end(units, i, name)
            run = i
          } else {
            start_tag(st, name, row_span, col_span)
          }
        }
      }
    } else if c == 38 {
      match reference_at(units, i) {
        Some((decoded, to)) => {
          flush(st, text, run, i)
          write(st, decoded)
          i = to
          run = i
        }
        None => i += 1
      }
    } else {
      i += 1
    }
  }
  flush(st, text, run, units.length())
  while !st.tables.is_empty() {
    end_table(st)
  }
  st.order
}

///|
/// A table's header rows and its data rows. The rows read inside a `thead`
/// are the header when there are any; otherwise the leading rows whose
/// every cell is a header cell are, and the first row that is not one of
/// them opens the data.
fn header_rows(table : Table) -> (Array[Row], Array[Row]) {
  let head : Array[Row] = []
  let body : Array[Row] = []
  if table.rows.any(row => row.in_head) {
    for row in table.rows {
      if row.in_head {
        head.push(row)
      } else {
        body.push(row)
      }
    }
  } else {
    let mut leading = true
    for row in table.rows {
      let all_header = row.cells.length() > 0 &&
        row.cells.all(cell => cell.header)
      if leading && all_header {
        head.push(row)
      } else {
        leading = false
        body.push(row)
      }
    }
  }
  (head, body)
}

///|
/// A cell's text as a frame holds it: every run of line breaks, and every
/// other run of two or more whitespace characters, one space; then the
/// whitespace at both ends cut. A single space or tab inside the text
/// stays as it is.
fn tidy_text(raw : String) -> String {
  let units = raw.code_units()
  let count = units.length()
  let mut from = 0
  while from < count && is_space(units[from].to_int()) {
    from += 1
  }
  let mut upto = count
  while upto > from && is_space(units[upto - 1].to_int()) {
    upto -= 1
  }
  let out = StringBuilder()
  let mut run = from
  let mut i = from
  while i < upto {
    let c = units[i].to_int()
    if c == 10 || c == 13 {
      out.write_stringview(raw[run:i])
      while i < upto && (units[i].to_int() == 10 || units[i].to_int() == 13) {
        i += 1
      }
      out.write_char(' ')
      run = i
    } else if is_space(c) {
      let opened = i
      while i < upto && is_space(units[i].to_int()) {
        i += 1
      }
      if i - opened >= 2 {
        out.write_stringview(raw[run:opened])
        out.write_char(' ')
        run = i
      }
    } else {
      i += 1
    }
  }
  out.write_stringview(raw[run:upto])
  out.to_string()
}

///|
/// The rows of one group laid out over a grid: a cell's text in every
/// position it spans, a position a cell above still covers stepped over,
/// and a line as long as the cells that reached into it — a row shorter
/// than the table simply leaves its line short. A span that would carry
/// the grid past the positions a table's grid may hold refuses, naming
/// them.
fn laid_out(rows : Array[Row]) -> Array[Array[String]] raise @types.DataError {
  let grid : Array[Array[String]] = []
  let covered : Array[Array[Bool]] = []
  for r, row in rows {
    // A span from above may have opened the rows after it already.
    while grid.length() < r + 1 {
      grid.push([])
      covered.push([])
    }
    let mask = covered[r]
    let mut col = 0
    for cell in row.cells {
      while col < mask.length() && mask[col] {
        col += 1
      }
      if (r + cell.row_span).to_int64() * (col + cell.col_span).to_int64() >
        HTML_GRID_LIMIT {
        raise @types.DataError::ParseError(
          @types.ParseErrorDetail::Message(
            "html: a table's cell spans past the \{HTML_GRID_LIMIT} positions a table's grid may hold",
          ),
        )
      }
      let text = tidy_text(cell.text.to_string())
      for down in 0..<cell.row_span {
        let line = r + down
        while grid.length() < line + 1 {
          grid.push([])
          covered.push([])
        }
        // The positions before the cell, in a row it only reaches by its
        // span, are no cell's: an empty text, which reads as a missing cell.
        while grid[line].length() < col {
          grid[line].push("")
          covered[line].push(false)
        }
        // Every position the line gains past them is one this cell covers.
        while grid[line].length() < col + cell.col_span {
          grid[line].push(text)
          covered[line].push(true)
        }
      }
      col += cell.col_span
    }
  }
  grid
}

///|
/// The columns' names from the header rows laid out: a position's names
/// down the header, joined by a space, and the position's own number where
/// it has none. A table with no header names its columns by position.
fn column_names(head : Array[Array[String]], width : Int32) -> Array[String] {
  let names : Array[String] = []
  for j in 0..<width {
    let joined = StringBuilder()
    let mut first = true
    for line in head {
      if j < line.length() && !line[j].is_empty() {
        if !first {
          joined.write_char(' ')
        }
        joined.write_string(line[j])
        first = false
      }
    }
    let name = joined.to_string()
    names.push(if name.is_empty() { "column\{j + 1}" } else { name })
  }
  names
}

///|
/// The spellings of a missing cell.
let missing_spellings : ReadOnlyArray[String] = [
  "", "NA", "N/A", "n/a", "NULL", "null", "None", "NaN", "nan", "-NaN", "-nan", "<NA>",
  "#NA", "#N/A", "#N/A N/A", "1.#IND", "-1.#IND", "1.#QNAN", "-1.#QNAN",
]

///|
/// A number's text with the commas between its digit groups taken out. A
/// comma is a separator when a digit is before it and a digit, or the end
/// of the text, after it, and when the rest of the text is a number's — a
/// sign, digits, and one decimal point. Any other text is returned as it
/// is.
fn ungrouped(text : String) -> String {
  let units = text.code_units()
  let start = if units.length() > 0 &&
    (units[0].to_int() == 43 || units[0].to_int() == 45) {
    1
  } else {
    0
  }
  let mut commas = 0
  let mut dots = 0
  let mut plain = units.length() > start
  for i in start..<units.length() {
    let c = units[i].to_int()
    if is_digit(c) {
      ()
    } else if c == 44 {
      if i == start ||
        !is_digit(units[i - 1].to_int()) ||
        (i + 1 < units.length() && !is_digit(units[i + 1].to_int())) {
        plain = false
      }
      commas += 1
    } else if c == 46 {
      dots += 1
    } else {
      plain = false
    }
  }
  if !plain || dots > 1 || commas == 0 {
    return text
  }
  let out = StringBuilder()
  for i in 0..<units.length() {
    let c = units[i].to_int()
    if c != 44 {
      // A plain number's text is ASCII, sign and point included.
      out.write_char(c.unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// A data cell before it is typed: nothing for a missing value, and its
/// text otherwise.
fn body_cell(text : String) -> String? {
  if missing_spellings.contains(text) {
    None
  } else {
    Some(text)
  }
}

///|
/// One table as a frame: the header rows laid out name the columns, the
/// data rows laid out are the frame's rows, and each column takes the
/// narrowest dtype holding its values. `None` for a table that holds no
/// row at all.
fn html_frame(table : Table) -> @frame.DataFrame? raise @types.DataError {
  let (head, body) = header_rows(table)
  if head.is_empty() && body.is_empty() {
    return None
  }
  let head_grid = laid_out(head)
  let body_grid = laid_out(body)
  let mut width = 0
  for line in head_grid {
    if line.length() > width {
      width = line.length()
    }
  }
  for line in body_grid {
    if line.length() > width {
      width = line.length()
    }
  }
  let names = column_names(head_grid, width)
  let columns : Array[@series.Series] = []
  for j, name in names {
    // A position no cell reached — a row shorter than the table — reads
    // as a missing cell.
    let cells : Array[String?] = Array::makei(body_grid.length(), i => {
      if j < body_grid[i].length() {
        body_cell(body_grid[i][j])
      } else {
        None
      }
    })
    // A number's commas come out for the typing alone: a column that ends
    // a text column keeps the text as the document wrote it.
    let plain = cells.map(cell => cell.map(ungrouped))
    let column = probed_text_column(name, plain)
    if column.dtype() is @types.DataType::String {
      columns.push(@series.Series::from_string_options(name, cells))
    } else {
      columns.push(column)
    }
  }
  Some(@frame.DataFrame::from_parts(columns, body_grid.length()))
}

///|
/// Read the tables an HTML document holds — one frame a table, in the
/// order the document opens them. A file may be gzip-compressed. Raises
/// `IoError` for a path that cannot be read, and what `parse_html` states
/// for the text.
pub fn read_html(
  path : String,
) -> Array[@frame.DataFrame] raise @types.DataError {
  parse_html(read_text(path))
}

///|
/// Parse the tables an HTML document holds — one frame a table, in the
/// order the document opens them; a document with no table reads as no
/// frame.
///
/// The document is walked once and is never repaired beyond what a table
/// needs: a tag the document ends inside, a comment, a declaration, a
/// `script` or `style` element's text, and any element outside the table
/// elements are stepped over; a row or cell still open where the next one
/// starts, or where the table ends, ends there.
///
/// The rows and columns:
///
/// - Every `table` is a frame, a table nested in a cell included, as its
///   own frame after the one holding it — whose cell carries the nested
///   table's text.
/// - The rows read inside a `thead` are the header when there are any;
///   otherwise the leading rows whose every cell is a `th` are. The header
///   rows, spans laid out, name the columns — a position's names down the
///   header joined by a space — and a table with no header names its
///   columns `column1`, `column2`, …, as does a position the header leaves
///   empty. A `tfoot`'s rows are data.
/// - A cell's `rowspan` and `colspan` say how far it reaches: its text
///   fills every position, and a cell above that still covers a position
///   pushes the row's cells past it. A span that is not a number or is
///   zero is one; a span is at most 65534 rows and 1000 columns.
/// - A cell's text is everything in it: character references decoded —
///   the HTML 4 names and the numeric ones — and each run of line breaks,
///   a `br` included, and every other run of two or more whitespace
///   characters read as one space, the whitespace at the ends cut.
/// - A cell spelling a missing value — empty, `NA`, `N/A`, `n/a`, `NULL`,
///   `null`, `None`, `NaN`, `nan`, `-NaN`, `-nan`, `<NA>`, `#NA`, `#N/A`,
///   `#N/A N/A`, `1.#IND`, `-1.#IND`, `1.#QNAN`, `-1.#QNAN` — reads
///   missing, and a number with commas between its digit groups types as
///   that number, a text column keeping the commas as written. Each column
///   then takes the narrowest dtype holding its
///   values — `Int`, `Float`, `Bool`, then `String` — the CSV reader's
///   rule.
///
/// Raises `ParseError` (`Message`) for a text that is not UTF-8, and for a
/// table whose spans would carry its grid past the positions a table's
/// grid may hold; `DuplicateColumn(name)` for a header naming one column
/// twice.
pub fn parse_html(
  text : String,
) -> Array[@frame.DataFrame] raise @types.DataError {
  let frames : Array[@frame.DataFrame] = []
  for table in html_tables(strip_utf8_bom(text)) {
    match html_frame(table) {
      Some(frame) => frames.push(frame)
      None => ()
    }
  }
  frames
}
