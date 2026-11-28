// Hand-built packages and the sidecar's spelling, shared by the blackbox
// tests. A test builds the bytes it asks the reader about, so a byte a
// message names is found in those bytes and not taken on trust.

///|
const OFFICE_NS : String = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"

///|
const TABLE_NS : String = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

///|
const TEXT_NS : String = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"

///|
const MIMETYPE : String = "application/vnd.oasis.opendocument.spreadsheet"

///|
/// A fixture file's bytes.
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
/// A test's own failure.
fn problem(what : String) -> @types.DataError {
  @types.DataError::InvalidOperation(what)
}

///|
/// content.xml around a body: the document-content root with the three
/// namespaces under their conventional prefixes, and the two a written
/// package declares beside them for the links and drawings a table holds.
fn document(body : String) -> String {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"" +
  OFFICE_NS +
  "\" xmlns:table=\"" +
  TABLE_NS +
  "\" xmlns:text=\"" +
  TEXT_NS +
  "\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" office:version=\"1.2\">" +
  "<office:automatic-styles/><office:body><office:spreadsheet>" +
  body +
  "</office:spreadsheet></office:body></office:document-content>"
}

///|

///|
/// A ZIP holding `entries` in order, the mimetype entry first and stored.
fn zip(entries : Array[(String, Bytes)], mimetype : Bytes) -> Bytes {
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", mimetype, compression=Store)
  for entry in entries {
    archive.add(entry.0, entry.1)
  }
  @zip.write(archive) catch {
    _ => b""
  }
}

///|
/// A spreadsheet package whose content.xml is `content`.
fn spreadsheet(content : String) -> Bytes {
  zip([("content.xml", @utf8.encode(content))], @utf8.encode(MIMETYPE))
}

///|
/// A spreadsheet package around a body.
fn body_package(body : String) -> Bytes {
  spreadsheet(document(body))
}

///|
/// The refusal reading the first sheet of `bytes` raises; the test fails
/// when the package reads back.
fn refused(bytes : Bytes) -> @types.DataError raise Failure {
  let outcome : Result[OdsGrid, @types.DataError] = Ok(sheet_grid(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Err(error) => error
    Ok(grid) =>
      fail(
        "the package read back as \{grid.cells().map(cell_text).join(" | ")}",
      )
  }
}

///|
/// The refusal reading the sheets of `bytes` raises; the test fails when
/// they read back.
fn refused_sheets(bytes : Bytes) -> @types.DataError raise Failure {
  let outcome : Result[Array[String], @types.DataError] = Ok(sheet_names(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Err(error) => error
    Ok(names) => fail("the package's sheets read back as \{names.join(", ")}")
  }
}

///|
/// A refusal's variant.
fn variant(error : @types.DataError) -> String {
  match error {
    ColumnNotFound(_) => "ColumnNotFound"
    DuplicateColumn(_) => "DuplicateColumn"
    TypeMismatch(_) => "TypeMismatch"
    LengthMismatch(_, _) => "LengthMismatch"
    IndexOutOfBounds(_) => "IndexOutOfBounds"
    ParseError(_) => "ParseError"
    InvalidOperation(_) => "InvalidOperation"
    IoError(_) => "IoError"
    Unsupported(_) => "Unsupported"
    NullInNonNullable(_) => "NullInNonNullable"
  }
}

///|
/// A refusal as the library renders it for a caller: the variant's name
/// in the library's wording, then what the reader said.
fn rendered(wanted : String, message : String) -> String {
  match wanted {
    "ParseError" => "Parse error: \{message}"
    "Unsupported" => "Unsupported: \{message}"
    "InvalidOperation" => "Invalid operation: \{message}"
    other => "<no such variant: \{other}>"
  }
}

///|
/// The first sheet's cells, each spelled — or the refusal.
fn read(bytes : Bytes) -> Array[String] {
  let outcome : Result[OdsGrid, @types.DataError] = Ok(sheet_grid(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(grid) => grid.cells().map(cell_text)
    Err(error) => ["<refused: \{error.message()}>"]
  }
}

///|
/// A double's bits as 16 lowercase hexadecimal digits, as the sidecars
/// spell one.
fn hex64(bits : UInt64) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let out = StringBuilder()
  for shift = 60; shift >= 0; shift = shift - 4 {
    out.write_char(digits[((bits >> shift.to_int()) & 0xFUL).to_int()])
  }
  out.to_string()
}

///|
/// A cell's value as the sidecar spells one: a number by the hexadecimal
/// digits of its bits, or `NaN`; a text by itself; a boolean by `true` or
/// `false`; a day, an instant or a time by its decimal count.
fn value_text(value : OdsValue) -> String {
  match value {
    Text(text) => "Text \{text}"
    Number(number) =>
      if number.is_nan() {
        "Number NaN"
      } else {
        "Number \{hex64(number.reinterpret_as_uint64())}"
      }
    Boolean(boolean) => "Boolean \{boolean}"
    Day(days) => "Day \{days}"
    Instant(micros) => "Instant \{micros}"
    Time(micros) => "Time \{micros}"
  }
}

///|
/// A cell as the sidecar spells one: its position, then its value.
fn cell_text(cell : OdsCell) -> String {
  "\{cell.row()},\{cell.col()} \{value_text(cell.value())}"
}

///|
/// A sidecar cell — `[row, column, kind, payload]` — as a test compares it.
fn sidecar_cell(cell : Json) -> String raise @types.DataError {
  let parts = jarray(cell)
  let row = jint(parts[0])
  let column = jint(parts[1])
  let kind = jstring(parts[2])
  let payload = jstring(parts[3])
  "\{row},\{column} \{kind} \{payload}"
}

///|
/// Where a pattern is first spelled in a byte string; -1 when nowhere.
fn index_of(bytes : Bytes, pattern : Bytes) -> Int32 {
  let mut at = 0
  let last = bytes.length() - pattern.length()
  while at <= last {
    let mut same = true
    for i in 0..<pattern.length() {
      if bytes[at + i] != pattern[i] {
        same = false
        break
      }
    }
    if same {
      return at
    }
    at += 1
  }
  -1
}
