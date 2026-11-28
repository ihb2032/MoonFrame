// Whitebox tests over the reference files. Each text file under
// `.github/fixtures/fwf/reference/` was written by the generator beside them, family by
// family, from a table or line by line; the JSON beside each holds what the
// reference reader itself made of it — the boundaries it inferred, its
// reader's cut of every line, the cells of its tables — under one reading
// or more, and, where it refused, its refusal.

///|
/// What one run over the corpus counted.
struct Tally {
  mut files : Int32
  mut readings : Int32
  mut refusals : Int32
  mut cut : Int32
  mut rows : Int32
}

///|
test "every reference file: the inferred layout is the reference's boundary for boundary, or refused as its sidecar says, and every line cuts to the reference's cells" {
  // The index lists what the generator wrote. It is read rather than a
  // count, so the test passes on any corpus the generator writes.
  let index = jarray(fixture_json(".github/fixtures/fwf/reference/index.json"))
  // And every data file in the directory is one the index lists: a file
  // the generator did not write cannot go unchecked.
  let listed : Array[String] = index.map(entry => jstring(field(entry, "file")))
  let names : Result[ArrayView[String], Unit] = Ok(
    @fs.read_dir(".github/fixtures/fwf/reference"),
  ) catch {
    _ => Err(())
  }
  let present = match names {
    Ok(found) => found
    Err(_) => fail("cannot list fixtures/reference")
  }
  for name in present {
    if name.has_suffix(".txt") && !listed.contains(name) {
      fail(
        ".github/fixtures/fwf/reference/\{name} is not in the index the generator wrote",
      )
    }
  }
  let tally = Tally::{ files: 0, readings: 0, refusals: 0, cut: 0, rows: 0, }
  // Everything that differs, all of it: the test fails with the list, so
  // one run tells everything that differs.
  let differences : Array[String] = []
  for entry in index {
    let file = jstring(field(entry, "file"))
    let sidecar = fixture_json(".github/fixtures/fwf/reference/\{file}.json")
    // The lines as a reader hands them to the codec are the lines the
    // reference read: the splitting of the file is checked with the rest.
    let mine = split_lines(
      fixture_text(".github/fixtures/fwf/reference/\{file}"),
    )
    let lines = jstrings(field(sidecar, "lines"))
    if mine != lines {
      differences.push(
        "\{file}: the file splits into \{mine.length()} lines here, \{lines.length()} for the reference",
      )
    }
    for reading in jarray(field(sidecar, "readings")) {
      check_reading(file, lines, reading, tally, differences)
    }
    tally.files += 1
  }
  // A run over an empty or gutted directory cannot pass for the corpus
  // the generator wrote, which holds 30 files, 69 readings and 1,171 cells.
  if tally.files < 30 || tally.readings < 69 || tally.cut < 1171 {
    fail(
      "only \{tally.cut} cells were compared over \{tally.files} files and \{tally.readings} readings",
    )
  }
  if !differences.is_empty() {
    fail(
      "\{differences.length()} readings differ from their sidecars:\n\{differences.join("\n")}",
    )
  }
  println(
    "reference files: \{tally.files}; readings: \{tally.readings}; cells the reference cut, compared: \{tally.cut}; cells of its tables, compared: \{tally.rows}; readings the reference refuses, refused by the codec as their sidecars say: \{tally.refusals}",
  )
}

