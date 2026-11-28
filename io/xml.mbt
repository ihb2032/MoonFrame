// The XML table interchange. A path names the elements that are the rows,
// and a row's attributes, its own text, and its direct child elements are
// the columns. The document is held whole and walked event by event: the
// reader keeps only the elements still open, so a row costs what its cells
// cost. The writer lays a frame out in the same shape.

///|
/// The path that names a document's rows: its steps — each an element's
/// name as written, or `*` for any element — and whether they run from the
/// document element down, or end at any depth below it.
priv struct RowPath {
  from_root : Bool
  steps : Array[String]
}

///|
/// One open element while the document streams past: what a row is built
/// from, should the element turn out to be one.
priv struct Open {
  name : String
  mut is_row : Bool
  // The attributes that are not namespace declarations.
  attributes : Array[(String, String)]
  // The elements closed directly inside this one: a name, and the
  // element's text before its own first child, or nothing for an empty one.
  cells : Array[(String, String?)]
  // The character data directly inside this element, before its first
  // child.
  text : StringBuilder
  mut before_child : Bool
}

///|
/// Whether `step` is `*`, or an element's name as a document writes it: a
/// letter or `_` first, then letters, digits, `_`, `-`, `.` and the `:` a
/// prefix ends with. A character outside ASCII is taken anywhere in the
/// name: a path's syntax is all ASCII, so such a character can only be
/// part of a name.
fn path_step_ok(step : String) -> Bool {
  if step == "*" {
    return true
  }
  let mut first = true
  let mut ok = true
  for c in step {
    let taken = !c.is_ascii() ||
      c.is_ascii_alphabetic() ||
      c == '_' ||
      (!first && (c.is_ascii_digit() || c == '-' || c == '.' || c == ':'))
    if !taken {
      ok = false
    }
    first = false
  }
  ok && !first
}

///|
/// The refusal for a path this reader does not take.
fn bad_path(xpath : String) -> @types.DataError {
  @types.DataError::InvalidOperation(
    "xml: the path \"\{xpath}\" is not one this reader takes: element names or * separated by /, from the document element (/a/b), from the element below it (a/b), or at any depth below it (//b)",
  )
}

///|
/// The rows a path names. A leading `//` or `.//` ends the steps at any
/// depth below the document element; a leading `/` runs them from the
/// document element down; and `./`, or no leading slash at all, runs them
/// from the document element's children. A path with nothing in it, an
/// empty step — a `//` inside the path, or a slash left dangling — and a
/// step that is not an element's name or `*` refuse, naming the path.
fn row_path(xpath : String) -> RowPath raise @types.DataError {
  let (from_root, rest) = if xpath.has_prefix("//") || xpath.has_prefix(".//") {
    let cut = if xpath.has_prefix(".//") { 3 } else { 2 }
    (false, "\{xpath[cut:]}")
  } else if xpath.has_prefix("/") {
    (true, "\{xpath[1:]}")
  } else if xpath.has_prefix("./") {
    (true, "*/\{xpath[2:]}")
  } else {
    (true, "*/\{xpath}")
  }
  let steps : Array[String] = rest
    .split("/")
    .map(step => step.to_owned())
    .collect()
  if rest.is_empty() || steps.any(step => !path_step_ok(step)) {
    raise bad_path(xpath)
  }
  RowPath::{ from_root, steps, }
}

///|
/// Whether the open elements end in this path's steps. From the document
/// element, the steps are the whole stack; at any depth, they are its top,
/// with the document element itself below them — a row is always an
/// element inside the document element.
fn RowPath::selects(self : RowPath, stack : Array[Open]) -> Bool {
  let depth = stack.length()
  let count = self.steps.length()
  if self.from_root {
    if depth != count {
      return false
    }
  } else if depth < count + 1 {
    return false
  }
  let base = depth - count
  for k in 0..<count {
    let step = self.steps[k]
    if step != "*" && stack[base + k].name != step {
      return false
    }
  }
  true
}

///|
/// Whether `text` is nothing but whitespace.
fn blank(text : String) -> Bool {
  for c in text {
    if !c.is_whitespace() {
      return false
    }
  }
  true
}

