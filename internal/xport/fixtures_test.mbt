// Blackbox tests over the reference files. Each transport file under
// `.github/fixtures/xport/reference/` was written by the reference writer (pyreadstat's
// `write_xport` at file format version 5) or — where its name says `syn` —
// by the generator beside them, which lays the records out itself. The JSON
// beside it holds the cells that generator reads from the bytes under the
// codec's rules, and records per column whether each reference reader
// agreed. A cell is spelled `<kind> <payload>`: `Null`, `Bool 1`,
// `Float <16 hex digits of the IEEE bits>`, `String <text>`, `Date <days
// since 1970-01-01>`, `Timestamp <microseconds since 1970-01-01>`.

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
/// A scalar as a sidecar spells one.
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
  if got is @types.Scalar::Float(a) && want is @types.Scalar::Float(b) {
    a.reinterpret_as_uint64() == b.reinterpret_as_uint64()
  } else {
    got == want
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
/// What a cell the codec read meets in pandas' raw column: the same
/// value, or pandas' reading of a cell of zero bytes, which is 2^-260
/// rather than zero.
enum Verdict {
  Same
  ZeroCell
  Differs
}

///|
/// The bits pandas answers for a cell of eight zero bytes.
const PANDAS_ZERO : UInt64 = 0x2FB0000000000000UL

///|
/// The bits of the NaN pandas answers for a missing cell.
const PANDAS_NAN : UInt64 = 0x7FF8000000000000UL

///|
/// Days from 1960-01-01 to 1970-01-01.
const EPOCH_DAYS : Int64 = 3653L

///|
/// Whether pandas' double `theirs` is the raw count `count` the codec's
/// cell came from. pandas converts nothing, so it answers the number the
/// file holds; a count of zero it answers as 2^-260.
fn count_verdict(count : Int64, theirs : Double) -> Verdict {
  if count == 0L {
    if theirs.reinterpret_as_uint64() == PANDAS_ZERO {
      return ZeroCell
    }
    return if theirs == 0.0 { Same } else { Differs }
  }
  if theirs == theirs.floor() && theirs.to_int64() == count {
    Same
  } else {
    Differs
  }
}

///|
/// What the codec's cell `mine` meets in the cell `theirs` pandas read at
/// the same row. A `Timestamp` cell counts microseconds from
/// `from_micros`: pandas' raw seconds of a datetime column count from
/// 1960-01-01, of a time column from midnight.
fn pandas_verdict(
  mine : @types.Scalar,
  theirs : String,
  from_micros : Int64,
) -> Verdict raise @types.DataError {
  let raw = cell(theirs)
  if mine is Null && raw is Float(n) {
    return if n.reinterpret_as_uint64() == PANDAS_NAN { Same } else { Differs }
  }
  if mine is String(a) && raw is String(b) {
    return if a == b { Same } else { Differs }
  }
  if raw is Float(b) && mine is Float(a) {
    if a.reinterpret_as_uint64() == b.reinterpret_as_uint64() {
      return Same
    }
    if a.reinterpret_as_uint64() == 0UL &&
      b.reinterpret_as_uint64() == PANDAS_ZERO {
      return ZeroCell
    }
    return Differs
  }
  if raw is Float(b) && mine is Date(d) {
    return count_verdict(d + EPOCH_DAYS, b)
  }
  if raw is Float(b) && mine is Timestamp(t) {
    return seconds_verdict(t + from_micros, b)
  }
  Differs
}

///|
/// Whether pandas' double `theirs` is the seconds that spell `micros`
/// microseconds: a count of zero pandas answers as 2^-260, and any other
/// is whole once scaled by 10^6.
fn seconds_verdict(micros : Int64, theirs : Double) -> Verdict {
  if micros == 0L {
    if theirs.reinterpret_as_uint64() == PANDAS_ZERO {
      return ZeroCell
    }
    return if theirs == 0.0 { Same } else { Differs }
  }
  let scaled = theirs * 1000000.0
  if scaled == scaled.floor() && scaled.to_int64() == micros {
    Same
  } else {
    Differs
  }
}

///|
/// What one pass over the reference files counted.
struct Tally {
  mut files : Int32
  mut cells : Int32
  mut pandas_cells : Int32
  mut zero_cells : Int32
  mut differs : Int32
  mut refused : Int32
}

///|
/// One reference file read through the codec, checked against its
/// sidecar: the observation count, the column names in file order, every
/// column's dtype, every cell, and — as far as pandas' rows reach — the
/// cell pandas itself read for that row.
fn check_reference(file : String, tally : Tally) -> Unit raise @types.DataError {
  let bytes = fixture(".github/fixtures/xport/reference/\{file}")
  let stem = file[:file.length() - 4].to_owned()
  let sidecar = fixture_json(".github/fixtures/xport/reference/\{stem}.json")
  let (columns, height) = read_xport_frame(bytes)
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
          "\{file}, column \"\{name}\", row \{row + 1}: the codec read \{spelled(cells[row])}, the sidecar \{lines[row]}",
        )
      }
    }
    tally.cells += cells.length()
    // pandas' raw cells, for the rows it read: it may read fewer than the
    // file holds, or more, where its observation count is off. The
    // sidecar says, per column, whether pandas agreed with the generator;
    // where it did, every cell must agree here too, and where it did not,
    // some cell must differ in fact.
    let pandas = field(spec, "pandas")
    let pandas_cells = jarray(field(pandas, "cells")).map(jstring)
    let from_micros = jlong(field(spec, "pandas_from"))
    let agrees = jbool(field(pandas, "agrees"))
    let mut differences = 0
    for row in 0..<pandas_cells.length() {
      if row >= cells.length() {
        break
      }
      match pandas_verdict(cells[row], pandas_cells[row], from_micros) {
        Same => ()
        ZeroCell => tally.zero_cells += 1
        Differs => differences += 1
      }
      tally.pandas_cells += 1
    }
    if agrees && differences > 0 {
      raise problem(
        "\{file}, column \"\{name}\": \{differences} cells differ from pandas', and the sidecar says none do",
      )
    }
    if !agrees {
      if differences == 0 && pandas_cells.length() == cells.length() {
        raise problem(
          "\{file}, column \"\{name}\": the sidecar says pandas disagrees, and every cell agrees",
        )
      }
      tally.differs += 1
    }
  }
  tally.files += 1
}

