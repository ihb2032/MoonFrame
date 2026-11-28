// Blackbox tests over the reference files. Each package under
// `.github/fixtures/ods/reference/` was written by odfpy or by ezodf, has a
// content.xml the generator spelled by hand, or is a written package the
// generator broke in one place. The JSON beside each holds, for every
// sheet, the cells the reference reader itself got from the file — or the
// generator's own reading where the reference reader could not — and, where
// the codec refuses the file, the exact text of its refusal; the generator
// beside them wrote both.

///|
test "every indexed file reads, sheet for sheet, as its sidecar spells it, or is refused as its sidecar says" {
  // The index lists what the generator wrote. It is read rather than a
  // count, so the test passes on any corpus the generator writes.
  let index = jarray(fixture_json(".github/fixtures/ods/reference/index.json"))
  let listed : Array[String] = index.map(entry => jstring(field(entry, "file")))
  let found : Result[ArrayView[String], _] = Ok(
    @fs.read_dir(".github/fixtures/ods/reference"),
  ) catch {
    _ => Err(())
  }
  let present = match found {
    Ok(found) => found
    Err(_) => fail("cannot list fixtures/reference")
  }
  for name in present {
    if name != "index.json" &&
      !name.has_suffix(".json") &&
      !listed.contains(name) {
      fail(
        ".github/fixtures/ods/reference/\{name} is not in the index the generator wrote",
      )
    }
  }
  let mut files = 0
  let mut compared = 0
  let mut refusals = 0
  let mut own = 0
  // Everything that differs, so one run tells all of it.
  let differences : Array[String] = []
  for entry in index {
    let file = jstring(field(entry, "file"))
    let bytes = fixture(".github/fixtures/ods/reference/\{file}")
    let sidecar = fixture_json(".github/fixtures/ods/reference/\{file}.json")
    if jint(field(sidecar, "bytes")) != bytes.length() {
      differences.push(
        "\{file}: \{bytes.length()} bytes on disk, \{jint(field(sidecar, "bytes"))} in its sidecar",
      )
    }
    match jstring(field(sidecar, "codec")) {
      "refuses" => {
        // The refusal is the sidecar's, to the letter: the variant, and the
        // text as the library renders it for a caller. Both ways in raise it.
        let wanted = jstring(field(sidecar, "refusal"))
        let message = jstring(field(sidecar, "message"))
        let expected = rendered(wanted, message)
        if !message.has_prefix("ods: ") {
          differences.push(
            "\{file}: the refusal does not start with \"ods: \": \{message}",
          )
        }
        let by_sheets = refused_sheets(bytes)
        if variant(by_sheets) != wanted || by_sheets.message() != expected {
          differences.push(
            "\{file}: OdsBook::sheets refuses with \{variant(by_sheets)} \{by_sheets.message()}; its sidecar says \{wanted} \{expected}",
          )
        }
        let by_grid = refused(bytes)
        if variant(by_grid) != wanted || by_grid.message() != expected {
          differences.push(
            "\{file}: OdsBook::grid refuses with \{variant(by_grid)} \{by_grid.message()}; its sidecar says \{wanted} \{expected}",
          )
        }
        refusals += 1
      }
      "reads" => {
        let spec = jarray(field(sidecar, "sheets"))
        let wanted : Array[String] = spec.map(sheet => {
          jstring(field(sheet, "name"))
        })
        let named : Result[Array[String], @types.DataError] = Ok(
          sheet_names(bytes),
        ) catch {
          e => Err(e)
        }
        match named {
          Ok(names) =>
            if names != wanted {
              differences.push(
                "\{file}: OdsBook::sheets names [\{names.join(", ")}]; the sidecar [\{wanted.join(", ")}]",
              )
            }
          Err(error) =>
            differences.push(
              "\{file}: OdsBook::sheets refuses it (\{error.message()}); its sidecar says it reads",
            )
        }
        for i, sheet in spec {
          let name = jstring(field(sheet, "name"))
          if jstring(field(sheet, "source")) == "generator" {
            own += 1
          }
          let opened : Result[OdsGrid, @types.DataError] = Ok(
            sheet_grid(bytes, sheet=i.to_int()),
          ) catch {
            e => Err(e)
          }
          match opened {
            Ok(grid) => {
              let got = grid.cells()
              let want : Array[String] = []
              for cell in jarray(field(sheet, "cells")) {
                want.push(sidecar_cell(cell))
              }
              let spelled = got.map(cell_text)
              if spelled != want {
                differences.push(
                  "\{file}, sheet \"\{name}\": the codec's cells differ from the sidecar's\n      codec: \{spelled.join(" | ")}\n    sidecar: \{want.join(" | ")}",
                )
              }
              // Row after row, and column after column within a row.
              for k, cell in got {
                if cell.row() < 0 || cell.col() < 0 {
                  differences.push(
                    "\{file}, sheet \"\{name}\": a cell at \{cell.row()},\{cell.col()}",
                  )
                }
                if k > 0 {
                  let before = got[k - 1]
                  let ordered = cell.row() > before.row() ||
                    (cell.row() == before.row() && cell.col() > before.col())
                  if !ordered {
                    differences.push(
                      "\{file}, sheet \"\{name}\": cell \{k} at \{cell.row()},\{cell.col()} follows one at \{before.row()},\{before.col()}",
                    )
                  }
                }
              }
              // What a caller does with one answer leaves the grid as it was.
              got.clear()
              if grid.cells().length() != want.length() {
                differences.push(
                  "\{file}, sheet \"\{name}\": clearing one answer emptied the grid",
                )
              }
              compared += want.length()
            }
            Err(error) =>
              differences.push(
                "\{file}, sheet \"\{name}\": OdsBook::grid refuses it (\{error.message()})",
              )
          }
        }
      }
      other => fail("\{file}: its sidecar says the codec \"\{other}\"")
    }
    files += 1
  }
  // A run over a gutted directory cannot pass for the corpus the generator
  // wrote, which holds 54 files and 227 cells, 29 of the files refused.
  if files < 50 || compared < 200 {
    fail("only \{compared} cells were compared over \{files} files")
  }
  if refusals < 25 {
    fail("only \{refusals} files were refused as their sidecars say")
  }
  if !differences.is_empty() {
    fail("\{differences.length()} differences:\n\{differences.join("\n")}")
  }
  println(
    "reference files: \{files}; cells compared: \{compared}; files the codec refuses as their sidecars say: \{refusals}; sheets whose cells are the generator's own: \{own}",
  )
}