///|
/// One reading of one file against its sidecar. A `widths` reading is the
/// layout of its widths; any other is the inference over the lines its
/// options select. The reference's refusal of a reading is the codec's —
/// except under widths, where the reference refuses the *file* and the
/// widths still spell a layout, whose cut of every line is compared all
/// the same.
fn check_reading(
  file : String,
  lines : Array[String],
  reading : Json,
  tally : Tally,
  differences : Array[String],
) -> Unit raise @types.DataError {
  let name = jstring(field(reading, "name"))
  let options = field(reading, "options")
  let widths = field(reading, "widths")
  let (selected, window) = inference_lines(lines, options)
  let outcome = if widths is Null {
    attempt(() => fwf_infer_layout(selected, window))
  } else {
    attempt(() => fwf_layout_of_widths(jarray(widths).map(jint)))
  }
  let refuses = field(reading, "refuses")
  let refused = !(refuses is Null)
  tally.readings += 1
  match outcome {
    Refused(error) =>
      if !refused {
        differences.push(
          "\{file} / \{name}: the codec refuses — \{error.message()} — where the reference reads it",
        )
      } else if !(widths is Null) {
        differences.push(
          "\{file} / \{name}: the codec refuses — \{error.message()} — where the reference refuses the file only",
        )
      } else {
        tally.refusals += 1
        let difference = refusal_difference(
          "\{file} / \{name}",
          error,
          jstring(field(refuses, "message")),
          selected,
          window,
        )
        if difference != "" {
          differences.push(difference)
        }
      }
    Answered(layout) =>
      if refused && widths is Null {
        differences.push(
          "\{file} / \{name}: the codec answers \{boundaries(layout)} where the reference refuses: \{jstring(field(refuses, "message"))}",
        )
      } else {
        compare_layout(
          file, name, layout, lines, reading, options, refused, tally, differences,
        )
      }
  }
}

///|
/// A layout the codec answered against its sidecar: the boundaries, then
/// every line's cut, then — where the reference read the file — the rows of
/// its table, each the cut of the line it comes from unless a comment
/// marker is set, which the table applies to the fields and the cut does
/// not, and the shape of the default table the sidecar keeps for the
/// reader that types the cells. Under widths the reference may refuse the
/// file; its reader's cut of every line is recorded all the same.
fn compare_layout(
  file : String,
  name : String,
  layout : FwfLayout,
  lines : Array[String],
  reading : Json,
  options : Json,
  refused : Bool,
  tally : Tally,
  differences : Array[String],
) -> Unit raise @types.DataError {
  let colspecs = jarray(field(reading, "colspecs"))
  let mine = boundaries(layout)
  let wanted = spelled_boundaries(colspecs)
  if mine != wanted {
    differences.push(
      "\{file} / \{name}: the codec lays out \{mine}, the reference \{wanted}",
    )
  }
  let cut = jarray(field(reading, "cut"))
  if cut.length() != lines.length() {
    differences.push(
      "\{file} / \{name}: the sidecar cuts \{cut.length()} lines, the file has \{lines.length()}",
    )
  } else {
    for i, line in lines {
      let cells = fwf_cut(line, layout)
      let theirs = spelled_cells(cut[i])
      tally.cut += cells.length()
      if cells.join(" | ") != theirs {
        differences.push(
          "\{file} / \{name}, line \{i}: the codec cuts \"\{cells.join(" | ")}\", the reference \"\{theirs}\"",
        )
      }
    }
  }
  if refused {
    return
  }
  let row_lines = jarray(field(reading, "row_lines")).map(jint)
  let rows = jarray(field(reading, "rows"))
  if rows.length() != row_lines.length() {
    differences.push(
      "\{file} / \{name}: the sidecar has \{rows.length()} rows from \{row_lines.length()} lines",
    )
  } else if field(options, "comment") is Null {
    for i, line in row_lines {
      let cells = fwf_cut(lines[line], layout)
      tally.rows += cells.length()
      let theirs = spelled_cells(rows[i])
      if cells.join(" | ") != theirs {
        differences.push(
          "\{file} / \{name}, row \{i} (line \{line}): the codec cuts \"\{cells.join(" | ")}\", the reference's table \"\{theirs}\"",
        )
      }
    }
  }
  // The default table a user sees has a column a field, and a row a kept
  // line past the header.
  let table = field(reading, "table")
  let columns = jarray(field(table, "columns")).length()
  if columns != layout.len() {
    differences.push(
      "\{file} / \{name}: the sidecar's table has \{columns} columns for \{layout.len()} fields",
    )
  }
  let table_rows = jarray(field(table, "cells")).length()
  if table_rows != row_lines.length() - 1 {
    differences.push(
      "\{file} / \{name}: the sidecar's table has \{table_rows} rows, the reading keeps \{row_lines.length()} lines",
    )
  }
}

