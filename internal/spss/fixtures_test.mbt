// Blackbox tests over the reference files. Each system file under
// `.github/fixtures/spss/reference/` was written by the reference writer or derived
// from one it wrote; with `make --with-pspp`, PSPP's own example and test
// files stand beside them. The JSON beside each holds the cells the
// reference reader itself got from it where that reader opens it, and
// the generator beside them wrote both. A cell is spelled
// `<kind> <payload>`: `Null`, `Float <16 hex digits of the IEEE bits>`,
// `String <text>`, `Date <days since 1970-01-01>`,
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
    Float(v) => "Float \{hex64(v.reinterpret_as_uint64())}"
    String(s) => "String \{s}"
    Date(d) => "Date \{d}"
    Timestamp(t) => "Timestamp \{t}"
    Bool(_) | Int(_) | Decimal(_) | Duration(_) | List(_) | Struct(_) =>
      value.to_string()
  }
}

///|
/// The cell a sidecar line spells, as a scalar.
fn cell(text : String) -> @types.Scalar raise @types.DataError {
  if text == "Null" {
    return @types.Scalar::Null
  }
  let (kind, payload) = match text.split_once(" ") {
    Some(pair) => pair
    None => raise problem("\{text} spells no cell")
  }
  match kind {
    "Float" =>
      @types.Scalar::Float(
        hexadecimal(payload.to_owned()).reinterpret_as_double(),
      )
    "String" => @types.Scalar::String(payload.to_owned())
    "Date" => @types.Scalar::Date(decimal(payload.to_owned()))
    "Timestamp" => @types.Scalar::Timestamp(decimal(payload.to_owned()))
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
    "Float" => @types.DataType::Float
    "String" => @types.DataType::String
    "Date" => @types.DataType::Date
    "Timestamp" => @types.DataType::Timestamp
    _ => raise problem("\{name} names no dtype a sidecar spells")
  }
}

///|
/// What the reader raises for `bytes`; a table answered instead fails
/// the test.
fn read_error(bytes : Bytes) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(read_spss_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the bytes read as a dataset")
    Err(e) => e
  }
}

///|
/// One reference file read through the codec, checked against its
/// sidecar: the case count, the column names in file order, every
/// column's dtype, and every cell. Answers how many cells it compared.
fn check_reference(
  file : String,
  bytes : Bytes,
  sidecar : Json,
) -> Int32 raise @types.DataError {
  let (columns, rows) = read_spss_frame(bytes)
  let ncases = jint(field(sidecar, "ncases"))
  if rows != ncases {
    raise problem(
      "\{file}: the codec reports \{rows} cases, the sidecar \{ncases}",
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
          "\{file}, column \"\{name}\", row \{row + 1}: the codec read \{spelled(cells[row])}, the sidecar \{lines[row]}",
        )
      }
    }
    compared += cells.length()
  }
  compared
}

///|
test "every reference file reads, cell for cell, as its sidecar spells it, or is refused as its sidecar says" {
  // The index lists what the generator wrote: the default corpus, and
  // PSPP's own files too when it ran with --with-pspp. It is read rather
  // than a count, so either corpus passes.
  let index = jarray(fixture_json(".github/fixtures/spss/reference/index.json"))
  // And every data file in the directory is one the index lists: a file
  // the generator did not write cannot go unchecked.
  let listed : Array[String] = index.map(entry => jstring(field(entry, "file")))
  let outcome : Result[ArrayView[String], Unit] = Ok(
    @fs.read_dir(".github/fixtures/spss/reference"),
  ) catch {
    _ => Err(())
  }
  let present = match outcome {
    Ok(names) => names
    Err(_) => fail("cannot list fixtures/reference")
  }
  for name in present {
    if (name.has_suffix(".sav") || name.has_suffix(".zsav")) &&
      !listed.contains(name) {
      fail(
        ".github/fixtures/spss/reference/\{name} is not in the index the generator wrote",
      )
    }
  }
  let mut files = 0
  let mut compared = 0
  let mut refused = 0
  let mut from_generator = 0
  let mut real = 0
  for entry in index {
    let file = jstring(field(entry, "file"))
    let sidecar = fixture_json(".github/fixtures/spss/reference/\{file}.json")
    let bytes = fixture(".github/fixtures/spss/reference/\{file}")
    if jstring(field(entry, "origin")) == "real" {
      real += 1
    }
    let outcome : Result[_, @types.DataError] = Ok(read_spss_frame(bytes)) catch {
      e => Err(e)
    }
    match jstring(field(sidecar, "codec")) {
      "refuses" => {
        let e = match outcome {
          Ok(_) =>
            fail(
              "\{file} read as a dataset; its sidecar says the codec refuses it",
            )
          Err(e) => e
        }
        let wanted = jstring(field(sidecar, "refusal"))
        let got = match e {
          Unsupported(_) => "Unsupported"
          ParseError(Message(_)) => "ParseError"
          _ => "another variant"
        }
        if got != wanted {
          fail(
            "\{file}: the codec refuses with \{e}; its sidecar says \{wanted}",
          )
        }
        refused += 1
      }
      "reads" => {
        let (columns, _) = match outcome {
          Ok(table) => table
          Err(e) => fail("\{file} was refused: \{e}")
        }
        ignore(columns)
        if jstring(field(sidecar, "sidecar_source")) == "generator" {
          from_generator += 1
        }
        compared += check_reference(file, bytes, sidecar)
      }
      other => fail("\{file}: its sidecar says the codec \"\{other}\"")
    }
    files += 1
  }
  // A run over an empty or gutted directory cannot pass for the default
  // corpus, which holds twenty-nine files and 1,622 cells.
  if files < 20 || compared < 1000 {
    fail("only \{compared} cells were compared over \{files} files")
  }
  println(
    "reference files: \{files} (\{real} of them PSPP's own); cells compared: \{compared}; files the codec refuses as their sidecars say: \{refused}; files only this side of the reference reader opens, their cells from the generator's own reading: \{from_generator}",
  )
}