///|
test "OdsBook::grid answers the sheet asked for by position, and refuses a position there is no sheet at" {
  let two = fixture(".github/fixtures/ods/reference/odfpy_small.ods")
  let second = sheet_grid(two, sheet=1)
  assert_eq(second.cells().length(), 0)
  assert_eq(sheet_names(two), ["Small", "Nothing here"])
  assert_eq(sheet_grid(two).cells().length(), 11)
  assert_eq(sheet_grid(two, sheet=0).cells().length(), 11)
  for
    (position, text) in [
      (2, "ods: sheet 2 is out of range: the workbook holds 2 sheets"),
      (99, "ods: sheet 99 is out of range: the workbook holds 2 sheets"),
      (-1, "ods: sheet -1 is out of range: the workbook holds 2 sheets"),
    ] {
    let outcome : Result[OdsGrid, @types.DataError] = Ok(
      sheet_grid(two, sheet=position),
    ) catch {
      e => Err(e)
    }
    match outcome {
      Ok(_) => fail("sheet \{position} of a two-sheet workbook answered")
      Err(error) => {
        assert_eq(variant(error), "InvalidOperation")
        assert_eq(error.message(), "Invalid operation: \{text}")
      }
    }
  }
  let one = fixture(".github/fixtures/ods/reference/odfpy_bool_spelled.ods")
  let outcome : Result[OdsGrid, @types.DataError] = Ok(sheet_grid(one, sheet=1)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("sheet 1 of a one-sheet workbook answered")
    Err(error) =>
      assert_eq(
        error.message(),
        "Invalid operation: ods: sheet 1 is out of range: the workbook holds 1 sheet",
      )
  }
  let none = fixture(".github/fixtures/ods/reference/synthetic_no_sheets.ods")
  assert_eq(sheet_names(none), [])
  let outcome : Result[OdsGrid, @types.DataError] = Ok(sheet_grid(none)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("a workbook with no sheet answered sheet 0")
    Err(error) =>
      assert_eq(
        error.message(),
        "Invalid operation: ods: sheet 0 is out of range: the workbook holds 0 sheets",
      )
  }
}

///|
test "the same sheet asked for twice is the same cells, from a package of each writer" {
  for
    file in [
      ".github/fixtures/ods/reference/odfpy_values.ods", ".github/fixtures/ods/reference/ezodf_values.ods",
      ".github/fixtures/ods/reference/synthetic_utf16be.ods", ".github/fixtures/ods/reference/synthetic_prefixed.ods",
    ] {
    let bytes = fixture(file)
    let once = sheet_grid(bytes).cells().map(cell_text)
    let twice = sheet_grid(bytes, sheet=0).cells().map(cell_text)
    assert_eq(once, twice)
    if once.is_empty() {
      fail("\{file}: no cell read")
    }
  }
}
