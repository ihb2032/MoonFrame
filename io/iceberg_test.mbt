// Blackbox tests of the Iceberg entry against the codec's corpus: every
// table read through `read_iceberg`, its rows compared with the rows the
// reference's own plan answers file by file, and every refusal by variant
// and by text; then the entry's own two decisions, which metadata file is
// the current one and which paths open under the table's directory.

///|
/// Where the codec's corpus lives, from the project root.
const ICEBERG_FIXTURES : String = ".github/fixtures/iceberg/reference"

///|
fn iceberg_problem(what : String) -> @types.DataError {
  @types.DataError::InvalidOperation("test: \{what}")
}

///|
fn iceberg_json(path : String) -> Json raise @types.DataError {
  let text = @fs.read_file_to_string(path) catch {
    _ => raise iceberg_problem("cannot read \{path}")
  }
  @json.parse(text) catch {
    _ => raise iceberg_problem("\{path} is not JSON")
  }
}

///|
fn iceberg_field(value : Json, name : String) -> Json raise @types.DataError {
  if value is Object(fields) {
    match fields.get(name) {
      Some(found) => found
      None => raise iceberg_problem("the JSON carries no field \"\{name}\"")
    }
  } else {
    raise iceberg_problem("the JSON value is not an object")
  }
}

///|
fn iceberg_array(value : Json) -> Array[Json] raise @types.DataError {
  if value is Array(items) {
    items
  } else {
    raise iceberg_problem("the JSON value is not an array")
  }
}

///|
fn iceberg_string(value : Json) -> String raise @types.DataError {
  if value is String(text) {
    text
  } else {
    raise iceberg_problem("the JSON value is not a string")
  }
}

///|
fn iceberg_number(value : Json) -> Int64 raise @types.DataError {
  if value is Number(number, ..) {
    number.to_int64()
  } else {
    raise iceberg_problem("the JSON value is not a number")
  }
}

///|
fn iceberg_strings(value : Json) -> Array[String] raise @types.DataError {
  iceberg_array(value).map(iceberg_string)
}

///|
/// The error a sidecar spells: its variant and its text.
fn iceberg_error(want : Json) -> @types.DataError raise @types.DataError {
  let text = iceberg_string(iceberg_field(want, "text"))
  match iceberg_string(iceberg_field(want, "variant")) {
    "Unsupported" => @types.DataError::Unsupported(text)
    "ParseError" =>
      @types.DataError::ParseError(@types.ParseErrorDetail::Message(text))
    "InvalidOperation" => @types.DataError::InvalidOperation(text)
    variant =>
      raise iceberg_problem("a variant the test does not know: \{variant}")
  }
}

///|
/// The error a read of the table at `path` raised; one that answers fails
/// the test.
fn iceberg_read_raised(path : String) -> @types.DataError raise {
  let outcome : Result[Unit, @types.DataError] = Ok(
    ignore(@io.read_iceberg(path)),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the read of \{path} was expected to refuse")
    Err(e) => e
  }
}

///|
/// A cell as the sidecar spells it, as a scalar: the kinds the tables this
/// entry reads hold. A float or a decimal cell names a column the Parquet
/// reader refuses before any cell is compared, so a sidecar of a table read
/// here carries neither.
fn iceberg_cell(cell : Json) -> @types.Scalar raise @types.DataError {
  let kind = iceberg_string(iceberg_field(cell, "kind"))
  if kind == "null" {
    return @types.Scalar::Null
  }
  let value = iceberg_field(cell, "value")
  match kind {
    "int" => @types.Scalar::Int(iceberg_number(value))
    "string" => @types.Scalar::String(iceberg_string(value))
    "boolean" =>
      if value is True {
        @types.Scalar::Bool(true)
      } else if value is False {
        @types.Scalar::Bool(false)
      } else {
        raise iceberg_problem("a boolean cell is spelled otherwise")
      }
    "date" => @types.Scalar::Date(iceberg_number(value))
    "timestamp" => @types.Scalar::Timestamp(iceberg_number(value))
    kind =>
      raise iceberg_problem("a cell kind the test does not spell: \{kind}")
  }
}

