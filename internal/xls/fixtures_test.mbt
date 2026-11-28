// Blackbox tests over the reference files. Each workbook under
// `.github/fixtures/xls/reference/` was written by the reference writer, built record
// by record with the generator's encoder, or is broken in one place. The
// JSON beside each holds what the reference reader itself got from it —
// its sheets, its date mode, and every cell that is not empty — or, for a
// broken file, the variant and the text of the refusal the codec owes it;
// the generator beside them wrote both.

///|
/// One sheet of one reference file read through the codec and checked
/// against its sidecar: the sheet's name, the date mode, and every cell.
/// A cell the sidecar marks as blank is one the codec answers nowhere.
/// Answers how many cells it compared.
fn check_grid(
  file : String,
  bytes : Bytes,
  sheet : Int32,
  spec : Json,
  sidecar : Json,
) -> Int32 raise @types.DataError {
  let grid = sheet_grid(bytes, sheet~)
  let name = jstring(field(spec, "sheet"))
  if sheet_names(bytes)[sheet] != name {
    raise problem(
      "\{file}, sheet \{sheet}: the codec names the sheet \{sheet_names(bytes)[sheet]}, the sidecar \{name}",
    )
  }
  let dated = jint(field(sidecar, "datemode")) == 1
  if grid.date_1904() != dated {
    raise problem(
      "\{file}, sheet \{sheet}: the codec's date mode is \{grid.date_1904()}, the sidecar's \{dated}",
    )
  }
  let wants = jarray(field(spec, "cells")).map(want_of)
  let cells = grid.cells()
  let kept = wants.filter(w => !w.blank)
  if cells.length() != kept.length() {
    raise problem(
      "\{file}, sheet \{name}: the codec answers \{cells.length()} cells, the sidecar \{kept.length()}",
    )
  }
  for want in wants {
    if want.blank {
      let mut found = false
      for cell in cells {
        if cell.row() == want.row && cell.col() == want.col {
          found = true
        }
      }
      if found {
        raise problem(
          "\{file}, sheet \{name}: the codec answers a cell at (\{want.row}, \{want.col}), which the sidecar marks as blank",
        )
      }
    }
  }
  for i, cell in cells {
    let want = kept[i]
    if cell.row() != want.row || cell.col() != want.col {
      raise problem(
        "\{file}, sheet \{name}, cell \{i}: the codec places it at (\{cell.row()}, \{cell.col()}), the sidecar at (\{want.row}, \{want.col})",
      )
    }
    let value = cell.value()
    if !agreed(value, want) {
      raise problem(
        "\{file}, sheet \{name}, cell (\{want.row}, \{want.col}): the codec read \{spelled(value)}; the sidecar [\"\{want.kind}\", \{want.row}, \{want.col}, \"\{want.text.escape()}\", \{want.key}, \"\{want.code.escape()}\"]",
      )
    }
    if want.kind == "N" && want.ctype != 0 {
      // A cell the reference reader calls a date never carries a built-in
      // format the library reads a plain number by, and one it calls a
      // number never carries a built-in date or time id; what a custom
      // code means is the library's to read off its letters.
      let builtin_date = match value {
        Number(_, Builtin(id)) => date_builtin(id)
        _ => false
      }
      let custom = value is Number(_, Custom(_))
      if (want.ctype == 3 && !builtin_date && !custom) ||
        (want.ctype == 2 && builtin_date) {
        raise problem(
          "\{file}, sheet \{name}, cell (\{want.row}, \{want.col}): the reference reader's cell type is \{want.ctype}, and the codec's format is \{spelled(value)}",
        )
      }
    }
  }
  cells.length()
}

