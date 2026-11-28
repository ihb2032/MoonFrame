// The walk over content.xml's events. Sheets, rows and cells are marked
// as their elements open and close; a cell with a value takes the
// position its row and the repeats around it give it; and every count the
// file spells is held to a budget tied to the package's size before
// anything is stored by it.

///|
/// The three namespaces this reader reads by. Elements and attributes are
/// matched by the namespace itself, never by the prefix a document spells
/// it with.
priv enum Space {
  Office
  Table
  Text
}

///|
/// A namespace's URI.
fn Space::uri(self : Space) -> String {
  match self {
    Office => "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    Table => "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    Text => "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
  }
}

///|
/// A namespace's conventional prefix, for a message.
fn Space::prefix(self : Space) -> String {
  match self {
    Office => "office"
    Table => "table"
    Text => "text"
  }
}

///|
/// Which of the three namespaces a name is in, or nothing.
fn space_of(name : @xml.XmlName) -> Space? {
  match name.namespace_uri {
    Some(uri) =>
      if uri == Space::uri(Office) {
        Some(Office)
      } else if uri == Space::uri(Table) {
        Some(Table)
      } else if uri == Space::uri(Text) {
        Some(Text)
      } else {
        None
      }
    None => None
  }
}

///|
/// A cell of a row that holds a value, and the columns it takes.
priv struct Placed {
  col : Int64
  repeat : Int64
  value : OdsValue
}

///|
/// A row between its element's start and end.
priv struct OpenRow {
  depth : Int32
  // How many rows the element stands for.
  repeat : Int64
  // The column the next cell with a value takes; the empty cells waiting
  // before it are not counted here.
  mut col : Int64
  // The empty cells waiting for a cell with a value after them.
  mut empty : Int64
  placed : Array[Placed]
  // One past the last column holding a value: -1 while none does.
  mut last : Int64
}

///|
/// A sheet as it is read.
priv struct Sheet {
  name : String
  depth : Int32
  cells : Array[OdsCell]
  // The row the next one with a value starts at.
  mut next_row : Int64
  // The rows with no value, waiting for a row with a value after them.
  mut empty_rows : Int64
  // The last repeat attribute read in the sheet that spelled more than
  // one: what a sheet made too big is blamed on.
  mut cause : Attr?
  // One past the last column holding a value.
  mut width : Int64
  // The cells the sheet holds, repeats counted.
  mut held : Int64
}

///|
/// The workbook while content.xml is read.
priv struct Book {
  document : Document
  // The most cells a sheet may hold, and the most spaces the document may
  // spell.
  budget : Int64
  size : Int32
  // Whether the package had no mimetype entry, so its content.xml's root
  // judges it.
  judged_by_root : Bool
  mut rooted : Bool
  // The depth of the office:body element open, or -1.
  mut body : Int32
  // The spaces the document's text:s elements with a text:c have spelled.
  mut spaces : Int64
  sheets : Array[Sheet]
  // The tables open, the innermost last.
  tables : Array[Sheet]
  // The rows open, the innermost last.
  rows : Array[OpenRow]
  // The cells open, the innermost last.
  cells : Array[OpenCell]
}

///|
/// The most cells a sheet may hold — and the most spaces the document may
/// spell — for a package of `size` bytes: 65 536 and eight to a byte, and
/// never more than 2^25.
fn cell_budget(size : Int32) -> Int64 {
  let linear = 65536L + size.to_int64() * 8L
  if linear < 33554432L {
    linear
  } else {
    33554432L
  }
}

///|
/// The workbook content.xml holds, its budget set by the package's size.
fn read_document(
  document : Document,
  size : Int32,
  judged_by_root : Bool,
) -> Array[OdsGrid] raise @types.DataError {
  let book = Book::{
    document,
    budget: cell_budget(size),
    size,
    judged_by_root,
    rooted: false,
    body: -1,
    spaces: 0L,
    sheets: [],
    tables: [],
    rows: [],
    cells: [],
  }
  book.walk()
  book.sheets.map(sheet => sheet.grid())
}

///|
/// The sheet as the caller gets it.
fn Sheet::grid(self : Sheet) -> OdsGrid {
  OdsGrid::{ name: self.name, cells: self.cells, }
}

///|
/// The count an attribute spells: ASCII digits only, and at most
/// 2 147 483 647 — more than any row or column a sheet has.
fn take_count(attr : Attr) -> Int64 raise @types.DataError {
  let units = attr.value.code_units()
  if units.length() == 0 {
    raise attr.refusal("is not a whole number")
  }
  let mut value = 0L
  for i in 0..<units.length() {
    let unit = units[i].to_int()
    if unit < 0x30 || unit > 0x39 {
      raise attr.refusal("is not a whole number")
    }
    value = value * 10L + (unit - 0x30).to_int64()
    if value > 2147483647L {
      raise attr.refusal("is past the largest count this reader takes")
    }
  }
  value
}

