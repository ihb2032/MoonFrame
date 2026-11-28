// The test support: a fixture and its sidecar read from under
// `.github/fixtures/xls/reference/`, the sidecar's cell spellings parsed back into
// what a codec's cell is held to, and the error vocabulary spelled the way
// a sidecar spells a refusal. The generator beside them wrote the sidecars;
// a cell is spelled `["T", row, col, text]` (a fifth element, "blank",
// where the codec answers no cell), `["B", row, col, boolean]`,
// `["N", row, col, 16 hex digits of the IEEE bits, format index, format
// code, cell type]` and `["E", row, col, text]`.

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
/// One cell as a sidecar spells it, and what a codec's cell is held to.
struct Want {
  kind : String
  row : Int32
  col : Int32
  /// A text, an error's text, or a number's bits as sixteen hex digits.
  text : String
  /// Whether the codec answers no cell there.
  blank : Bool
  /// A number's bits as the sidecar spells them.
  bits : UInt64
  /// A number's format index.
  key : Int32
  /// A number's format code, where the index is a custom one's.
  code : String
  /// A number's cell type as the reference reader names it: 0 when the
  /// sidecar spells none.
  ctype : Int32
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
/// The cell a sidecar's array spells.
fn want_of(cell : Json) -> Want raise @types.DataError {
  let parts = jarray(cell)
  let kind = jstring(parts[0])
  // A boolean's text is its JSON spelling.
  let text = if kind == "B" {
    if jbool(parts[3]) {
      "true"
    } else {
      "false"
    }
  } else {
    jstring(parts[3])
  }
  let mut key = 0
  let mut code = ""
  let mut ctype = 0
  if kind == "N" {
    key = jint(parts[4])
    if parts[5] is String(named) {
      code = named
    } else if key >= 164 {
      raise problem("a number under a custom format spells no code")
    }
    if parts.length() > 6 {
      ctype = jint(parts[6])
    }
  }
  let blank = parts.length() > 4 && parts[4] is String(mark) && mark == "blank"
  let bits = if kind == "N" { hexadecimal(text) } else { 0UL }
  Want::{
    kind,
    row: jint(parts[1]),
    col: jint(parts[2]),
    text,
    blank,
    bits,
    key,
    code,
    ctype,
  }
}

///|
/// A number format as a failure's text spells it.
fn spelled_format(format : XlsFormat) -> String {
  match format {
    Builtin(id) => "Builtin(\{id})"
    Custom(code) => "Custom(\"\{code.escape()}\")"
  }
}

///|
/// A value as a failure's text spells it: a number by its bits.
fn spelled(value : XlsValue) -> String {
  match value {
    Text(text) => "Text(\"\{text.escape()}\")"
    Boolean(b) => "Boolean(\{b})"
    Number(v, format) =>
      "Number(\{hex64(v.reinterpret_as_uint64())}, \{spelled_format(format)})"
    Error(text) => "Error(\"\{text.escape()}\")"
  }
}

///|
/// Whether a built-in number format id is one of the date and time ids
/// the library reads a number by — the format ids every locale shares.
fn date_builtin(id : Int32) -> Bool {
  (id >= 14 && id <= 22) || (id >= 45 && id <= 47)
}

///|
/// Whether the codec's value and the sidecar's cell spell one cell: a
/// number by its bits and by its format — a built-in one by its id, a
/// custom one by its code — and every other kind by its text or its
/// boolean.
fn agreed(value : XlsValue, want : Want) -> Bool {
  match want.kind {
    "T" => value is Text(text) && text == want.text
    "B" => value is Boolean(b) && b == (want.text == "true")
    "E" => value is Error(text) && text == want.text
    "N" =>
      if value is Number(v, format) {
        if v.reinterpret_as_uint64() != want.bits {
          false
        } else if want.key < 164 {
          format is Builtin(id) && id == want.key
        } else {
          format is Custom(code) && code == want.code
        }
      } else {
        false
      }
    _ => false
  }
}

// ── the refusals ────────────────────────────────────────────────────

///|
/// The variant name of an error, as a sidecar spells a refusal.
fn variant(error : @types.DataError) -> String {
  match error {
    Unsupported(_) => "Unsupported"
    ParseError(Message(_)) => "ParseError"
    InvalidOperation(_) => "InvalidOperation"
    _ => "another variant"
  }
}

///|
/// The text an error carries after its variant: what starts with `xls: `.
fn detail(error : @types.DataError) -> String {
  match error {
    Unsupported(text) => text
    InvalidOperation(text) => text
    ParseError(Message(text)) => text
    _ => ""
  }
}

///|
/// How the library renders an error for a reader: the variant's words,
/// then the codec's text.
fn rendered(error : @types.DataError) -> String {
  match error {
    Unsupported(text) => "Unsupported: \{text}"
    InvalidOperation(text) => "Invalid operation: \{text}"
    ParseError(Message(text)) => "Parse error: \{text}"
    _ => ""
  }
}

///|
/// Hold the codec's refusal of `file` to its sidecar's: the variant, the
/// text to the letter, the `xls: ` every message of this codec starts
/// with, and the library's own rendering. Answers what differs, or
/// nothing when the refusal is the sidecar's.
fn refusal_difference(
  file : String,
  error : @types.DataError,
  sidecar : Json,
) -> String raise @types.DataError {
  let wanted = jstring(field(sidecar, "refusal"))
  if variant(error) != wanted {
    return "\{file}: the codec refuses with \{error.message()}; its sidecar names the variant \{wanted}"
  }
  let expected = jstring(field(sidecar, "message"))
  let got = detail(error)
  if got != expected {
    return "\{file}: the codec refuses with \"\{got}\"; its sidecar says \"\{expected}\""
  }
  if !got.has_prefix("xls: ") {
    return "\{file}: the refusal does not start with \"xls: \": \{got}"
  }
  if error.message() != rendered(error) {
    return "\{file}: the library renders the refusal otherwise: \{error.message()}"
  }
  ""
}