///|
test "every reference file reads, cell for cell, as its sidecar spells it, or is refused as its sidecar says" {
  // The index lists what the generator wrote; it is read rather than a
  // count, so any corpus the generator writes passes.
  let index = jarray(fixture_json(".github/fixtures/xls/reference/index.json"))
  let listed : Array[String] = index.map(entry => jstring(field(entry, "file")))
  // And every data file in the directory is one the index lists: a file
  // the generator did not write cannot go unchecked.
  let outcome : Result[ArrayView[String], Unit] = Ok(
    @fs.read_dir(".github/fixtures/xls/reference"),
  ) catch {
    _ => Err(())
  }
  let present = match outcome {
    Ok(names) => names
    Err(_) => fail("cannot list fixtures/reference")
  }
  for name in present {
    if name.has_suffix(".xls") && !listed.contains(name) {
      fail(
        ".github/fixtures/xls/reference/\{name} is not in the index the generator wrote",
      )
    }
  }
  let mut files = 0
  let mut compared = 0
  let mut refused = 0
  let mut below = 0
  let mut blanks = 0
  let mut written = 0
  let mut dated = 0
  // The differences from the sidecars, all of them: the test fails with
  // the list, so one run tells everything that differs.
  let differences : Array[String] = []
  for entry in index {
    let file = jstring(field(entry, "file"))
    if jstring(field(entry, "origin")) == "xlwt" {
      written += 1
    }
    let sidecar = fixture_json(".github/fixtures/xls/reference/\{file}.json")
    let bytes = fixture(".github/fixtures/xls/reference/\{file}")
    let names : Result[Array[String], @types.DataError] = Ok(sheet_names(bytes)) catch {
      e => Err(e)
    }
    let grids : Result[XlsGrid, @types.DataError] = Ok(sheet_grid(bytes)) catch {
      e => Err(e)
    }
    match jstring(field(sidecar, "codec")) {
      "refuses" => {
        match grids {
          Ok(_) =>
            differences.push(
              "\{file} read as a grid; its sidecar says the codec refuses it",
            )
          Err(e) => {
            let difference = refusal_difference(file, e, sidecar)
            if difference != "" {
              differences.push(difference)
            }
          }
        }
        // The workbook's sheet names meet the same refusal, unless the
        // fault lies below the workbook globals, in a sheet's records.
        match names {
          Err(e) => {
            let difference = refusal_difference(file, e, sidecar)
            if difference != "" {
              differences.push("the sheet names: " + difference)
            }
          }
          Ok(list) => if list.length() != 0 { below += 1 }
        }
        refused += 1
      }
      "reads" => {
        let list = match names {
          Ok(found) => found
          Err(e) =>
            fail("\{file}: the sheet names were refused: \{e.message()}")
        }
        let wanted : Array[String] = jarray(field(sidecar, "sheets")).map(
          jstring,
        )
        if list != wanted {
          differences.push(
            "\{file}: the codec lists the sheets \{list.join(", ")}, the sidecar \{wanted.join(", ")}",
          )
        }
        let count = wanted.length()
        for position in jarray(field(sidecar, "out_of_range")).map(jint) {
          let asked : Result[XlsGrid, @types.DataError] = Ok(
            sheet_grid(bytes, sheet=position),
          ) catch {
            e => Err(e)
          }
          match asked {
            Ok(_) =>
              differences.push("\{file}: sheet \{position} read as a grid")
            Err(e) =>
              if variant(e) != "InvalidOperation" ||
                detail(e) !=
                "xls: sheet \{position}: the workbook holds \{count} sheets" {
                differences.push(
                  "\{file}, sheet \{position}: the codec refuses with \{e.message()}",
                )
              }
          }
        }
        let specs = jarray(field(sidecar, "grids"))
        if specs.length() != count {
          differences.push(
            "\{file}: the sidecar holds \{specs.length()} sheets' cells for \{count} sheets",
          )
        }
        for k, spec in specs {
          compared += check_grid(file, bytes, k, spec, sidecar)
          blanks += jarray(field(spec, "cells"))
            .filter(cell => {
              let parts = jarray(cell)
              parts.length() > 4 && parts[4] is String(mark) && mark == "blank"
            })
            .length()
          dated += jarray(field(spec, "cells"))
            .filter(cell => {
              let parts = jarray(cell)
              parts[0] is String(kind) &&
              kind == "N" &&
              parts.length() > 6 &&
              jint(parts[6]) == 3
            })
            .length()
        }
      }
      other =>
        differences.push("\{file}: its sidecar says the codec \"\{other}\"")
    }
    files += 1
  }
  // A run over an empty or gutted directory cannot pass for the corpus
  // the generator wrote, which holds 143 files, 109 of them refused, and
  // 1,554 cells — 1,549 compared, five left out by blank formulas.
  if files < 143 || compared < 1549 || refused < 109 || blanks < 5 {
    fail(
      "only \{compared} cells were compared over \{files} files, \{refused} of them refused, \{blanks} left out",
    )
  }
  if !differences.is_empty() {
    fail(
      "\{differences.length()} differences from the sidecars:\n\{differences.join("\n")}",
    )
  }
  println(
    "reference files: \{files} (\{written} the reference writer's); cells compared: \{compared}; cells the reference reader calls dates: \{dated}; cells a blank formula leaves out: \{blanks}; files the codec refuses as their sidecars say, by variant and exact text: \{refused} (\{below} of them faults below the workbook globals, their sheet names answering)",
  )
}

