// The test support: a fixture and its sidecar read from under
// `.github/fixtures/orc/reference/`, the sidecar's cell and dtype spellings parsed
// back into scalars and dtypes, and one view of a file compared with the
// view its sidecar holds. the generator beside them wrote the sidecars; a
// cell is spelled `<kind> <payload>` — `Null`, `Bool true`,
// `Int <decimal>`, `Float <16 hex digits of the IEEE bits>`,
// `String <JSON string>`, `Date <days since 1970-01-01>`,
// `Timestamp <microseconds since 1970-01-01>`, `Decimal <plain text>`,
// `List [cell, ...]`, `Struct {"field": cell, ...}` — and a dtype
// `Int` / `Float` / `Bool` / `String` / `Date` / `Timestamp` / `Decimal` /
// `List(<dtype>)` / `Struct({"name": <dtype>, ...})`.

///|
/// A test's own refusal, in the error type the codec raises.
fn problem(what : String) -> @types.DataError {
  @types.DataError::ParseError(@types.ParseErrorDetail::Message(what))
}

///|
/// A fixture file, which must be there: a missing fixture fails the test
/// it belongs to rather than skipping it.
fn fixture(path : String) -> Bytes raise @types.DataError {
  @fs.read_file_to_bytes(path) catch {
    _ => raise problem("cannot read the fixture \{path}")
  }
}

///|
/// A fixture file parsed as JSON.
fn fixture_json(path : String) -> Json raise @types.DataError {
  let text = @fs.read_file_to_string(path) catch {
    _ => raise problem("cannot read the fixture \{path}")
  }
  @json.parse(text) catch {
    _ => raise problem("the fixture \{path} is not JSON")
  }
}

///|
/// Whether a JSON object carries a field.
fn has_field(value : Json, name : String) -> Bool {
  if value is Object(fields) {
    fields.contains(name)
  } else {
    false
  }
}

///|
/// A JSON value's field, which must be there.
fn field(value : Json, name : String) -> Json raise @types.DataError {
  if value is Object(fields) {
    match fields.get(name) {
      Some(found) => found
      None => raise problem("the JSON carries no field \"\{name}\"")
    }
  } else {
    raise problem("the JSON value is not an object")
  }
}

///|
/// A JSON value that must be an array.
fn jarray(value : Json) -> Array[Json] raise @types.DataError {
  if value is Array(items) {
    items
  } else {
    raise problem("the JSON value is not an array")
  }
}

///|
/// A JSON value that must be a string.
fn jstring(value : Json) -> String raise @types.DataError {
  if value is String(text) {
    text
  } else {
    raise problem("the JSON value is not a string")
  }
}

///|
/// A JSON value that must be a whole number.
fn jint(value : Json) -> Int32 raise @types.DataError {
  if value is Number(number, ..) {
    number.to_int()
  } else {
    raise problem("the JSON value is not a number")
  }
}

///|
/// A JSON value that must be a boolean.
fn jbool(value : Json) -> Bool raise @types.DataError {
  if value is True {
    true
  } else if value is False {
    false
  } else {
    raise problem("the JSON value is not a boolean")
  }
}

// ── the cell spelling ───────────────────────────────────────────────

///|
/// A reader of a cell's text: the text and how far into it the reading
/// has come, in code units.
priv struct CellText {
  text : String
  mut at : Int32
}

///|
/// The code unit at the reading point, or -1 past the end.
fn CellText::unit(self : CellText) -> Int32 {
  if self.at < self.text.length() {
    self.text.at(self.at).to_int()
  } else {
    -1
  }
}

///|
/// The code unit one ahead of the reading point, or -1 past the end.
fn CellText::next(self : CellText) -> Int32 {
  if self.at + 1 < self.text.length() {
    self.text.at(self.at + 1).to_int()
  } else {
    -1
  }
}

///|
/// Step over the blanks.
fn CellText::skip(self : CellText) -> Unit {
  while self.unit() == 32 {
    self.at = self.at + 1
  }
}

///|
/// The stretch of the text from `start` to the reading point.
fn CellText::part(self : CellText, start : Int32) -> String {
  self.text[start:self.at].to_owned()
}

