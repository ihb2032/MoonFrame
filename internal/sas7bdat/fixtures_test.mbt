// Blackbox tests over the reference files. Each sas7bdat file under
// `.github/fixtures/sas7bdat/reference/` was written by the reference writer (pyreadstat's
// `write_sas7bdat`), comes from the pandas test corpus (real SAS data
// sets, as they are), or — where its name says `syn` — was laid out from
// scratch by the generator (the generator beside the reference files).
// The JSON beside it holds the cells a reference reader returned, spelled
// under the codec's rules, and records per column whether each reference
// reader's own result agreed. A cell is spelled `<kind> <payload>`:
// `Null`, `Float <16 hex digits of the IEEE bits>`, `String <text>`,
// `Date <days since 1970-01-01>`, `Timestamp <microseconds since
// 1970-01-01>`.

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
fn jlong(value : Json) -> Int64 raise @types.DataError {
  if value is Number(number, ..) {
    number.to_int64()
  } else {
    raise problem("the JSON value is not a number")
  }
}

///|
/// A JSON value that must be a Boolean.
fn jbool(value : Json) -> Bool raise @types.DataError {
  if value is True {
    true
  } else if value is False {
    false
  } else {
    raise problem("the JSON value is not a Boolean")
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
/// The cell a sidecar spells, as a scalar.
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
    "Float" =>
      @types.Scalar::Float(hexadecimal(payload).reinterpret_as_double())
    "String" => @types.Scalar::String(payload)
    "Date" => @types.Scalar::Date(decimal(payload))
    "Timestamp" => @types.Scalar::Timestamp(decimal(payload))
    _ => raise problem("\{text} spells no cell the codec reads")
  }
}

///|
/// Whether two cells agree — a `Float` by its bits, so that -0.0 and 0.0
/// stay apart; anything else by equality.
fn cell_equal(got : @types.Scalar, want : @types.Scalar) -> Bool {
  if got is @types.Scalar::Float(a) && want is @types.Scalar::Float(b) {
    a.reinterpret_as_uint64() == b.reinterpret_as_uint64()
  } else {
    got == want
  }
}

///|
/// A scalar as a sidecar spells one.
fn spelled(value : @types.Scalar) -> String {
  match value {
    Null => "Null"
    Float(v) => "Float \{hex64(v.reinterpret_as_uint64())}"
    String(s) => "String \{s}"
    Date(d) => "Date \{d}"
    Timestamp(t) => "Timestamp \{t}"
    Int(_) | Bool(_) | Decimal(_) | Duration(_) | List(_) | Struct(_) =>
      "another dtype"
  }
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
/// The library dtype a sidecar names.
fn dtype_of(name : String) -> @types.DataType raise @types.DataError {
  match name {
    "Float" => @types.DataType::Float
    "String" => @types.DataType::String
    "Date" => @types.DataType::Date
    "Timestamp" => @types.DataType::Timestamp
    _ => raise problem("\{name} names no dtype a sidecar spells")
  }
}

///|
/// What one pass over the reference files counted.
struct Tally {
  mut files : Int32
  mut cells : Int32
  columns : Array[Int32]
  mut both_agree : Int32
  mut refused : Int32
}

///|
/// One reference file read through the codec, checked against its
/// sidecar: the observation count, the column names in file order, every
/// column's dtype, and every cell.
fn check_reference(file : String, tally : Tally) -> Unit raise @types.DataError {
  let bytes = fixture(".github/fixtures/sas7bdat/reference/\{file}")
  let stem = file[:file.length() - 9].to_owned()
  let sidecar = fixture_json(".github/fixtures/sas7bdat/reference/\{stem}.json")
  let (columns, height) = read_sas7bdat_frame(bytes) catch {
    e => raise problem("\{file}: \{e.message()}")
  }
  let rows = jlong(field(sidecar, "rows"))
  if height.to_int64() != rows {
    raise problem(
      "\{file}: the codec reports \{height} observations, the sidecar \{rows}",
    )
  }
  let expected = jarray(field(sidecar, "columns"))
  if columns.length() != expected.length() {
    raise problem(
      "\{file}: the codec reads \{columns.length()} columns, the sidecar \{expected.length()}",
    )
  }
  for i, (name, series) in columns {
    let spec = expected[i]
    let wanted = jstring(field(spec, "name"))
    if name != wanted {
      raise problem(
        "\{file}: the codec reads column \{i + 1} as \"\{name}\", the sidecar \"\{wanted}\"",
      )
    }
    let dtype = jstring(field(spec, "dtype"))
    if series.dtype() != dtype_of(dtype) {
      raise problem(
        "\{file}, column \"\{name}\" (format \{jstring(field(spec, "format"))}): the codec reads \{series.dtype()}, the sidecar \{dtype}",
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
          "\{file}, column \"\{name}\", row \{row + 1}: the codec read \{spelled(cells[row])}, the sidecar \{lines[row]}",
        )
      }
    }
    tally.cells += cells.length()
    if dtype == "Float" {
      tally.columns[0] += 1
    } else if dtype == "String" {
      tally.columns[1] += 1
    } else if dtype == "Date" {
      tally.columns[2] += 1
    } else {
      tally.columns[3] += 1
    }
    if jstring(field(spec, "pandas")) == "agrees" &&
      jstring(field(spec, "pyreadstat")) == "agrees" {
      tally.both_agree += 1
    }
  }
  tally.files += 1
}