///|
/// An element's attribute in one of the three namespaces, by its part
/// name.
fn Book::attribute(
  self : Book,
  element : @xml.NamespaceElement,
  space : Space,
  part : String,
) -> Attr? {
  let uri = space.uri()
  let found = element.attributes.search_by(found => {
    found.name.namespace_uri == Some(uri) && found.name.local_name == part
  })
  match found {
    Some(index) => {
      let found = element.attributes[index]
      Some(Attr::{
        name: "\{space.prefix()}:\{part}",
        value: found.value,
        byte: self.document.byte(found.span.start.offset),
      })
    }
    None => None
  }
}

///|
/// The refusal for a sheet made to hold more cells than the budget: the
/// repeat attribute that did it is named where one did.
fn Sheet::too_big(self : Sheet, book : Book) -> @types.DataError {
  let grant = "than this reader grants a package of \{book.size} bytes (\{book.budget})"
  match self.cause {
    Some(attr) =>
      attr.refusal(
        "would make sheet \"\{cut(self.name, 64)}\" hold more cells \{grant}",
      )
    None =>
      bad(
        "ods: content.xml: sheet \"\{cut(self.name, 64)}\" holds more cells \{grant}",
      )
  }
}

///|
/// The events of content.xml, one after another, until the document ends;
/// the first the XML reader refuses ends the read.
fn Book::walk(self : Book) -> Unit raise @types.DataError {
  let reader = @xml.NamespaceReader::from_string(self.document.text)
  let mut depth = 0
  for ;; {
    let next : Result[@xml.NamespaceEvent, @xml.XmlError] = Ok(
      reader.read_event(),
    ) catch {
      e => Err(e)
    }
    let event = match next {
      Ok(event) => event
      Err(error) => raise self.ill_formed(error)
    }
    match event.kind {
      Start(element) => {
        depth += 1
        self.open(element, depth, event.span.start.offset)
      }
      Empty(element) => {
        self.open(element, depth + 1, event.span.start.offset)
        self.shut(element.name, depth + 1)
      }
      End(name) => {
        self.shut(name, depth)
        depth -= 1
      }
      Text(text) | CData(text) => self.text(text)
      Comment(_) | PI(..) | Decl(..) | DocType(_) => ()
      Eof => break
    }
  }
}

///|
/// The XML reader's refusal: content.xml is not well-formed, or is cut
/// short, at the byte its position names.
fn Book::ill_formed(self : Book, error : @xml.XmlError) -> @types.DataError {
  let byte = match error {
    @xml.XmlError::At(error~, span~) => {
      ignore(error)
      self.document.byte(span.start.offset)
    }
  }
  bad("ods: content.xml byte \{byte} is not well-formed: \{error}")
}

///|
/// An element opens: the root is judged where the package has no mimetype
/// entry; the body, a table, a row or a cell is marked; and a string cell
/// open around the element takes it into its string.
fn Book::open(
  self : Book,
  element : @xml.NamespaceElement,
  depth : Int32,
  at : Int32,
) -> Unit raise @types.DataError {
  if !self.rooted {
    self.rooted = true
    if self.judged_by_root {
      self.judge_root(element)
    }
  }
  let space = space_of(element.name)
  let part = element.name.local_name
  let in_table = space is Some(Table) &&
    (part == "table-cell" || part == "covered-table-cell")
  if self.cells.length() > 0 {
    self.element_open(element)
  }
  if space is Some(Office) && part == "body" {
    self.body = depth
  } else if space is Some(Table) && part == "table" {
    if self.body >= 0 {
      self.open_table(element, depth)
    }
  } else if space is Some(Table) && part == "table-row" {
    if self.tables.length() > 0 {
      self.open_row(element, depth)
    }
  } else if in_table {
    // A cell is one directly under a row.
    let under_row = self.rows.length() > 0 &&
      self.rows[self.rows.length() - 1].depth == depth - 1
    if under_row {
      self.start_cell(
        element,
        depth,
        self.document.byte(at),
        part == "covered-table-cell",
      )
    }
  }
}