///|
test "every line of every reading, cut and put back into its fields, cuts again to the same cells" {
  // The property a writer of left-aligned cells rests on: a cell is never
  // wider than its field, and placed at the field's first character it is
  // cut out again unchanged.
  let index = jarray(fixture_json(".github/fixtures/fwf/reference/index.json"))
  let mut lines = 0
  let mut cells = 0
  for entry in index {
    let file = jstring(field(entry, "file"))
    let sidecar = fixture_json(".github/fixtures/fwf/reference/\{file}.json")
    let text = jstrings(field(sidecar, "lines"))
    for reading in jarray(field(sidecar, "readings")) {
      if !(field(reading, "refuses") is Null) &&
        field(reading, "widths") is Null {
        continue
      }
      let colspecs = jarray(field(reading, "colspecs"))
      let outcome = if field(reading, "widths") is Null {
        let (selected, window) = inference_lines(
          text,
          field(reading, "options"),
        )
        attempt(() => fwf_infer_layout(selected, window))
      } else {
        attempt(() => {
          fwf_layout_of_widths(jarray(field(reading, "widths")).map(jint))
        })
      }
      let layout = match outcome {
        Answered(layout) => layout
        Refused(error) => fail("\{file}: \{error.message()}")
      }
      assert_eq(layout.len(), colspecs.length())
      for line in text {
        let cut = fwf_cut(line, layout)
        assert_eq(fwf_cut(put_cells(cut, layout), layout), cut)
        lines += 1
        cells += cut.length()
      }
    }
  }
  println(
    "lines cut, put back and cut again: \{lines}; cells: \{cells}; all unchanged",
  )
}

///|
test "a line handed with its terminator infers and cuts as the line without it" {
  // A line feed, a carriage return and line feed, and a carriage return are
  // separators like the space and the tab: a caller that hands the
  // terminator in gets the layout and the cells of the line without it.
  // The boundaries are written out by hand: `id` is two characters, `100`
  // three, so the first field runs 0 to 3; `name` starts at 4 and `maple`
  // ends it at 9; `amount` at 10 and the header's six characters end it at
  // 16; `flag` runs 17 to 21, the header's four, though every cell is one.
  let wanted = "(0, 3) (4, 9) (10, 16) (17, 21)"
  let sidecar = fixture_json(
    ".github/fixtures/fwf/reference/grid_one_space.txt.json",
  )
  let plain = jstrings(field(sidecar, "lines"))
  let layout = fwf_infer_layout(plain, 100)
  assert_eq(boundaries(layout), wanted)
  assert_eq(fwf_cut(plain[1], layout), ["100", "maple", "15012", "Y"])
  for terminator in ["\n", "\r\n", "\r"] {
    let carried = plain.map(line => "\{line}\{terminator}")
    assert_eq(boundaries(fwf_infer_layout(carried, 100)), wanted)
    for i, line in carried {
      assert_eq(fwf_cut(line, layout), fwf_cut(plain[i], layout))
    }
  }
  // A terminator inside a line separates as well: the same layout as the
  // line with a space or a tab there.
  let with_space = ["id name\tamount flag", "100 oak 12\t34 Y"]
  let with_break = ["id\nname\tamount flag", "100 oak 12\r34 Y"]
  assert_eq(
    boundaries(fwf_infer_layout(with_break, 100)),
    boundaries(fwf_infer_layout(with_space, 100)),
  )
  assert_eq(fwf_cut("id\nname\tamount flag", fwf_layout_of_widths([8])), [
    "id\nname",
  ])
}
