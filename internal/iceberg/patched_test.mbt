// Blackbox tests over the hand-patched files of the corpus. Each file under
// `.github/fixtures/iceberg/reference/patched/` is one malformed shape — a metadata JSON
// edited, cut or replaced; a manifest list or a manifest built record by
// record, or the list a table really holds with bytes patched in place —
// and `index.json` names, for each, the variant and the exact text of the
// refusal the codec owes, or what it must answer for the shapes it must
// accept; the generator beside them wrote both.

///|
/// A JSON value's field, or a JSON null when the object lacks it.
fn loose_field(value : Json, name : String) -> Json raise @types.DataError {
  if value is Object(fields) {
    fields.get(name).unwrap_or(@json.null)
  } else {
    raise problem("the JSON value is not an object")
  }
}

///|
/// A table against what its entry says the codec answers for it: its field
/// ids, the location of its manifest list (none for no snapshot), its
/// partition fields and, where the entry names them, its dtypes. Answers
/// why they differ, or "" when they agree.
fn check_answers(
  table : IcebergTable,
  answers : Json,
) -> String raise @types.DataError {
  let ids = jarray(field(answers, "field_ids")).map(n => jtext(n))
  let codec_ids = table.field_ids().map(fn(n) { n.to_string() })
  if codec_ids != ids {
    return "the field ids are \{codec_ids.join(", ")}; the entry says \{ids.join(", ")}"
  }
  let listed = field(answers, "manifest_list")
  match (table.manifest_list(), listed) {
    (None, Null) => ()
    (Some(found), String(expected)) =>
      if found != expected {
        return "the manifest list is \{found}; the entry says \{expected}"
      }
    (None, _) => return "no manifest list where the entry names one"
    (Some(_), Null) => return "a manifest list where the entry names none"
    (Some(_), _) =>
      return "the entry's manifest list is neither a string nor null"
  }
  match loose_field(answers, "dtypes") {
    Null => ()
    wanted => {
      let expected = jarray(wanted).map(n => jstring(n))
      let codec = table.schema().fields().map(fn(one) { describe(one.dtype()) })
      if codec != expected {
        return "the dtypes are \{codec.join(", ")}; the entry says \{expected.join(", ")}"
      }
    }
  }
  ""
}

///|
/// The manifest list's entry for a manifest, read from the list the entry
/// names beside it.
fn listed_manifest(entry : Json) -> IcebergManifest raise @types.DataError {
  let list = ".github/fixtures/iceberg/reference/" +
    jstring(field(entry, "list"))
  let location = jstring(field(entry, "location"))
  let manifests = iceberg_manifests(fixture(list), location~)
  if manifests.length() != 1 {
    raise problem(
      "the list beside a patched manifest names \{manifests.length()} manifests, not one",
    )
  }
  manifests[0]
}