///|
test "every table of the corpus reads as the reference's plan answers it, or refuses" {
  let index = iceberg_json("\{ICEBERG_FIXTURES}/index.json")
  let mut compared = 0
  let mut refused = 0
  for entry in iceberg_array(iceberg_field(index, "tables")) {
    let name = iceberg_string(iceberg_field(entry, "name"))
    let sidecar = iceberg_json("\{ICEBERG_FIXTURES}/\{name}.json")
    let outcome : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.read_iceberg("\{ICEBERG_FIXTURES}/\{name}"),
    ) catch {
      e => Err(e)
    }
    if iceberg_string(iceberg_field(sidecar, "codec")) == "refuses" {
      // The codec's own refusal, raised through the entry unchanged.
      assert_eq(outcome, Err(iceberg_error(iceberg_field(sidecar, "refusal"))))
      refused += 1
      continue
    }
    let plan_rows = iceberg_field(sidecar, "plan_rows")
    if plan_rows is Null {
      continue
    }
    // What the entry refuses itself, beyond what the codec refuses: a
    // column of a type the Parquet reader does not carry, a nested
    // column, an equality-delete file it does not apply. One data file of
    // `partition_scalars` is not carried, its path too long for a
    // checkout (the sidecar names it): whichever of its two data files the
    // plan names first refuses — the float column of the one carried, or
    // the missing file.
    let own : Array[(String, String)] = match name {
      "evolution" => [("Unsupported", "carries a dtype MoonFrame cannot map")]
      "types" => [("ParseError", "the schema carries the nested group")]
      "equality_deletes" => [("Unsupported", "equality-delete file")]
      "partition_scalars" =>
        [
          ("Unsupported", "carries a dtype MoonFrame cannot map"),
          ("IoError", ""),
        ]
      _ => []
    }
    if !own.is_empty() {
      let error = iceberg_read_raised("\{ICEBERG_FIXTURES}/\{name}")
      let spelled = iceberg_variant(error)
      assert_true(
        own.any(wanted => {
          let (variant, fragment) = wanted
          spelled == variant && error.message().contains(fragment)
        }),
      )
      refused += 1
      continue
    }
    let frame = match outcome {
      Ok(frame) => frame
      Err(error) => fail("\{name}: the entry refused: \{error}")
    }
    // The columns in the schema's order, and every cell as the reference's
    // plan spells it, file by file.
    assert_eq(
      frame.columns(),
      iceberg_strings(iceberg_field(iceberg_field(sidecar, "schema"), "names")),
    )
    let rows = iceberg_array(plan_rows)
    assert_eq(frame.nrows(), rows.length())
    let differences : Array[String] = []
    for r, row in rows {
      for column in frame.columns() {
        let want = iceberg_cell(iceberg_field(row, column))
        let got = frame.get_column(column).to_scalars()[r]
        if got != want {
          differences.push(
            "\{name}, row \{r}, column \"\{column}\": \{got} where the reference's plan answers \{want}",
          )
        }
      }
    }
    if !differences.is_empty() {
      fail("\{differences.length()} differences:\n\{differences.join("\n")}")
    }
    compared += 1
  }
  assert_eq(compared, 21)
  assert_eq(refused, 11)
}

///|
/// An error's variant, as the sidecars spell it.
fn iceberg_variant(error : @types.DataError) -> String {
  match error {
    @types.DataError::Unsupported(_) => "Unsupported"
    @types.DataError::ParseError(_) => "ParseError"
    @types.DataError::InvalidOperation(_) => "InvalidOperation"
    @types.DataError::IoError(_) => "IoError"
    _ => "other"
  }
}

///|
/// A directory and everything under it, when it is there.
fn iceberg_remove(path : String) -> Unit raise {
  if !@fs.path_exists(path) {
    return
  }
  for name in @fs.read_dir(path) {
    let child = "\{path}/\{name}"
    if @fs.is_dir(child) {
      iceberg_remove(child)
    } else {
      @fs.remove_file(child)
    }
  }
  @fs.remove_dir(path)
}

///|
/// A table's directory copied under another, file by file — into a
/// directory that starts empty, whatever an earlier run left there.
fn iceberg_copy(from : String, to : String) -> Unit raise {
  iceberg_remove(to)
  @fs.create_dir(to) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  let names = @fs.read_dir(from) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  for name in names {
    let source = "\{from}/\{name}"
    let target = "\{to}/\{name}"
    let directory = @fs.is_dir(source) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
    if directory {
      iceberg_copy(source, target)
    } else {
      let bytes = @fs.read_file_to_bytes(source) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
      @fs.write_bytes_to_file(target, bytes) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
    }
  }
}