///|
test "a sheet's grid answers its date mode and a copy of its cells, and the workbook its sheets' names" {
  let bytes = fixture(".github/fixtures/xls/reference/xlwt_dates_1904.xls")
  let first = sheet_grid(bytes)
  assert_eq(sheet_names(bytes), ["dates"])
  assert_eq(first.date_1904(), true)
  // A caller's mutation of the cells it was handed does not reach the
  // grid: the array is the grid's own.
  let held = first.cells()
  let count = held.length()
  held.clear()
  assert_eq(first.cells().length(), count)
  // The workbook's sheets, in workbook order, hidden ones included.
  let sheets = sheet_names(
    fixture(".github/fixtures/xls/reference/xlwt_sheets.xls"),
  )
  assert_eq(
    sheets.join("|"),
    "Zebra|Hidden sheet|日本語のシート|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|Empty",
  )
  // An empty sheet answers no cell.
  let empty = sheet_grid(
    fixture(".github/fixtures/xls/reference/xlwt_sheets.xls"),
    sheet=4,
  )
  assert_eq(empty.cells().length(), 0)
  assert_eq(empty.date_1904(), false)
}

///|
test "a sheet out of range is refused by variant and exact text, naming the position and the count" {
  let bytes = fixture(".github/fixtures/xls/reference/syn_sheet_kinds.xls")
  for position in [4, 5, 100, -1, -5] {
    let asked : Result[XlsGrid, @types.DataError] = Ok(
      sheet_grid(bytes, sheet=position),
    ) catch {
      e => Err(e)
    }
    match asked {
      Ok(_) => fail("sheet \{position} read as a grid")
      Err(e) => {
        assert_eq(variant(e), "InvalidOperation")
        assert_eq(
          e.message(),
          "Invalid operation: xls: sheet \{position}: the workbook holds 4 sheets",
        )
        assert_eq(
          detail(e),
          "xls: sheet \{position}: the workbook holds 4 sheets",
        )
      }
    }
  }
  // A workbook of no sheet: the first sheet is out of range too.
  let none = fixture(".github/fixtures/xls/reference/syn_zero_sheets.xls")
  assert_eq(sheet_names(none).length(), 0)
  let asked : Result[XlsGrid, @types.DataError] = Ok(sheet_grid(none)) catch {
    e => Err(e)
  }
  match asked {
    Ok(_) => fail("a workbook of no sheet read as a grid")
    Err(e) => {
      assert_eq(variant(e), "InvalidOperation")
      assert_eq(
        e.message(),
        "Invalid operation: xls: sheet 0: the workbook holds 0 sheets",
      )
    }
  }
}
