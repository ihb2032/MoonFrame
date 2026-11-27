// Blackbox tests over the reference files. Each dataset under
// `.github/fixtures/stata/reference/` was written by a reference implementation, or —
// where its name says `synthetic` — derived from one of those files; the
// JSON beside it holds the cells the reference reader itself got from it,
// and the generator beside them wrote both. A cell is spelled
// `<kind> <payload>`: `Null`, `Bool 1`, `Int 12`, `Float <16 hex digits of
// the IEEE bits>`, `String <text>`, `Date <days since 1970-01-01>`,
// `Timestamp <microseconds since 1970-01-01>`.

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
/// A decimal integer as the sidecar spells one.
fn decimal(text : String) -> Int64 raise @types.DataError {
  let units = text.code_units()
  let mut i = 0
  let negative = units.length() > 0 && units[0].to_int() == 45
  if negative {
    i = 1
  }
  if i >= units.length() {
    raise problem("\{text} spells no integer")
  }
  let mut value = 0L
  while i < units.length() {
    let digit = units[i].to_int() - 48
    if digit < 0 || digit > 9 {
      raise problem("\{text} spells no integer")
    }
    value = value * 10L + digit.to_int64()
    i += 1
  }
  if negative {
    -value
  } else {
    value
  }
}

///|
/// A hexadecimal integer as the sidecar spells one.
fn hexadecimal(text : String) -> UInt64 raise @types.DataError {
  let units = text.code_units()
  if units.length() == 0 {
    raise problem("the hex digits are empty")
  }
  let mut value = 0UL
  for i in 0..<units.length() {
    let c = units[i].to_int()
    let digit = if c >= 48 && c <= 57 {
      c - 48
    } else if c >= 97 && c <= 102 {
      c - 87
    } else if c >= 65 && c <= 70 {
      c - 55
    } else {
      raise problem("\{text} spells no hex digits")
    }
    value = (value << 4) | digit.to_uint64()
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
/// A scalar as the sidecar spells one.
fn spelled(value : @types.Scalar) -> String {
  match value {
    Null => "Null"
    Bool(b) => "Bool \{if b { 1 } else { 0 }}"
    Int(v) => "Int \{v}"
    Float(v) => "Float \{hex64(v.reinterpret_as_uint64())}"
    String(s) => "String \{s}"
    Date(d) => "Date \{d}"
    Timestamp(t) => "Timestamp \{t}"
    Decimal(_) | Duration(_) | List(_) | Struct(_) => value.to_string()
  }
}

///|
/// The cell a sidecar line spells, as a scalar.
fn cell(text : String) -> @types.Scalar raise @types.DataError {
  if text == "Null" {
    return @types.Scalar::Null
  }
  let (kind_v, payload_v) = match text.split_once(" ") {
    Some(pair) => pair
    None => raise problem("\{text} spells no cell")
  }
  let kind = kind_v.to_owned()
  let payload = payload_v.to_owned()
  match kind {
    "Int" => @types.Scalar::Int(decimal(payload))
    "Float" =>
      @types.Scalar::Float(hexadecimal(payload).reinterpret_as_double())
    "String" => @types.Scalar::String(payload)
    "Date" => @types.Scalar::Date(decimal(payload))
    "Timestamp" => @types.Scalar::Timestamp(decimal(payload))
    "Bool" => @types.Scalar::Bool(payload == "1")
    _ => raise problem("\{text} spells no cell")
  }
}

///|
/// Whether two cells agree — a `Float` by its bits, so that -0.0 and 0.0
/// stay apart; anything else by equality.
fn cell_equal(got : @types.Scalar, want : @types.Scalar) -> Bool {
  match (got, want) {
    (Float(a), Float(b)) =>
      a.reinterpret_as_uint64() == b.reinterpret_as_uint64()
    (a, b) => a == b
  }
}

///|
/// The library dtype a sidecar names.
fn dtype_of(name : String) -> @types.DataType raise @types.DataError {
  match name {
    "Int" => @types.DataType::Int
    "Float" => @types.DataType::Float
    "String" => @types.DataType::String
    "Date" => @types.DataType::Date
    "Timestamp" => @types.DataType::Timestamp
    _ => raise problem("\{name} names no dtype a sidecar spells")
  }
}

///|
/// One reference file read through the codec, checked against its
/// sidecar: the observation count, the column names in file order, every
/// column's dtype, and every cell. Answers how many cells it compared.
fn check_reference(file : String) -> Int32 raise @types.DataError {
  let bytes = fixture(".github/fixtures/stata/reference/\{file}")
  let stem = file[:file.length() - 4].to_owned()
  let sidecar = fixture_json(".github/fixtures/stata/reference/\{stem}.json")
  let (columns, height) = read_stata_frame(bytes)
  let nobs = jint(field(sidecar, "nobs"))
  if height != nobs {
    raise problem(
      "\{file}: the codec reports \{height} observations, the sidecar \{nobs}",
    )
  }
  let expected = jarray(field(sidecar, "columns"))
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
    let lines = jarray(field(spec, "cells")).map(jstring)
    if cells.length() != lines.length() {
      raise problem(
        "\{file}, column \"\{name}\": \{cells.length()} cells against the sidecar's \{lines.length()}",
      )
    }
    for row in 0..<cells.length() {
      if !cell_equal(cells[row], cell(lines[row])) {
        raise problem(
          "\{file}, column \"\{name}\", row \{row + 1}: the codec read \{spelled(cells[row])}, the reference reader \{lines[row]}",
        )
      }
    }
    compared += cells.length()
  }
  compared
}

///|
test "every reference file reads, cell for cell, as the reference reader read it" {
  let index = jarray(
    fixture_json(".github/fixtures/stata/reference/index.json"),
  )
  // The corpus is the generator's, and all of it is read here: a
  // directory that lost its files cannot pass as an empty run.
  if index.length() < 46 {
    fail(
      "the reference corpus holds \{index.length()} files, fewer than the generator wrote",
    )
  }
  let mut files = 0
  let mut compared = 0
  for entry in index {
    compared += check_reference(jstring(field(entry, "file")))
    files += 1
  }
  // A corpus of this size is thousands of cells: a check that compared
  // nothing would have to be a smaller corpus.
  if compared < 2000 {
    fail("only \{compared} cells were compared over \{files} files")
  }
  println("reference files: \{files}; cells compared: \{compared}")
}