///|
/// A table's metadata files: their names, sorted.
fn iceberg_metadata_names(
  root : String,
) -> Array[String] raise @types.DataError {
  let names = @fs.read_dir("\{root}/metadata") catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  let out : Array[String] = []
  for name in names {
    if name.has_suffix(".metadata.json") {
      out.push(name)
    }
  }
  out.sort()
  out
}

///|
/// Leave a copied table its current metadata file alone, under a name the
/// test spells: the last of its metadata files is renamed to `to`, and
/// the others are removed.
fn iceberg_rename_metadata(root : String, to : String) -> Unit raise {
  let names = iceberg_metadata_names(root)
  assert_true(names.length() > 0)
  let current = names[names.length() - 1]
  let bytes = @fs.read_file_to_bytes("\{root}/metadata/\{current}") catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  @fs.write_bytes_to_file("\{root}/metadata/\{to}", bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  for name in names {
    @fs.remove_file("\{root}/metadata/\{name}") catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
  }
}

///|
test "the current metadata file is the one the version hint names, in each of its spellings" {
  let wanted = @io.read_iceberg("\{ICEBERG_FIXTURES}/append_one")
  // A hint naming the file as it is spelled.
  let spelled = "_build/iceberg_hint_spelled"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_one", spelled)
  @fs.write_string_to_file(
    "\{spelled}/metadata/version-hint.text",
    "00000-0-hint.metadata.json\n",
  )
  iceberg_rename_metadata(spelled, "00000-0-hint.metadata.json")
  assert_eq(@io.read_iceberg(spelled), wanted)
  // A bare number names `v<number>.metadata.json`; the content is trimmed.
  let numbered = "_build/iceberg_hint_number"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_one", numbered)
  @fs.write_string_to_file("\{numbered}/metadata/version-hint.text", " 7 ")
  iceberg_rename_metadata(numbered, "v7.metadata.json")
  assert_eq(@io.read_iceberg(numbered), wanted)
  // Anything else names `<content>.metadata.json`.
  let other = "_build/iceberg_hint_other"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_one", other)
  @fs.write_string_to_file("\{other}/metadata/version-hint.text", "latest")
  iceberg_rename_metadata(other, "latest.metadata.json")
  assert_eq(@io.read_iceberg(other), wanted)
  // A hint naming a file that is not there is the I/O error of reading it.
  @fs.write_string_to_file("\{other}/metadata/version-hint.text", "absent")
  assert_true(iceberg_read_raised(other) is @types.DataError::IoError(_))
}

///|
test "without a hint, the metadata file with the greatest leading number is the current one" {
  // `00009-…` outranks `v2.…` and `00003-…`, as numbers: 9 before 10, and
  // before 2 whatever the spelling's length.
  let table = "_build/iceberg_greatest"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_one", table)
  iceberg_rename_metadata(table, "00009-0-greatest.metadata.json")
  @fs.write_bytes_to_file("\{table}/metadata/v2.metadata.json", b"{}")
  @fs.write_bytes_to_file(
    "\{table}/metadata/00003-0-older.metadata.json",
    b"{}",
  )
  assert_eq(
    @io.read_iceberg(table),
    @io.read_iceberg("\{ICEBERG_FIXTURES}/append_one"),
  )
  // A greater number wins even where its file is no metadata at all: the
  // choice is made on the name, and the file then refuses as malformed.
  @fs.write_bytes_to_file("\{table}/metadata/00010-0-newer.metadata.json", b"{")
  assert_true(iceberg_read_raised(table) is @types.DataError::ParseError(_))
  assert_eq(
    iceberg_metadata_names(table)
    .filter(name => name.has_prefix("00010"))
    .length(),
    1,
  )
  // A name that leads with no number ranks below every numbered one,
  // whatever it holds.
  @fs.write_bytes_to_file("\{table}/metadata/.metadata.json", b"{")
  assert_true(iceberg_read_raised(table) is @types.DataError::ParseError(_))
  @fs.remove_file("\{table}/metadata/00010-0-newer.metadata.json")
  assert_eq(
    @io.read_iceberg(table),
    @io.read_iceberg("\{ICEBERG_FIXTURES}/append_one"),
  )
}

///|
test "a table that is no table refuses: no metadata directory, no metadata file, a missing path" {
  assert_true(
    iceberg_read_raised("_build/iceberg_absent") is @types.DataError::IoError(_),
  )
  let bare = "_build/iceberg_bare"
  @fs.create_dir("\{bare}/metadata")
  assert_eq(
    iceberg_read_raised(bare),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the table's metadata directory names no metadata file",
      ),
    ),
  )
  // A trailing separator on the path names the same table.
  assert_eq(
    iceberg_read_raised("\{bare}/"),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the table's metadata directory names no metadata file",
      ),
    ),
  )
}