///|
/// One reference file the codec refuses by name: the sidecar says which
/// variant it raises and what the message says.
fn check_refusal(file : String, tally : Tally) -> Unit raise {
  let bytes = fixture(".github/fixtures/xport/reference/\{file}")
  let stem = file[:file.length() - 4].to_owned()
  let refusal = field(
    fixture_json(".github/fixtures/xport/reference/\{stem}.json"),
    "refusal",
  )
  let variant = jstring(field(refusal, "variant"))
  let contains = jstring(field(refusal, "contains"))
  let outcome : Result[_, @types.DataError] = Ok(read_xport_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("\{file} read back as a table")
    Err(e) => {
      let message = e.message()
      if variant == "Unsupported" {
        assert_true(e is @types.DataError::Unsupported(_))
      } else {
        assert_true(e is @types.DataError::ParseError(_))
      }
      assert_true(
        message.contains(contains),
        msg="\{file}: \{message} does not say \{contains}",
      )
    }
  }
  tally.refused += 1
}

///|
test "every reference file reads, cell for cell, as its sidecar spells, and pandas' raw cells agree" {
  let index = jarray(
    fixture_json(".github/fixtures/xport/reference/index.json"),
  )
  // The corpus is the generator's, and all of it is read here: a
  // directory that lost its files cannot pass as an empty run.
  if index.length() < 29 {
    fail(
      "the reference corpus holds \{index.length()} files, fewer than the generator wrote",
    )
  }
  let tally = Tally::{
    files: 0,
    cells: 0,
    pandas_cells: 0,
    zero_cells: 0,
    differs: 0,
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
  // A corpus of this size is hundreds of cells: a check that compared
  // nothing would have to be a smaller corpus.
  if tally.cells < 400 {
    fail("only \{tally.cells} cells were compared over \{tally.files} files")
  }
  if tally.pandas_cells < 300 {
    fail("only \{tally.pandas_cells} cells were cross-checked against pandas")
  }
  println(
    "reference files: \{tally.files} read, \{tally.refused} refused by name; cells compared: \{tally.cells}; pandas cells cross-checked: \{tally.pandas_cells}, zero cells pandas reads as 2^-260: \{tally.zero_cells}, columns pandas disagrees on (recorded in the sidecar): \{tally.differs}",
  )
}