///|
/// The word at the reading point: letters, to the first other code unit.
fn CellText::word(self : CellText) -> String raise @types.DataError {
  let start = self.at
  while (self.unit() >= 65 && self.unit() <= 90) ||
        (self.unit() >= 97 && self.unit() <= 122) {
    self.at = self.at + 1
  }
  if self.at == start {
    raise problem("\{self.text} spells no word at \{start}")
  }
  self.part(start)
}

///|
/// The code unit at the reading point, which must be `wanted`; it is
/// stepped over.
fn CellText::expect(
  self : CellText,
  wanted : Int32,
) -> Unit raise @types.DataError {
  if self.unit() != wanted {
    raise problem("\{self.text} spells no code unit \{wanted} at \{self.at}")
  }
  self.at = self.at + 1
}

///|
/// Four hexadecimal digits at the reading point, as a number.
fn CellText::hex4(self : CellText) -> Int32 raise @types.DataError {
  let mut value = 0
  for _ in 0..<4 {
    let c = self.unit()
    let digit = if c >= 48 && c <= 57 {
      c - 48
    } else if c >= 97 && c <= 102 {
      c - 87
    } else {
      raise problem("\{self.text} spells no four hex digits at \{self.at}")
    }
    value = value * 16 + digit
    self.at = self.at + 1
  }
  value
}

///|
/// The JSON string at the reading point, decoded: the one-character
/// escapes a JSON writer spells, and a `\u` escape — a surrogate pair
/// included — read back by the JSON reader itself.
fn CellText::quoted(self : CellText) -> String raise @types.DataError {
  self.expect(34)
  let out = StringBuilder()
  let mut run = self.at
  let mut closed = false
  while !closed {
    let c = self.unit()
    if c < 0 {
      raise problem("\{self.text} spells a string that does not end")
    }
    if c == 34 {
      out.write_string(self.part(run))
      self.at = self.at + 1
      closed = true
    } else if c == 92 {
      out.write_string(self.part(run))
      let escape_at = self.at
      self.at = self.at + 1
      let escape = self.unit()
      self.at = self.at + 1
      match escape {
        34 => out.write_char('"')
        47 => out.write_char('/')
        92 => out.write_char('\\')
        98 => out.write_char('\b')
        102 => out.write_char('\f')
        110 => out.write_char('\n')
        114 => out.write_char('\r')
        116 => out.write_char('\t')
        117 => {
          let code = self.hex4()
          if code >= 0xD800 &&
            code <= 0xDBFF &&
            self.unit() == 92 &&
            self.next() == 117 {
            self.at = self.at + 2
            let low = self.hex4()
            if low < 0xDC00 || low > 0xDFFF {
              raise problem("\{self.text} spells a lone high surrogate")
            }
          }
          let decoded = @json.parse("\"\{self.part(escape_at)}\"") catch {
            _ =>
              raise problem(
                "\{self.text} spells no JSON escape at \{escape_at}",
              )
          }
          if decoded is String(text) {
            out.write_string(text)
          }
        }
        _ => raise problem("\{self.text} spells no JSON escape at \{escape_at}")
      }
      run = self.at
    } else {
      self.at = self.at + 1
    }
  }
  out.to_string()
}

///|
/// The signed decimal integer at the reading point.
fn CellText::number(self : CellText) -> Int64 raise @types.DataError {
  let negative = self.unit() == 45
  if negative {
    self.at = self.at + 1
  }
  let start = self.at
  // The magnitude is taken in the unsigned domain, so the least 64-bit
  // integer is reached without a wrap.
  let mut value = 0UL
  while self.unit() >= 48 && self.unit() <= 57 {
    let digit = (self.unit() - 48).to_uint64()
    if value > 922337203685477580UL ||
      (value == 922337203685477580UL && digit > 8UL) {
      raise problem("\{self.text} spells an integer past 64 bits")
    }
    value = value * 10UL + digit
    self.at = self.at + 1
  }
  if self.at == start {
    raise problem("\{self.text} spells no integer at \{start}")
  }
  if negative {
    (0UL - value).reinterpret_as_int64()
  } else {
    value.reinterpret_as_int64()
  }
}

