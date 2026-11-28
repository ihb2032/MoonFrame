// Blackbox tests over the reference corpus. Each directory under
// `.github/fixtures/iceberg/reference/` is a table the reference wrote, or one derived from
// a table it wrote; the JSON beside it holds what the reference itself
// answers for that table — its schema, its partition fields, the manifests
// of its snapshot's list and the files they hold, and its rows — and, where
// the codec refuses the table, the exact text of its refusal;
// the generator beside them wrote both. A cell is spelled `<kind>:<value>`: a
// double by the sixteen hex digits of its bits, a date by its days and a
// timestamp by its microseconds since the epoch, a decimal by its text.

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
/// A fixture file parsed as JSON, every number kept by its own digits.
fn fixture_json(path : String) -> Json raise @types.DataError {
  let text = @fs.read_file_to_string(path) catch {
    _ => raise problem("cannot read the fixture \{path}")
  }
  @json.parse(text, preserve_number_repr=true) catch {
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
/// A JSON number's own digits: a whole number is compared by its text, so
/// that a 64-bit identifier loses nothing on either side.
fn jtext(value : Json) -> String raise @types.DataError {
  match value {
    Number(_, repr=Some(text)) => text
    String(text) => text
    True => "true"
    False => "false"
    _ => raise problem("the JSON value is neither a number nor a string")
  }
}

///|
/// Sixteen lowercase hexadecimal digits.
fn hex64(bits : UInt64) -> String {
  let digits = "0123456789abcdef".code_units()
  let out = StringBuilder()
  for shift in [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0] {
    let digit = (bits >> shift).to_int() & 15
    out.write_char(digits[digit].to_byte().to_char())
  }
  out.to_string()
}

///|
/// The library dtype a field reads as, spelled the way the sidecar spells
/// the reference's type: a list as `List[...]`, a struct by its fields.
fn describe(dtype : @types.DataType) -> String {
  match dtype {
    Bool => "Bool"
    Int => "Int"
    Float => "Float"
    String => "String"
    Date => "Date"
    Timestamp => "Timestamp"
    Decimal => "Decimal"
    Duration => "Duration"
    Null => "Null"
    List(element) => "List[\{describe(element)}]"
    Struct(schema) =>
      "Struct{" +
      schema
      .fields()
      .map(fn(one) { "\{one.name()}: \{describe(one.dtype())}" })
      .join(", ") +
      "}"
  }
}

///|
/// A transform spelled the way the sidecar spells the reference's.
fn transform_text(transform : IcebergTransform) -> String {
  match transform {
    Identity => "identity"
    Bucket(n) => "bucket[\{n}]"
    Truncate(n) => "truncate[\{n}]"
    Year => "year"
    Month => "month"
    Day => "day"
    Hour => "hour"
    Void => "void"
    Unknown(name) => name
  }
}

///|
/// A cell as the sidecar spells it.
fn cell_text(spell : Json) -> String raise @types.DataError {
  let kind = jstring(field(spell, "kind"))
  if kind == "null" {
    return "null"
  }
  let value = jtext(field(spell, "value"))
  "\{kind}:\{value}"
}

///|
/// A partition value as the codec answers it, spelled the same way.
fn scalar_text(value : @types.Scalar) -> String {
  match value {
    Null => "null"
    Bool(b) => "bool:\{b}"
    Int(n) => "int:\{n}"
    Float(d) => "float:\{hex64(d.reinterpret_as_uint64())}"
    String(s) => "string:\{s}"
    Date(days) => "date:\{days}"
    Timestamp(micros) => "timestamp:\{micros}"
    Decimal(d) => "decimal:\{d.to_string()}"
    Duration(_) => "duration"
    List(_) => "list"
    Struct(_) => "struct"
  }
}

///|
/// A kind of file as the sidecar's number: 0 data, 1 position deletes,
/// 2 equality deletes.
fn kind_text(kind : IcebergFileKind) -> String {
  match kind {
    Data => "0"
    PositionDeletes => "1"
    EqualityDeletes => "2"
  }
}

///|
/// The names of a directory, which must be there.
fn directory(path : String) -> ArrayView[String] raise @types.DataError {
  let outcome : Result[ArrayView[String], Unit] = Ok(@fs.read_dir(path)) catch {
    _ => Err(())
  }
  match outcome {
    Ok(names) => names
    Err(_) => raise problem("cannot list the directory \{path}")
  }
}

///|
/// The digits a file's name opens with, or -1 when it opens with none.
fn leading_number(name : String) -> Int64 {
  let mut value = 0L
  let mut at = 0
  while at < name.length() {
    let digit = name[at].to_int() - 48
    if digit < 0 || digit > 9 {
      return if at == 0 { -1L } else { value }
    }
    if value > 922337203685477579L {
      return -1L
    }
    value = value * 10L + digit.to_int64()
    at += 1
  }
  if at == 0 {
    -1L
  } else {
    value
  }
}

///|
/// The metadata file of a table's directory with the greatest version
/// number: the current one, for a table no catalog points into.
fn current_metadata(dir : String) -> String raise @types.DataError {
  let names = directory("\{dir}/metadata")
  let mut newest = ""
  let mut version = -1L
  for name in names {
    if name.has_suffix(".metadata.json") {
      let number = leading_number(name)
      if number > version {
        version = number
        newest = name
      }
    }
  }
  if newest == "" {
    raise problem("\{dir}/metadata holds no metadata file")
  }
  "\{dir}/metadata/\{newest}"
}

///|
/// The variant of an error, as the sidecar names it.
fn variant(error : @types.DataError) -> String {
  match error {
    Unsupported(_) => "Unsupported"
    ParseError(_) => "ParseError"
    ColumnNotFound(_) => "ColumnNotFound"
    DuplicateColumn(_) => "DuplicateColumn"
    TypeMismatch(_) => "TypeMismatch"
    LengthMismatch(_, _) => "LengthMismatch"
    IndexOutOfBounds(_) => "IndexOutOfBounds"
    InvalidOperation(_) => "InvalidOperation"
    IoError(_) => "IoError"
    NullInNonNullable(_) => "NullInNonNullable"
  }
}

///|
/// Whether an error is the refusal the sidecar's `refusal` names, by
/// variant and by text; when it is not, why.
fn refusal_agrees(
  error : @types.DataError,
  refusal : Json,
) -> Result[Unit, String] raise @types.DataError {
  let wanted = jstring(field(refusal, "variant"))
  if variant(error) != wanted {
    return Err(
      "the codec raises \{variant(error)}; the sidecar names \{wanted}",
    )
  }
  let text = match error {
    Unsupported(text) => text
    ParseError(Message(text)) => text
    _ => return Err("the codec raises \{variant(error)}, which carries no text")
  }
  let expected = jstring(field(refusal, "text"))
  if text != expected {
    Err("the codec says \"\{text}\"; the sidecar says \"\{expected}\"")
  } else {
    Ok(())
  }
}

///|
/// One file against the sidecar's entry: its path, kind, record count,
/// sequence number, field ids, equality ids and partition values.
fn check_file(
  place : String,
  file : IcebergFile,
  expected : Json,
  differences : Array[String],
) -> Unit raise @types.DataError {
  let spelled = "\{file.path()}|\{kind_text(file.kind())}|\{file.record_count()}|\{file.sequence_number()}|\{file.field_ids().map(fn(n) { n.to_string() }).join(",")}|\{file.equality_ids().map(fn(n) { n.to_string() }).join(",")}"
  let ids_text = jarray(field(expected, "field_ids"))
    .map(n => jtext(n))
    .join(",")
  let equality_text = jarray(field(expected, "equality_ids"))
    .map(n => jtext(n))
    .join(",")
  let path = jstring(field(expected, "path"))
  let kind = jtext(field(expected, "kind"))
  let count = jtext(field(expected, "record_count"))
  let sequence = jtext(field(expected, "sequence_number"))
  let expected_text = "\{path}|\{kind}|\{count}|\{sequence}|\{ids_text}|\{equality_text}"
  if spelled != expected_text {
    differences.push(
      "\{place}: the file is \{spelled}; the sidecar says \{expected_text}",
    )
    return
  }
  let partition = jarray(field(expected, "partition"))
  let values = file.partition()
  if values.length() != partition.length() {
    differences.push(
      "\{place}: \{values.length()} partition values, the sidecar \{partition.length()}",
    )
    return
  }
  for i, value in values {
    let wanted = jarray(partition[i])
    let one = "\{value.name()}|\{value.source_id()}|\{transform_text(value.transform())}|\{scalar_text(value.value())}"
    let other = "\{jstring(wanted[0])}|\{jtext(wanted[1])}|\{jstring(wanted[2])}|\{cell_text(wanted[3])}"
    if one != other {
      differences.push(
        "\{place}, partition value \{i}: \{one}; the sidecar says \{other}",
      )
    }
  }
}

///|
/// One table of the corpus against its sidecar: the metadata, the manifest
/// list, every manifest and every file. Answers false when the table is one
/// the sidecar says the codec refuses.
fn check_table(
  name : String,
  differences : Array[String],
) -> Bool raise @types.DataError {
  let dir = ".github/fixtures/iceberg/reference/\{name}"
  let sidecar = fixture_json("\{dir}.json")
  let bytes = fixture(current_metadata(dir))
  let outcome : Result[IcebergTable, @types.DataError] = Ok(
    iceberg_metadata(bytes),
  ) catch {
    error => Err(error)
  }
  match jstring(field(sidecar, "codec")) {
    "refuses" => {
      // The sidecar names the reading that refuses: the metadata file
      // itself, or the snapshot's manifest list further down the chain.
      let refusal = field(sidecar, "refusal")
      let step = jstring(field(refusal, "step"))
      match outcome {
        Ok(table) =>
          if step == "manifest_list" {
            let list_path = table.manifest_list().unwrap_or("")
            let listed : Result[Array[IcebergManifest], @types.DataError] = Ok(
              iceberg_manifests(
                fixture("\{dir}/\{list_path}"),
                location=table.location(),
              ),
            ) catch {
              error => Err(error)
            }
            match listed {
              Ok(_) =>
                differences.push(
                  "\{name}: its manifest list reads; its sidecar says the codec refuses it",
                )
              Err(error) =>
                match refusal_agrees(error, refusal) {
                  Ok(_) => ()
                  Err(why) => differences.push("\{name}: \{why}")
                }
            }
          } else {
            differences.push(
              "\{name} reads as a table; its sidecar says the codec refuses its metadata",
            )
          }
        Err(error) =>
          if step == "manifest_list" {
            differences.push(
              "\{name}: its metadata was refused (\{error.message()}); its sidecar says the refusal lies in the manifest list",
            )
          } else {
            match refusal_agrees(error, refusal) {
              Ok(_) => ()
              Err(why) => differences.push("\{name}: \{why}")
            }
          }
      }
      return false
    }
    "reads" => ()
    other => raise problem("\{name}: its sidecar says the codec \"\{other}\"")
  }
  let table = match outcome {
    Ok(found) => found
    Err(error) => {
      differences.push("\{name} was refused: \{error.message()}")
      return false
    }
  }
  if table.location() != jstring(field(sidecar, "location")) {
    differences.push("\{name}: the location is \{table.location()}")
  }
  let schema = field(sidecar, "schema")
  let names = jarray(field(schema, "names")).map(n => jstring(n))
  let dtypes = jarray(field(schema, "dtypes")).map(n => jstring(n))
  let ids = jarray(field(schema, "field_ids")).map(n => jtext(n))
  let fields = table.schema().fields()
  if fields.length() != names.length() {
    differences.push(
      "\{name}: \{fields.length()} columns, the sidecar \{names.length()}",
    )
  }
  for i, one in fields {
    if i < names.length() {
      if one.name() != names[i] || describe(one.dtype()) != dtypes[i] {
        differences.push(
          "\{name}, column \{i}: \{one.name()} \{describe(one.dtype())}; the sidecar \{names[i]} \{dtypes[i]}",
        )
      }
    }
  }
  let codec_ids = table.field_ids().map(fn(n) { n.to_string() })
  if codec_ids != ids {
    differences.push(
      "\{name}: the field ids are \{codec_ids.join(", ")}; the sidecar \{ids.join(", ")}",
    )
  }
  let plan = field(sidecar, "plan")
  let listed = jarray(field(plan, "manifests"))
  match table.manifest_list() {
    None =>
      if field(plan, "manifest_list") is Null {
        ()
      } else {
        differences.push(
          "\{name}: no manifest list where the sidecar names one",
        )
      }
    Some(list) => {
      if list != jstring(field(plan, "manifest_list")) {
        differences.push("\{name}: the manifest list is \{list}")
      }
      let manifests = iceberg_manifests(
        fixture("\{dir}/\{list}"),
        location=table.location(),
      )
      if manifests.length() != listed.length() {
        differences.push(
          "\{name}: \{manifests.length()} manifests, the sidecar \{listed.length()}",
        )
      }
      for m, manifest in manifests {
        if m >= listed.length() {
          break
        }
        if manifest.path() != jstring(field(listed[m], "path")) {
          let expected = jstring(field(listed[m], "path"))
          differences.push(
            "\{name}, manifest \{m}: the path is \{manifest.path()}; the sidecar says \{expected}",
          )
        }
        let wanted = jarray(field(listed[m], "files"))
        let files = iceberg_files(
          fixture("\{dir}/\{manifest.path()}"),
          manifest~,
        )
        if files.length() != wanted.length() {
          differences.push(
            "\{name}, manifest \{m}: \{files.length()} files, the sidecar \{wanted.length()}",
          )
        }
        for f, file in files {
          if f >= wanted.length() {
            break
          }
          check_file(
            "\{name}, manifest \{m}, file \{f}",
            file,
            wanted[f],
            differences,
          )
        }
      }
    }
  }
  true
}

///|
test "every table of the corpus reads, file for file, as its sidecar spells it, or is refused as its sidecar says" {
  // The index lists what the generator wrote. It is read rather than a
  // count, so the test passes on any corpus the generator writes.
  let index = fixture_json(".github/fixtures/iceberg/reference/index.json")
  let listed = jarray(field(index, "tables")).map(entry => {
    jstring(field(entry, "name"))
  })
  // And every directory and sidecar in the corpus belongs to a listed
  // table: a table the generator did not write cannot go unchecked.
  for name in directory(".github/fixtures/iceberg/reference") {
    if name == "index.json" || name == "patched" {
      continue
    }
    let base = if name.has_suffix(".json") {
      name[:name.length() - 5].to_owned()
    } else {
      name
    }
    if !listed.contains(base) {
      fail(
        ".github/fixtures/iceberg/reference/\{name} is not in the index the generator wrote",
      )
    }
  }
  if listed.length() < 20 {
    fail("the corpus holds only \{listed.length()} tables")
  }
  let differences : Array[String] = []
  let mut refused = 0
  let mut tables = 0
  for name in listed {
    if check_table(name, differences) {
      tables += 1
    } else {
      refused += 1
    }
  }
  for difference in differences {
    println("DIFFERENCE \{difference}")
  }
  if differences.length() != 0 {
    fail("\{differences.length()} differences against the sidecars")
  }
  if refused < 8 {
    fail("only \{refused} tables were refused as their sidecars say")
  }
  println(
    "reference tables: \{listed.length()}; read as their sidecars spell them: \{tables}; refused as their sidecars say: \{refused}",
  )
}