///|
/// One patched file against its entry. Answers "" when the codec does what
/// the entry says, and why not otherwise.
fn check_patched(entry : Json) -> String raise @types.DataError {
  let shape = jstring(field(entry, "shape"))
  let file = ".github/fixtures/iceberg/reference/" +
    jstring(field(entry, "file"))
  match jstring(field(entry, "kind")) {
    "metadata" => {
      let outcome : Result[IcebergTable, @types.DataError] = Ok(
        iceberg_metadata(fixture(file)),
      ) catch {
        error => Err(error)
      }
      match jstring(field(entry, "codec")) {
        "refuses" =>
          match outcome {
            Ok(_) =>
              "\{shape} reads as a table; its entry says the codec refuses it"
            Err(error) =>
              match refusal_agrees(error, field(entry, "refusal")) {
                Ok(_) => ""
                Err(why) => "\{shape}: \{why}"
              }
          }
        "reads" =>
          match outcome {
            Ok(table) => check_answers(table, field(entry, "answers"))
            Err(error) => "\{shape} was refused: \{error.message()}"
          }
        other =>
          raise problem("\{shape}: its entry says the codec \"\{other}\"")
      }
    }
    "list" => {
      let location = jstring(field(entry, "location"))
      let outcome : Result[Array[IcebergManifest], @types.DataError] = Ok(
        iceberg_manifests(fixture(file), location~),
      ) catch {
        error => Err(error)
      }
      match jstring(field(entry, "codec")) {
        "refuses" =>
          match outcome {
            Ok(_) =>
              "\{shape} reads as a list; its entry says the codec refuses it"
            Err(error) =>
              match refusal_agrees(error, field(entry, "refusal")) {
                Ok(_) => ""
                Err(why) => "\{shape}: \{why}"
              }
          }
        "reads" =>
          match outcome {
            Ok(manifests) => {
              let wanted = jarray(field(entry, "manifests"))
              if manifests.length() != wanted.length() {
                "\{shape}: \{manifests.length()} manifests; the entry says \{wanted.length()}"
              } else {
                let mut differs = ""
                for i, manifest in manifests {
                  if differs == "" &&
                    manifest.path() != jstring(field(wanted[i], "path")) {
                    differs = "\{shape}: the path is \{manifest.path()}; the entry says \{jstring(field(wanted[i], "path"))}"
                  }
                }
                differs
              }
            }
            Err(error) => "\{shape} was refused: \{error.message()}"
          }
        other =>
          raise problem("\{shape}: its entry says the codec \"\{other}\"")
      }
    }
    "manifest" => {
      // With the list's entry beside it, the manifest is told where the
      // table lies and what the list says of it; without one it is read
      // on its own.
      let context = match loose_field(entry, "list") {
        Null => None
        _ => Some(listed_manifest(entry))
      }
      let outcome : Result[Array[IcebergFile], @types.DataError] = Ok(
        match context {
          Some(manifest) => iceberg_files(fixture(file), manifest~)
          None => iceberg_files(fixture(file))
        },
      ) catch {
        error => Err(error)
      }
      match jstring(field(entry, "codec")) {
        "refuses" =>
          match outcome {
            Ok(files) =>
              "\{shape} reads as \{files.length()} files; its entry says the codec refuses it"
            Err(error) =>
              match refusal_agrees(error, field(entry, "refusal")) {
                Ok(_) => ""
                Err(why) => "\{shape}: \{why}"
              }
          }
        "reads" =>
          match outcome {
            Ok(files) => {
              let wanted = jarray(field(entry, "files"))
              if files.length() != wanted.length() {
                return "\{shape}: \{files.length()} files; the entry says \{wanted.length()}"
              }
              let differences : Array[String] = []
              for f, one in files {
                check_file(shape, one, wanted[f], differences)
              }
              differences.join("; ")
            }
            Err(error) => "\{shape} was refused: \{error.message()}"
          }
        other =>
          raise problem("\{shape}: its entry says the codec \"\{other}\"")
      }
    }
    other => raise problem("\{shape}: its entry names the kind \"\{other}\"")
  }
}

///|
test "every hand-patched file is refused as its entry says, by variant and by text, or answers as it says" {
  let index = fixture_json(".github/fixtures/iceberg/reference/index.json")
  let patched = jarray(field(index, "patched"))
  // Every file under the directory belongs to an entry: a shape the
  // generator wrote but did not index cannot go unchecked.
  let listed : Array[String] = []
  for entry in patched {
    listed.push(jstring(field(entry, "file")))
    match loose_field(entry, "list") {
      Null => ()
      beside => listed.push(jstring(beside))
    }
  }
  for name in directory(".github/fixtures/iceberg/reference/patched") {
    if !listed.contains("patched/\{name}") {
      fail(
        ".github/fixtures/iceberg/reference/patched/\{name} is not in the index the generator wrote",
      )
    }
  }
  let differences : Array[String] = []
  let mut refused = 0
  let mut answered = 0
  let mut unsupported = 0
  for entry in patched {
    if check_patched(entry) != "" {
      differences.push(check_patched(entry))
    }
    if jstring(field(entry, "codec")) == "refuses" {
      refused += 1
      if jstring(field(field(entry, "refusal"), "variant")) == "Unsupported" {
        unsupported += 1
      }
    } else {
      answered += 1
    }
  }
  for difference in differences {
    println("DIFFERENCE \{difference}")
  }
  if differences.length() != 0 {
    fail(
      "\{differences.length()} of the \{patched.length()} patched files differ from their entries",
    )
  }
  if refused < 150 || answered < 25 {
    fail("only \{refused} patched files are refused and \{answered} answered")
  }
  println(
    "patched files: \{patched.length()}; refused as their entries say: \{refused} (\{unsupported} of them Unsupported); answered as their entries say: \{answered}",
  )
}