///|
/// The decimal text at the reading point: to the comma, bracket or brace
/// that ends a cell inside a list or a struct, or to the end.
fn CellText::decimal(self : CellText) -> String raise @types.DataError {
  let start = self.at
  while self.unit() >= 0 &&
        self.unit() != 44 &&
        self.unit() != 93 &&
        self.unit() != 125 {
    self.at = self.at + 1
  }
  let text = self.part(start).trim().to_owned()
  if text.is_empty() {
    raise problem("\{self.text} spells no decimal at \{start}")
  }
  text
}

///|
/// Sixteen hex digits as the bits of a double.
fn CellText::double(self : CellText) -> Double raise @types.DataError {
  let mut bits = 0UL
  for _ in 0..<4 {
    bits = (bits << 16) | self.hex4().to_uint64()
  }
  bits.reinterpret_as_double()
}

///|
/// The cell a sidecar spells, at the reading point of `text`.
fn parse_cell(text : CellText) -> @types.Scalar raise @types.DataError {
  text.skip()
  let kind = text.word()
  text.skip()
  match kind {
    "Null" => @types.Scalar::Null
    "List" => list_cell(text)
    "Struct" => struct_cell(text)
    "Bool" =>
      if text.word() == "true" {
        @types.Scalar::Bool(true)
      } else {
        @types.Scalar::Bool(false)
      }
    "Int" => @types.Scalar::Int(text.number())
    "Date" => @types.Scalar::Date(text.number())
    "Timestamp" => @types.Scalar::Timestamp(text.number())
    "Float" => @types.Scalar::Float(text.double())
    "String" => @types.Scalar::String(text.quoted())
    "Decimal" =>
      match @types.Dec128::parse_opt(text.decimal()) {
        Some(value) => @types.Scalar::Decimal(value)
        None => raise problem("\{text.text} spells no decimal")
      }
    _ => raise problem("\{text.text} spells no cell of kind \{kind}")
  }
}