///|
test "a file a manifest names but the table does not hold is the I/O error of reading it" {
  let table = "_build/iceberg_missing_file"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_three", table)
  let sidecar = iceberg_json("\{ICEBERG_FIXTURES}/append_three.json")
  let plan = iceberg_field(sidecar, "plan")
  let first = iceberg_array(iceberg_field(plan, "manifests"))[0]
  let file = iceberg_array(iceberg_field(first, "files"))[0]
  let path = iceberg_string(iceberg_field(file, "path"))
  @fs.remove_file("\{table}/\{path}")
  assert_true(iceberg_read_raised(table) is @types.DataError::IoError(_))
}

///|
/// A file of the table replaced by other bytes.
fn iceberg_overwrite(
  table : String,
  relative : String,
  bytes : Bytes,
) -> Unit raise {
  @fs.write_bytes_to_file("\{table}/\{relative}", bytes)
}

///|
/// The files of the table's snapshot the sidecar names, of the kind asked:
/// their paths and record counts, in the plan's order.
fn iceberg_files_of(
  sidecar : Json,
  kind : Int64,
) -> Array[(String, Int64)] raise @types.DataError {
  let out : Array[(String, Int64)] = []
  for
    manifest in iceberg_array(
      iceberg_field(iceberg_field(sidecar, "plan"), "manifests"),
    ) {
    for file in iceberg_array(iceberg_field(manifest, "files")) {
      if iceberg_number(iceberg_field(file, "kind")) == kind {
        out.push(
          (
            iceberg_string(iceberg_field(file, "path")),
            iceberg_number(iceberg_field(file, "record_count")),
          ),
        )
      }
    }
  }
  out
}

///|
/// The bytes of a Parquet file the fixtures hold for the reading of rows.
fn iceberg_io_fixture(name : String) -> Bytes raise {
  @fs.read_file_to_bytes(".github/fixtures/iceberg/io/\{name}")
}

///|
test "a data file that names no field id refuses, naming the file" {
  let table = "_build/iceberg_no_ids"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_one", table)
  let sidecar = iceberg_json("\{ICEBERG_FIXTURES}/append_one.json")
  let (path, _) = iceberg_files_of(sidecar, 0)[0]
  // The library's own writer names no field id.
  let plain = "_build/iceberg_no_ids_source.parquet"
  @io.write_parquet(@io.read_parquet("\{table}/\{path}"), plain)
  iceberg_overwrite(table, path, @fs.read_file_to_bytes(plain))
  assert_eq(
    iceberg_read_raised(table),
    @types.DataError::Unsupported(
      "iceberg: the file \{path} names no field id, so its columns cannot be matched to the table's",
    ),
  )
}

///|
test "a data file answering other rows than its entry names refuses, naming both counts" {
  let table = "_build/iceberg_other_rows"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_three", table)
  let sidecar = iceberg_json("\{ICEBERG_FIXTURES}/append_three.json")
  let mut path = ""
  let mut count = 0L
  for (file, rows) in iceberg_files_of(sidecar, 0) {
    if rows != 3L && path.is_empty() {
      path = file
      count = rows
    }
  }
  assert_true(count > 0L)
  // Three rows under the ids of the table's first two columns.
  iceberg_overwrite(
    table,
    path,
    iceberg_io_fixture("data_without_third.parquet"),
  )
  assert_eq(
    iceberg_read_raised(table),
    @types.DataError::InvalidOperation(
      "iceberg: the file \{path} answers 3 rows, where its manifest entry names \{count}",
    ),
  )
}