///|
/// A cell's text with the whitespace around it cut — an indented document
/// puts a line break and spaces inside nearly every element — and kept as
/// written when it is nothing but whitespace.
fn trimmed_cell(text : String) -> String {
  if blank(text) {
    text
  } else {
    text.trim().to_owned()
  }
}

///|
/// A document that is not well-formed: the reader's error, with the
/// line and column it names.
fn xml_error(error : @xml.XmlError) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("xml: \{error}"),
  )
}

///|
/// An element's start: pushed on the open elements and marked a row when
/// the path selects it; the element it opens inside takes no more direct
/// text of its own.
fn open_element(
  stack : Array[Open],
  path : RowPath,
  name : String,
  attributes : Array[@xml.XmlAttribute],
) -> Unit {
  let kept : Array[(String, String)] = []
  for attribute in attributes {
    let declaration = attribute.name == "xmlns" ||
      attribute.name.has_prefix("xmlns:")
    if !declaration {
      kept.push((attribute.name, attribute.value))
    }
  }
  let element = Open::{
    name,
    is_row: false,
    attributes: kept,
    cells: [],
    text: StringBuilder(),
    before_child: true,
  }
  stack.push(element)
  stack[stack.length() - 1].is_row = path.selects(stack)
  if stack.length() >= 2 {
    stack[stack.length() - 2].before_child = false
  }
}

///|
/// An element's end: popped off the open elements. One that opened
/// directly inside a row leaves a cell there — its text, or nothing when
/// it is empty — and one that is a row itself is laid out as one: its
/// attributes, its own text where that is not blank, and then its cells.
/// An end with no element open is a document the reader should have
/// refused: it refuses here too, rather than closing nothing silently.
fn close_element(
  stack : Array[Open],
  rows : Array[Array[(String, String?)]],
) -> Unit raise @types.DataError {
  let open = match stack.pop() {
    Some(open) => open
    None =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "xml: an element ends that never began",
        ),
      )
  }
  let text = open.text.to_string()
  if !stack.is_empty() && stack[stack.length() - 1].is_row {
    // A cell before its own first child only: what follows a nested
    // element is not the cell's.
    let value = if text.is_empty() { None } else { Some(trimmed_cell(text)) }
    stack[stack.length() - 1].cells.push((open.name, value))
  }
  if open.is_row {
    let cells : Array[(String, String?)] = []
    for attribute in open.attributes {
      cells.push((attribute.0, Some(attribute.1)))
    }
    if !blank(text) {
      cells.push((open.name, Some(trimmed_cell(text))))
    }
    for cell in open.cells {
      cells.push(cell)
    }
    rows.push(cells)
  }
}

///|
/// The rows a path selects in a document, each as its cells in document
/// order: a column's name, and the cell's text or nothing. Events are
/// pulled until the document ends, and the first one the reader refuses
/// ends the read.
fn xml_rows(
  text : String,
  path : RowPath,
) -> Array[Array[(String, String?)]] raise @types.DataError {
  let reader = @xml.Reader::from_string(text)
  let stack : Array[Open] = []
  let rows : Array[Array[(String, String?)]] = []
  while true {
    let event = reader.read_event() catch { e => raise xml_error(e) }
    match event.kind {
      Start(element) =>
        open_element(stack, path, element.name, element.attributes)
      Empty(element) => {
        open_element(stack, path, element.name, element.attributes)
        close_element(stack, rows)
      }
      End(_) => close_element(stack, rows)
      Text(t) | CData(t) =>
        if !stack.is_empty() && stack[stack.length() - 1].before_child {
          stack[stack.length() - 1].text.write_string(t)
        }
      Comment(_) | PI(..) | Decl(..) | DocType(_) => ()
      Eof => break
    }
  }
  rows
}