///|
/// An element closes: a cell takes its place in its row, a row its rows
/// in its sheet, and a table ends; then a string cell still open around
/// the element takes the close into its string.
fn Book::shut(
  self : Book,
  name : @xml.XmlName,
  depth : Int32,
) -> Unit raise @types.DataError {
  let space = space_of(name)
  let part = name.local_name
  let in_table = space is Some(Table) &&
    (part == "table-cell" || part == "covered-table-cell")
  if space is Some(Office) && part == "body" {
    if self.body == depth {
      self.body = -1
    }
  } else if space is Some(Table) && part == "table" {
    let open = self.tables.length() > 0 &&
      self.tables[self.tables.length() - 1].depth == depth
    if open {
      ignore(self.tables.pop())
    }
  } else if space is Some(Table) && part == "table-row" {
    let open = self.rows.length() > 0 &&
      self.rows[self.rows.length() - 1].depth == depth
    if open {
      let row = self.rows[self.rows.length() - 1]
      ignore(self.rows.pop())
      self.close_row(row)
    }
  } else if in_table {
    let open = self.cells.length() > 0 &&
      self.cells[self.cells.length() - 1].depth == depth
    if open {
      let cell = self.cells[self.cells.length() - 1]
      ignore(self.cells.pop())
      self.close_cell(cell)
      return
    }
  }
  for cell in self.cells {
    cell.close()
  }
}

///|
/// The root of content.xml where the package has no mimetype entry: the
/// document-content element, saying a spreadsheet where it says anything.
fn Book::judge_root(
  self : Book,
  root : @xml.NamespaceElement,
) -> Unit raise @types.DataError {
  let content = space_of(root.name) is Some(Office) &&
    root.name.local_name == "document-content"
  if !content {
    raise nope(
      "ods: content.xml's root element is \"\{cut(root.name.qualified_name, 64)}\", not an OpenDocument document-content element",
    )
  }
  let kind = self.attribute(root, Office, "mimetype")
  if kind is Some(kind) {
    if kind.value != SPREADSHEET {
      raise nope(
        "ods: content.xml's office:mimetype is \"\{cut(kind.value, 64)}\", not an OpenDocument spreadsheet's",
      )
    }
  }
}

///|
/// A table opens in the body: a sheet, named by table:name — `""` where
/// the attribute is absent.
fn Book::open_table(
  self : Book,
  element : @xml.NamespaceElement,
  depth : Int32,
) -> Unit {
  let name = match self.attribute(element, Table, "name") {
    Some(name) => name.value
    None => ""
  }
  let sheet = Sheet::{
    name,
    depth,
    cells: [],
    next_row: 0L,
    empty_rows: 0L,
    cause: None,
    width: 0L,
    held: 0L,
  }
  self.sheets.push(sheet)
  self.tables.push(sheet)
}

///|
/// A row opens in the innermost table: how many rows it stands for is
/// read at once.
fn Book::open_row(
  self : Book,
  element : @xml.NamespaceElement,
  depth : Int32,
) -> Unit raise @types.DataError {
  let (repeat, cause) = match
    self.attribute(element, Table, "number-rows-repeated") {
    Some(attr) => {
      let count = take_count(attr)
      (count, if count > 1L { Some(attr) } else { None })
    }
    None => (1L, None)
  }
  let sheet = self.tables[self.tables.length() - 1]
  if cause is Some(_) {
    sheet.cause = cause
  }
  self.rows.push(OpenRow::{
    depth,
    repeat,
    col: 0L,
    empty: 0L,
    placed: [],
    last: -1L,
  })
}

///|
/// A cell opens directly under the innermost row: how many columns it
/// takes, and what its value type is, are read at once.
fn Book::start_cell(
  self : Book,
  element : @xml.NamespaceElement,
  depth : Int32,
  byte : Int32,
  covered : Bool,
) -> Unit raise @types.DataError {
  let (repeat, cause) = match
    self.attribute(element, Table, "number-columns-repeated") {
    Some(attr) => {
      let count = take_count(attr)
      (count, if count > 1L { Some(attr) } else { None })
    }
    None => (1L, None)
  }
  let sheet = self.tables[self.tables.length() - 1]
  if cause is Some(_) {
    sheet.cause = cause
  }
  let kind = match self.attribute(element, Office, "value-type") {
    Some(kind) => kind.value
    None => ""
  }
  let timed = self.attribute(element, Office, "time-value") is Some(_)
  self.cells.push(open_cell(element, depth, byte, covered, repeat, kind, timed))
}

///|
/// A cell closes: with a value it takes the columns after the empty cells
/// waiting before it; without one it waits with them.
fn Book::close_cell(
  self : Book,
  cell : OpenCell,
) -> Unit raise @types.DataError {
  cell.close()
  let row = self.rows[self.rows.length() - 1]
  let value = self.cell_value(cell)
  match value {
    None => row.empty += cell.repeat
    Some(value) => {
      let col = row.col + row.empty
      row.empty = 0L
      row.col = col + cell.repeat
      if cell.repeat > 0L {
        if row.last < row.col {
          row.last = row.col
        }
        row.placed.push(Placed::{ col, repeat: cell.repeat, value, })
      }
    }
  }
}