///|
/// One reference file the codec refuses by name: the sidecar says which
/// variant it raises and what the message says.
fn check_refusal(file : String, tally : Tally) -> Unit raise {
  let bytes = fixture(".github/fixtures/sas7bdat/reference/\{file}")
  let stem = file[:file.length() - 9].to_owned()
  let refusal = field(
    fixture_json(".github/fixtures/sas7bdat/reference/\{stem}.json"),
    "refusal",
  )
  let variant = jstring(field(refusal, "variant"))
  let contains = jstring(field(refusal, "contains"))
  let outcome : Result[_, @types.DataError] = Ok(read_sas7bdat_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok((columns, _)) =>
      fail("\{file} read back as a table of \{columns.length()} columns")
    Err(e) => {
      let message = e.message()
      let variant_ok = if variant == "Unsupported" {
        e is @types.DataError::Unsupported(_)
      } else {
        e is @types.DataError::ParseError(_)
      }
      if !variant_ok || !message.contains(contains) {
        fail(
          "\{file}: the codec raises the \{variant} variant: \{variant_ok}; its message \{message} does not say \{contains}",
        )
      }
    }
  }
  tally.refused += 1
}

///|
test "every reference file reads, cell for cell, as its sidecar spells, or is refused by name" {
  let index = jarray(
    fixture_json(".github/fixtures/sas7bdat/reference/index.json"),
  )
  // The corpus is the generator's, and all of it is read here: a
  // directory that lost its files cannot pass as an empty run.
  if index.length() < 39 {
    fail(
      "the reference corpus holds \{index.length()} files, fewer than the generator wrote",
    )
  }
  let tally = Tally::{
    files: 0,
    cells: 0,
    columns: [0, 0, 0, 0],
    both_agree: 0,
    refused: 0,
  }
  for entry in index {
    let file = jstring(field(entry, "file"))
    if jbool(field(entry, "readable")) {
      check_reference(file, tally)
    } else {
      check_refusal(file, tally)
    }
  }
  // A corpus of this size is thousands of cells: a check that compared
  // nothing would have to be a smaller corpus.
  if tally.cells < 5000 {
    fail("only \{tally.cells} cells were compared over \{tally.files} files")
  }
  if tally.files < 30 || tally.refused < 7 {
    fail("\{tally.files} files read and \{tally.refused} refused")
  }
  println(
    "reference files: \{tally.files} read, \{tally.refused} refused by name; cells compared: \{tally.cells}; columns: \{tally.columns[0]} Float, \{tally.columns[1]} String, \{tally.columns[2]} Date, \{tally.columns[3]} Timestamp; columns both reference readers agree with the sidecar on: \{tally.both_agree}",
  )
}