///|
/// The table a path selects, as a frame: the columns in first-seen order,
/// each typed by the narrowest dtype holding every cell in it, the CSV
/// reader's rule. A name that repeats in one row keeps its last cell, and
/// an element named like an attribute of its row takes the attribute's
/// column.
fn xml_frame(
  text : String,
  path : RowPath,
) -> @frame.DataFrame raise @types.DataError {
  let rows = xml_rows(text, path)
  let names : Array[String] = []
  let places : Map[String, Int32] = Map([])
  let table : Array[Array[String?]] = []
  for cells in rows {
    let line : Array[String?] = Array::make(names.length(), None)
    for (name, value) in cells {
      match places.get(name) {
        Some(at) => line[at] = value
        None => {
          places[name] = names.length()
          names.push(name)
          line.push(value)
        }
      }
    }
    table.push(line)
  }
  let columns : Array[@series.Series] = []
  for j, name in names {
    // A column first met in a later row: the rows before it hold nothing.
    let cells : Array[String?] = Array::makei(table.length(), i => {
      if j < table[i].length() {
        table[i][j]
      } else {
        None
      }
    })
    columns.push(probed_text_column(name, cells))
  }
  @frame.DataFrame::from_parts(columns, table.length())
}

///|
/// A document's bytes decoded as UTF-8, refusing the first malformed byte
/// by its offset.
fn utf8_text(path : String, bytes : Bytes) -> String raise @types.DataError {
  @utf8.decode(bytes) catch {
    @utf8.Malformed(tail) =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file \{path} is not valid UTF-8: first malformed byte at offset \{bytes.length() - tail.length()}",
        ),
      )
  }
}

///|
/// A document's bytes decoded as UTF-16 in one byte order.
fn utf16_text(
  path : String,
  bytes : Bytes,
  order : @utf16.Endian,
) -> String raise @types.DataError {
  @utf16.decode(bytes, endianness=order) catch {
    _ =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file \{path} is not valid UTF-16: an odd length or a lone surrogate",
        ),
      )
  }
}

///|
/// A document's bytes decoded one byte to one character — the whole of
/// US-ASCII and of ISO-8859-1.
fn latin1_text(bytes : BytesView) -> String {
  let out = StringBuilder()
  for b in bytes {
    out.write_char(b.to_char())
  }
  out.to_string()
}

///|
/// Where a document's declaration names its encoding: the code-unit range
/// of the name between its quotes. `None` when the text does not open with
/// a declaration, when the declaration names none, or when the name is not
/// closed inside it.
fn declared_range(text : String) -> (Int32, Int32)? {
  if !text.has_prefix("<?xml") {
    return None
  }
  let units = text.code_units()
  if units.length() < 6 {
    return None
  }
  // A processing instruction opens the same way; a declaration follows
  // its name with whitespace.
  let opener = units[5].to_int()
  if opener != 32 && opener != 9 && opener != 10 && opener != 13 {
    return None
  }
  let end = match text.find("?>") {
    Some(end) => end
    None => return None
  }
  // The name is looked for inside the declaration alone.
  let at = match text.find("encoding") {
    Some(at) => at
    None => return None
  }
  if at + 8 > end {
    return None
  }
  let units = text.code_units()
  let mut i = at + 8
  while i < end && units[i].to_int() == 32 {
    i += 1
  }
  if i >= end || units[i].to_int() != 61 {
    return None
  }
  i += 1
  while i < end && units[i].to_int() == 32 {
    i += 1
  }
  if i >= end {
    return None
  }
  let quote = units[i].to_int()
  if quote != 34 && quote != 39 {
    return None
  }
  i += 1
  let start = i
  while i < end && units[i].to_int() != quote {
    i += 1
  }
  if i >= end {
    return None
  }
  Some((start, i))
}

///|
/// The encoding a document's declaration names, lower-cased, or nothing.
/// The first hundred bytes are read one to a character: a document in an
/// encoding this reader decodes writes its declaration in ASCII.
fn declared_encoding(bytes : Bytes) -> String? {
  let window = if bytes.length() < 100 { bytes.length() } else { 100 }
  let head = latin1_text(bytes[0:window])
  let (from, to) = match declared_range(head) {
    Some(range) => range
    None => return None
  }
  Some(head[from:to].to_owned().to_lower())
}

///|
/// Whether an encoding's name is UTF-8's.
fn is_utf8(name : String) -> Bool {
  name == "utf-8" || name == "utf8"
}

///|
/// Whether an encoding's name is one ISO-8859-1 holds whole.
fn is_latin1(name : String) -> Bool {
  name == "iso-8859-1" ||
  name == "iso8859-1" ||
  name == "latin-1" ||
  name == "latin1" ||
  name == "us-ascii" ||
  name == "ascii"
}

