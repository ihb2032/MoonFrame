// Blackbox tests over the reference files. Each ORC file under
// `.github/fixtures/orc/reference/` was written by the reference writer (the ORC
// writer of pyarrow), derived from one it wrote, built stream by stream
// to spell a shape no writer spells, or is an example file of the format's
// own repository. The JSON beside each holds the cells the reference
// reader itself got from it — as many views as the file has — and, where
// the codec refuses the file, the exact text of its refusal;
// the generator beside them wrote both.

///|
test "every reference file reads, view for view, as its sidecar spells it, or is refused as its sidecar says" {
  // The index lists what the generator wrote. It is read rather than a
  // count, so the test passes on any corpus the generator writes.
  let index = jarray(fixture_json(".github/fixtures/orc/reference/index.json"))
  // And every data file in the directory is one the index lists: a file
  // the generator did not write cannot go unchecked.
  let listed : Array[String] = index.map(entry => jstring(field(entry, "file")))
  let names : Result[ArrayView[String], Unit] = Ok(
    @fs.read_dir(".github/fixtures/orc/reference"),
  ) catch {
    _ => Err(())
  }
  let present = match names {
    Ok(found) => found
    Err(_) => fail("cannot list fixtures/reference")
  }
  for name in present {
    if name.has_suffix(".orc") && !listed.contains(name) {
      fail(
        ".github/fixtures/orc/reference/\{name} is not in the index the generator wrote",
      )
    }
  }
  let mut files = 0
  let mut compared = 0
  let mut refused = 0
  let mut views = 0
  let mut own = 0
  let mut projected = 0
  // The refusals that differ from their sidecars, all of them: the test
  // fails with the list, so one run tells everything that differs
  let differences : Array[String] = []
  for entry in index {
    let file = jstring(field(entry, "file"))
    let sidecar = fixture_json(".github/fixtures/orc/reference/\{file}.json")
    let bytes = fixture(".github/fixtures/orc/reference/\{file}")
    let unprojected : Result[
      (Array[(String, @series.Series)], Int32),
      @types.DataError,
    ] = Ok(read_orc_frame(bytes)) catch { e => Err(e) }
    let views_of = jarray(field(sidecar, "views"))
    match jstring(field(sidecar, "codec")) {
      "refuses" => {
        // The refusal is the sidecar's, to the letter: the variant, and
        // the text — the byte and the words — as the library renders it
        // for the reader: the variant's name, then what the codec said.
        let wanted = jstring(field(sidecar, "refusal"))
        let expected = if field(sidecar, "message") is String(text) {
          text
        } else {
          "<no text in the sidecar>"
        }
        let rendered = match wanted {
          "Unsupported" => "Unsupported: \{expected}"
          "ParseError" => "Parse error: \{expected}"
          other => fail("\{file}: its sidecar names the variant \{other}")
        }
        match unprojected {
          Ok(_) =>
            differences.push(
              "\{file} read as a table; its sidecar says the codec refuses it",
            )
          Err(error) => {
            // the text as the codec answered it, for the log
            println("refusal \{file} | \{error.message()}")
            if variant(error) != wanted || error.message() != rendered {
              differences.push(
                "\{file}: the codec refuses with \{error.message()}; its sidecar says \{rendered}",
              )
            }
          }
        }
        if !expected.has_prefix("orc: ") {
          differences.push(
            "\{file}: the refusal does not start with \"orc: \": \{expected}",
          )
        }
        refused += 1
      }
      "reads" => {
        let view = match views_of.get(0) {
          Some(first) if field(first, "projection") is Null => first
          _ => fail("\{file}: its sidecar holds no unprojected view")
        }
        compared += check_view(file, view, bytes)
        views += 1
      }
      other => fail("\{file}: its sidecar says the codec \"\{other}\"")
    }
    for view in views_of {
      if field(view, "projection") is Null {
        continue
      }
      compared += check_view(file, view, bytes)
      views += 1
      projected += 1
    }
    for view in views_of {
      if has_field(view, "source") &&
        jstring(field(view, "source")) == "generator" {
        own += 1
      }
    }
    files += 1
  }
  // A run over an empty or gutted directory cannot pass for the corpus
  // the generator wrote, which holds 175 files and 27,000 cells.
  if files < 160 || compared < 25000 {
    fail("only \{compared} cells were compared over \{files} files")
  }
  if refused < 100 {
    fail("only \{refused} files were refused as their sidecars say")
  }
  if !differences.is_empty() {
    fail(
      "\{differences.length()} refusals differ from their sidecars:\n\{differences.join("\n")}",
    )
  }
  println(
    "reference files: \{files}; views compared: \{views} (\{projected} of them projected); cells compared: \{compared}; files the codec refuses as their sidecars say: \{refused}; views whose cells are the generator's own: \{own}",
  )
}