///|
test "a column a file does not hold reads null, and a partition column its partition value" {
  // A file written before the table's third column: the column reads null
  // over its rows, and the others read as the file spells them.
  let table = "_build/iceberg_absent_column"
  iceberg_copy("\{ICEBERG_FIXTURES}/unicode", table)
  let (path, _) = iceberg_files_of(
      iceberg_json("\{ICEBERG_FIXTURES}/unicode.json"),
      0,
    )[0]
  iceberg_overwrite(
    table,
    path,
    iceberg_io_fixture("data_without_third.parquet"),
  )
  let frame = @io.read_iceberg(table)
  assert_eq(frame.columns(), ["col naïf", "a.b", "with space"])
  assert_eq(frame.nrows(), 3)
  assert_eq(frame.get_column("col naïf").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::Null,
    @types.Scalar::String("z"),
  ])
  // The column is an `Int` the file spelled as text: cast.
  assert_eq(frame.get_column("a.b").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Null,
  ])
  assert_eq(frame.get_column("with space").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // A file of a partitioned table without its partition column: the column
  // reads the file's partition value, and the table reads as it does.
  let partitioned = "_build/iceberg_partition_fill"
  iceberg_copy("\{ICEBERG_FIXTURES}/partition_identity", partitioned)
  let sidecar = iceberg_json("\{ICEBERG_FIXTURES}/partition_identity.json")
  // The one file lying in the partition `k` = b: its partition tuple's
  // first field names the column and spells the value.
  let mut filled = ""
  for
    manifest in iceberg_array(
      iceberg_field(iceberg_field(sidecar, "plan"), "manifests"),
    ) {
    for file in iceberg_array(iceberg_field(manifest, "files")) {
      let first = iceberg_array(
        iceberg_array(iceberg_field(file, "partition"))[0],
      )
      // A null partition value spells no value at all.
      if iceberg_string(first[0]) == "k" && first[3] is Object(members) {
        match members.get("value") {
          Some(String("b")) =>
            filled = iceberg_string(iceberg_field(file, "path"))
          _ => ()
        }
      }
    }
  }
  assert_true(!filled.is_empty())
  iceberg_overwrite(
    partitioned,
    filled,
    iceberg_io_fixture("data_without_k.parquet"),
  )
  assert_eq(
    @io.read_iceberg(partitioned),
    @io.read_iceberg("\{ICEBERG_FIXTURES}/partition_identity"),
  )
}

///|
test "a position-delete file of the wrong cells refuses, naming the file and the cell" {
  let delete = "00000-0-position-deletes.parquet"
  let table = "_build/iceberg_delete_shape"
  let source = "\{ICEBERG_FIXTURES}/position_deletes"
  // A file naming neither of the delete file's two columns by field id.
  iceberg_copy(source, table)
  let plain = "_build/iceberg_delete_shape_source.parquet"
  @io.write_parquet(@io.read_parquet("\{table}/data/\{delete}"), plain)
  iceberg_overwrite(table, "data/\{delete}", @fs.read_file_to_bytes(plain))
  assert_eq(
    iceberg_read_raised(table),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the position-delete file data/\{delete} names no column of the data file's path or of the position",
      ),
    ),
  )
  // A path cell that is a whole number.
  iceberg_overwrite(
    table,
    "data/\{delete}",
    iceberg_io_fixture("delete_path_int.parquet"),
  )
  assert_eq(
    iceberg_read_raised(table),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the position-delete file data/\{delete} holds a data file's path that is not a string",
      ),
    ),
  )
  // A position cell that is a text.
  iceberg_overwrite(
    table,
    "data/\{delete}",
    iceberg_io_fixture("delete_position_text.parquet"),
  )
  assert_eq(
    iceberg_read_raised(table),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the position-delete file data/\{delete} holds a position that is not a whole number",
      ),
    ),
  )
}

///|
test "a path of separators only names the table at the filesystem's root, which is no table" {
  for path in ["", "/", "//"] {
    let error = iceberg_read_raised(path)
    assert_true(
      error is @types.DataError::IoError(_) ||
      error is @types.DataError::ParseError(_),
    )
  }
}

///|
test "a version hint that cannot be read is the I/O error of reading it" {
  let table = "_build/iceberg_hint_unreadable"
  iceberg_copy("\{ICEBERG_FIXTURES}/append_one", table)
  @fs.create_dir("\{table}/metadata/version-hint.text")
  assert_true(iceberg_read_raised(table) is @types.DataError::IoError(_))
}