///|
/// A list cell: `[`, its cells apart by commas, `]`; the empty list is
/// the two brackets.
fn list_cell(text : CellText) -> @types.Scalar raise @types.DataError {
  text.expect(91)
  let cells : Array[@types.Scalar] = []
  text.skip()
  let mut closed = false
  if text.unit() == 93 {
    text.at = text.at + 1
    closed = true
  }
  while !closed {
    text.skip()
    cells.push(parse_cell(text))
    text.skip()
    if text.unit() == 44 {
      text.at = text.at + 1
    } else if text.unit() == 93 {
      text.at = text.at + 1
      closed = true
    } else {
      raise problem("\{text.text} spells no list at \{text.at}")
    }
  }
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
/// A struct cell: `{`, its fields — a quoted name, a colon and a cell —
/// apart by commas, `}`; the empty struct is the two braces.
fn struct_cell(text : CellText) -> @types.Scalar raise @types.DataError {
  text.expect(123)
  let fields : Array[@types.FieldValue] = []
  text.skip()
  let mut closed = false
  if text.unit() == 125 {
    text.at = text.at + 1
    closed = true
  }
  while !closed {
    text.skip()
    let name = text.quoted()
    text.skip()
    text.expect(58)
    fields.push(@types.FieldValue::FieldValue(name, parse_cell(text)))
    text.skip()
    if text.unit() == 44 {
      text.at = text.at + 1
    } else if text.unit() == 125 {
      text.at = text.at + 1
      closed = true
    } else {
      raise problem("\{text.text} spells no struct at \{text.at}")
    }
  }
  @types.Scalar::Struct(@types.StructValue::StructValue(fields))
}

///|
/// The cell a sidecar spells, as a scalar.
fn cell(text : String) -> @types.Scalar raise @types.DataError {
  let reader = CellText::{ text, at: 0, }
  let value = parse_cell(reader)
  reader.skip()
  if reader.at != text.length() {
    raise problem("\{text} spells a cell and more")
  }
  value
}

///|
/// Sixteen lowercase hexadecimal digits.
fn hex64(bits : UInt64) -> String {
  let digits = "0123456789abcdef".code_units()
  let out = StringBuilder()
  for shift in [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0] {
    let digit = digits[(bits >> shift).to_int() & 15].to_int()
    out.write_char(digit.to_byte().to_char())
  }
  out.to_string()
}

///|
/// A scalar as the sidecar spells one — for a refusal's text.
fn spelled(value : @types.Scalar) -> String {
  match value {
    Null => "Null"
    Bool(b) => "Bool \{b}"
    Int(v) => "Int \{v}"
    Float(v) => "Float \{hex64(v.reinterpret_as_uint64())}"
    String(s) => "String \{s.escape()}"
    Date(d) => "Date \{d}"
    Timestamp(t) => "Timestamp \{t}"
    Decimal(d) => "Decimal \{d.to_string()}"
    Duration(_) | List(_) | Struct(_) => value.to_string()
  }
}

///|
/// Whether two cells agree, a list element by element and a struct field
/// by field — a `Float` by its bits, so that -0.0 and 0.0 stay apart and
/// a NaN equals its own bits; a `Decimal` by its value with the cohort's
/// trailing zeros dropped, since the sidecar spells the scale the file
/// declared and the codec the scale its stream carried; anything else by
/// equality.
fn cell_equal(got : @types.Scalar, want : @types.Scalar) -> Bool {
  match (got, want) {
    (Float(a), Float(b)) =>
      a.reinterpret_as_uint64() == b.reinterpret_as_uint64()
    (Decimal(a), Decimal(b)) => a.canonical() == b.canonical()
    (List(a), List(b)) =>
      if a.len() != b.len() {
        false
      } else {
        cells_equal(a.cells(), b.cells())
      }
    (Struct(a), Struct(b)) => {
      let mine = a.fields()
      let theirs = b.fields()
      if mine.length() != theirs.length() {
        false
      } else {
        let mut same = true
        for i in 0..<mine.length() {
          if mine[i].name() != theirs[i].name() ||
            !cell_equal(mine[i].value(), theirs[i].value()) {
            same = false
          }
        }
        same
      }
    }
    (a, b) => a == b
  }
}

///|
/// Whether two lists of cells agree, cell by cell.
fn cells_equal(got : Array[@types.Scalar], want : Array[@types.Scalar]) -> Bool {
  let mut same = true
  for i in 0..<got.length() {
    if !cell_equal(got[i], want[i]) {
      same = false
    }
  }
  same
}

// ── the dtype spelling ──────────────────────────────────────────────

///|
/// The dtype a sidecar spells, at the reading point of `text`.
fn parse_dtype(text : CellText) -> @types.DataType raise @types.DataError {
  text.skip()
  let kind = text.word()
  match kind {
    "Int" => @types.DataType::Int
    "Float" => @types.DataType::Float
    "Bool" => @types.DataType::Bool
    "String" => @types.DataType::String
    "Date" => @types.DataType::Date
    "Timestamp" => @types.DataType::Timestamp
    "Decimal" => @types.DataType::Decimal
    "List" => {
      text.expect(40)
      let inner = parse_dtype(text)
      text.skip()
      text.expect(41)
      @types.DataType::List(inner)
    }
    "Struct" => struct_dtype(text)
    _ => raise problem("\{text.text} spells no dtype of kind \{kind}")
  }
}

///|
/// A struct dtype: `(`, `{`, its fields — a quoted name, a colon and a
/// dtype — apart by commas, `}`, `)`.
fn struct_dtype(text : CellText) -> @types.DataType raise @types.DataError {
  text.expect(40)
  text.expect(123)
  let fields : Array[@types.Field] = []
  let mut closed = false
  while !closed {
    text.skip()
    if text.unit() == 125 {
      text.at = text.at + 1
      closed = true
    } else {
      let name = text.quoted()
      text.skip()
      text.expect(58)
      fields.push(@types.Field::Field(name, parse_dtype(text)))
      text.skip()
      if text.unit() == 44 {
        text.at = text.at + 1
      } else if text.unit() != 125 {
        raise problem("\{text.text} spells no struct dtype at \{text.at}")
      }
    }
  }
  text.expect(41)
  @types.DataType::Struct(@types.Schema::Schema(fields))
}

///|
/// The library dtype a sidecar names.
fn dtype_of(name : String) -> @types.DataType raise @types.DataError {
  let reader = CellText::{ text: name, at: 0, }
  let dtype = parse_dtype(reader)
  reader.skip()
  if reader.at != name.length() {
    raise problem("\{name} spells a dtype and more")
  }
  dtype
}

// ── a view of a file against its sidecar ───────────────────────────

///|
/// A cell as the sidecar's JSON spells it: a missing value is JSON's own
/// null, any other cell its spelled text.
fn spelled_cell(value : Json) -> String raise @types.DataError {
  if value is Null {
    "Null"
  } else {
    jstring(value)
  }
}

///|
/// The variant name of an error, as a sidecar spells a refusal.
fn variant(error : @types.DataError) -> String {
  match error {
    Unsupported(_) => "Unsupported"
    ParseError(Message(_)) => "ParseError"
    _ => "another variant"
  }
}

///|
/// One view of one reference file read through the codec and checked
/// against its sidecar: the row count, the column names in file order,
/// every column's dtype and every cell. Answers how many cells it
/// compared.
fn check_view(
  file : String,
  view : Json,
  bytes : Bytes,
) -> Int32 raise @types.DataError {
  let (columns, rows) = match field(view, "projection") {
    Null => read_orc_frame(bytes)
    named => read_orc_frame(bytes, projection=jarray(named).map(jstring))
  }
  let sidecar = fixture_json(".github/fixtures/orc/reference/\{file}.json")
  let wanted_rows = jint(field(sidecar, "rows"))
  if rows != wanted_rows {
    raise problem(
      "\{file}: the codec reports \{rows} rows, the sidecar \{wanted_rows}",
    )
  }
  let expected = jarray(field(view, "columns"))
  let names = columns.map(pair => pair.0)
  let wanted = expected.map(spec => jstring(field(spec, "name")))
  if names != wanted {
    raise problem(
      "\{file}: the codec reads the columns \{names.join(", ")}, the sidecar \{wanted.join(", ")}",
    )
  }
  let mut compared = 0
  for i, (name, series) in columns {
    let spec = expected[i]
    let dtype = dtype_of(jstring(field(spec, "dtype")))
    if series.dtype() != dtype {
      raise problem(
        "\{file}, column \"\{name}\": the codec reads \{series.dtype()}, the sidecar \{dtype}",
      )
    }
    let cells = series.to_scalars()
    let lines = jarray(field(spec, "cells")).map(spelled_cell)
    if cells.length() != lines.length() {
      raise problem(
        "\{file}, column \"\{name}\": \{cells.length()} cells against the sidecar's \{lines.length()}",
      )
    }
    for row in 0..<cells.length() {
      if !cell_equal(cells[row], cell(lines[row])) {
        raise problem(
          "\{file}, column \"\{name}\", row \{row + 1}: the codec read \{spelled(cells[row])}, the sidecar \{lines[row]}",
        )
      }
    }
    compared += cells.length()
  }
  compared
}

///|
/// A frame's cells against cells spelled as the sidecar spells them, an
/// array a column: answers how many cells were compared, and raises for a
/// cell that differs.
fn compare_cells(
  place : String,
  columns : Array[(String, @series.Series)],
  recorded : Array[Json],
) -> Int32 raise @types.DataError {
  if columns.length() != recorded.length() {
    raise problem(
      "\{place}: the codec reads \{columns.length()} columns, the reference reader \{recorded.length()}",
    )
  }
  let mut compared = 0
  for i, (name, series) in columns {
    let cells = series.to_scalars()
    let lines = jarray(recorded[i]).map(spelled_cell)
    if cells.length() != lines.length() {
      raise problem(
        "\{place}, column \"\{name}\": \{cells.length()} cells against the reference reader's \{lines.length()}",
      )
    }
    for row in 0..<cells.length() {
      if !cell_equal(cells[row], cell(lines[row])) {
        raise problem(
          "\{place}, column \"\{name}\", row \{row + 1}: the codec read \{spelled(cells[row])}, the reference reader \{lines[row]}",
        )
      }
    }
    compared += cells.length()
  }
  compared
}