///|
/// A transcoded document with its declaration saying UTF-8, which is now
/// what the text is. A declaration that names no encoding, and a document
/// without one, are left as they are.
fn redeclare(text : String) -> String {
  let (from, to) = match declared_range(text) {
    Some(range) => range
    None => return text
  }
  "\{text[0:from]}utf-8\{text[to:]}"
}

///|
/// A document's bytes as text, in the encoding its mark or declaration
/// names. A byte-order mark for UTF-8 is skipped; a mark for UTF-16, or a
/// `<` beside a zero byte, decodes as UTF-16 in that byte order; a
/// declaration naming ISO-8859-1 (or US-ASCII, which it holds) decodes
/// byte for byte; any other declared encoding refuses by name; and with no
/// mark and no such declaration the bytes are UTF-8, strictly.
fn xml_text(path : String, bytes : Bytes) -> String raise @types.DataError {
  let marked = bytes.length() >= 2 &&
    (
      (bytes[0] == b'\xFF' && bytes[1] == b'\xFE') ||
      (bytes[0] == b'\xFE' && bytes[1] == b'\xFF')
    )
  let zeroed = bytes.length() >= 2 &&
    (
      (bytes[0] == b'\x00' && bytes[1] == b'<') ||
      (bytes[0] == b'<' && bytes[1] == b'\x00')
    )
  if marked || zeroed {
    let little = bytes[0] == b'\xFF' || bytes[1] == b'\x00'
    let order = if little { @utf16.Endian::Little } else { @utf16.Endian::Big }
    let text = strip_utf8_bom(utf16_text(path, bytes, order))
    return redeclare(text)
  }
  if bytes.length() >= 3 &&
    bytes[0] == b'\xEF' &&
    bytes[1] == b'\xBB' &&
    bytes[2] == b'\xBF' {
    return utf8_text(path, bytes[3:].to_owned())
  }
  match declared_encoding(bytes) {
    Some(name) =>
      if is_utf8(name) {
        utf8_text(path, bytes)
      } else if is_latin1(name) {
        redeclare(latin1_text(bytes))
      } else {
        raise @types.DataError::Unsupported(
          "xml: the document declares the \{name} encoding, which this reader does not decode",
        )
      }
    None => utf8_text(path, bytes)
  }
}

///|
/// Whether `name` can be an element's name in a written document: one or
/// more of ASCII letters, digits, `_`, `-` and `.`, opening with a letter
/// or `_`.
fn xml_name_ok(name : String) -> Bool {
  let mut first = true
  let mut ok = true
  for c in name {
    let taken = c.is_ascii_alphabetic() ||
      c == '_' ||
      (!first && (c.is_ascii_digit() || c == '-' || c == '.'))
    if !taken {
      ok = false
    }
    first = false
  }
  ok && !first
}

///|
/// Refuse a name a written element cannot carry, saying which kind of
/// element it names.
fn check_xml_name(name : String, what : String) -> Unit raise @types.DataError {
  if !xml_name_ok(name) {
    raise @types.DataError::InvalidOperation(
      "xml: the \{what} name \"\{name}\" is not an element name this writer carries (a letter or _, then letters, digits, _, - and .)",
    )
  }
}

///|
/// One cell as the text its element holds — `None` for a missing cell, which
/// is written as an empty element — a string as itself, every other scalar
/// as its text form. A decimal, a span, a list, and a struct refuse: read
/// back, they would be a float or a string, and the frame would not
/// round-trip.
fn xml_cell_text(
  column : String,
  scalar : @types.Scalar,
) -> String? raise @types.DataError {
  match scalar {
    Null => None
    String(value) => Some(value)
    Int(_) | Float(_) | Bool(_) | Date(_) | Timestamp(_) =>
      Some(scalar.to_string())
    Decimal(_) | Duration(_) | List(_) | Struct(_) =>
      raise @types.DataError::Unsupported(
        "xml cannot carry column \"\{column}\" of dtype \{scalar.dtype()}",
      )
  }
}