///|
/// A row closes. One with no value waits with the rows before it that had
/// none. One with a value takes its rows after theirs — and its cells
/// their columns — once the sheet it makes has been measured against the
/// budget: each count on its own before any two are multiplied.
fn Book::close_row(self : Book, row : OpenRow) -> Unit raise @types.DataError {
  let sheet = self.tables[self.tables.length() - 1]
  if row.last < 0L {
    sheet.empty_rows += row.repeat
    return
  }
  let first = sheet.next_row + sheet.empty_rows
  let rows = first + row.repeat
  let width = if sheet.width > row.last { sheet.width } else { row.last }
  let held = sheet.held + row.placed.length().to_int64() * row.repeat
  if rows > self.budget ||
    width > self.budget ||
    rows * width > self.budget ||
    held > self.budget {
    raise sheet.too_big(self)
  }
  // Every position is below the budget, so each fits the 32-bit index it
  // is stored as.
  let mut k = 0L
  while k < row.repeat {
    let at = (first + k).to_int()
    for placed in row.placed {
      let mut j = 0L
      while j < placed.repeat {
        sheet.cells.push(OdsCell::{
          row: at,
          col: (placed.col + j).to_int(),
          value: placed.value,
        })
        j += 1L
      }
    }
    k += 1L
  }
  sheet.held = held
  sheet.width = width
  sheet.next_row = rows
  sheet.empty_rows = 0L
}

///|
/// Text inside the cells still open: each keeps what its type asks of it.
fn Book::text(self : Book, text : String) -> Unit {
  for cell in self.cells {
    cell.text(text)
  }
}

///|
/// An element opens inside the cells still open. A string cell's string
/// takes it as the element's name says; a text:s spells its text:c spaces,
/// counted and held to the budget.
fn Book::element_open(
  self : Book,
  element : @xml.NamespaceElement,
) -> Unit raise @types.DataError {
  let space = space_of(element.name)
  let part = element.name.local_name
  let level : Level = if space is Some(Text) && part == "s" {
    Space
  } else if space is Some(Text) && part == "line-break" {
    Break
  } else if space is Some(Text) && part == "p" {
    Paragraph
  } else if space is Some(Office) && part == "annotation" {
    Annotation
  } else {
    Other
  }
  let composing = self.cells.any(cell => cell.composes)
  let spaces = if level is Space && composing {
    self.spell_spaces(element)
  } else {
    1
  }
  for cell in self.cells {
    cell.open(level, spaces)
  }
}

///|
/// The spaces a text:s spells: one, or its text:c — a count, and one whose
/// sum over the document stays inside the budget.
fn Book::spell_spaces(
  self : Book,
  element : @xml.NamespaceElement,
) -> Int32 raise @types.DataError {
  match self.attribute(element, Text, "c") {
    None => 1
    Some(count) => {
      let spaces = take_count(count)
      self.spaces += spaces
      if self.spaces > self.budget {
        raise count.refusal(
          "would spell more spaces than this reader grants a package of \{self.size} bytes (\{self.budget})",
        )
      }
      spaces.to_int()
    }
  }
}

///|
/// The value a cell holds, or nothing for an empty cell. A cell whose
/// whole text is "#N/A" is empty, as is one with no value type. A covered
/// cell with no office:value is empty whatever else it holds.
fn Book::cell_value(
  self : Book,
  cell : OpenCell,
) -> OdsValue? raise @types.DataError {
  if cell.is_na() {
    return None
  }
  let kind = match self.attribute(cell.element, Office, "value-type") {
    None => return None
    Some(kind) => kind
  }
  let value = self.attribute(cell.element, Office, "value")
  if cell.covered && value is None {
    return None
  }
  match kind.value {
    "float" | "percentage" | "currency" =>
      match value {
        Some(value) => Some(OdsValue::Number(parse_number(value.value, value)))
        None =>
          raise bad(
            "ods: content.xml byte \{cell.byte}: a \{kind.value} cell carries no office:value",
          )
      }
    "boolean" => Some(OdsValue::Boolean(cell.is_true()))
    "string" =>
      if cell.composed() == "" {
        None
      } else {
        Some(OdsValue::Text(cell.composed()))
      }
    "date" =>
      match self.attribute(cell.element, Office, "date-value") {
        Some(date) =>
          if date.value == "" {
            None
          } else {
            Some(parse_date(date.value, date))
          }
        None => None
      }
    "time" =>
      match self.attribute(cell.element, Office, "time-value") {
        Some(time) => Some(OdsValue::Time(parse_duration(time.value, time)))
        None =>
          if cell.raw.to_string().trim() == "" {
            None
          } else {
            Some(
              OdsValue::Time(parse_clock_text(cell.raw.to_string(), cell.byte)),
            )
          }
      }
    "void" => None
    _ =>
      raise nope(
        "ods: content.xml byte \{kind.byte}: the office:value-type \"\{cut(kind.value, 32)}\" is not a value type this reader carries",
      )
  }
}