///|
/// Read the table an XML document holds into a frame — `parse_xml` over a
/// file, which may be gzip-compressed. Raises `IoError` for a path that
/// cannot be read, and what `parse_xml` states for the bytes.
pub fn read_xml(
  path : String,
  xpath~ : String = ".//row",
) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_xml(xml_text(path, gunzip_bytes(path, bytes)), xpath~)
}

///|
/// Parse an XML document into a frame: the elements the path selects are
/// the rows, and a row's columns are its attributes, its own text, and its
/// direct child elements, in document order.
///
/// `xpath` names the rows. A leading `//` (or `.//`) selects at any depth
/// below the document element — the default, `.//row`, every `row` element
/// in the document; a leading `/` runs from the document element down
/// (`/records/row`); and `a/b`, or `./a/b`, runs from the document
/// element's children. A step is an element's name as written, prefix
/// included, or `*` for any element. A path with an empty step, a `//`
/// inside it, or a step that is not a name refuses with
/// `InvalidOperation`, and a path that selects nothing reads as a frame of
/// no row and no column.
///
/// The cells:
///
/// - An attribute of the row is a column under its name; a namespace
///   declaration is not.
/// - A direct child element is a column under its name, its cell the text
///   directly inside it before any nested element — a nested element adds
///   nothing, and an empty one reads missing.
/// - Text directly inside a row that is not blank is a column under the
///   row's own name.
/// - A cell's text has the whitespace around it cut; whitespace inside it
///   stays. A name that repeats in one row keeps its last cell, and an
///   element named like an attribute takes the attribute's column.
/// - Each column takes the narrowest dtype holding every value in it —
///   `Int`, `Float`, `Bool`, then `String` — the CSV reader's rule; a
///   column of nothing but missing cells is `String`.
///
/// Raises `ParseError` (`Message`) for a document that is not well-formed,
/// naming the line and column; `Unsupported` for a declared encoding other
/// than UTF-8, UTF-16, and ISO-8859-1; and `InvalidOperation` for a path
/// this reader does not take.
pub fn parse_xml(
  text : String,
  xpath~ : String = ".//row",
) -> @frame.DataFrame raise @types.DataError {
  xml_frame(strip_utf8_bom(text), row_path(xpath))
}

///|
/// Write a frame as one XML document — `format_xml`'s text under `path`,
/// gzip-compressed when the path ends in `.gz`.
pub fn write_xml(
  df : @frame.DataFrame,
  path : String,
  root_name~ : String = "data",
  row_name~ : String = "row",
) -> Unit raise @types.DataError {
  write_text(path, format_xml(df, root_name~, row_name~))
}

///|
/// A frame as one XML document: a UTF-8 declaration, the root element
/// `root_name` holding one `row_name` element a row, and each row holding
/// one element a column, named after it, with the cell's text — a missing
/// cell an empty element, a string as itself, and every other scalar in
/// its text form. The same frame writes the same document.
///
/// Raises `InvalidOperation` for a root, row, or column name that is not
/// an element name (a letter or `_`, then ASCII letters, digits, `_`, `-`
/// and `.`), naming it; and `Unsupported` for a `Decimal`, `Duration`,
/// `List`, or `Struct` column, which would not read back as itself.
pub fn format_xml(
  df : @frame.DataFrame,
  root_name~ : String = "data",
  row_name~ : String = "row",
) -> String raise @types.DataError {
  check_xml_name(root_name, "root")
  check_xml_name(row_name, "row")
  let columns = df.column_series()
  for column in columns {
    check_xml_name(column.name(), "column")
  }
  let cells = columns.map(column => column.to_scalars())
  let out = StringBuilder()
  out.write_string("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
  out.write_string("<\{root_name}>\n")
  for row in 0..<df.nrows() {
    out.write_string("  <\{row_name}>\n")
    for c, column in columns {
      let name = column.name()
      match xml_cell_text(name, cells[c][row]) {
        Some(text) =>
          out.write_string("    <\{name}>\{@xml.escape(text)}</\{name}>\n")
        None => out.write_string("    <\{name}/>\n")
      }
    }
    out.write_string("  </\{row_name}>\n")
  }
  out.write_string("</\{root_name}>\n")
  out.to_string()
}
