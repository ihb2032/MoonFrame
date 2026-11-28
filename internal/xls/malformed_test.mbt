// Blackbox malformed-input sweep. Two small valid workbooks — one the
// reference writer wrote (`xlwt_small.xls`), one built by hand
// (`syn_tiny.xls`, its workbook in the mini stream) — are truncated at
// every length; each has one byte replaced in 200 copies; then random byte
// strings, bare and after the compound file's signature. A truncation or
// a random string that reads back fails the test. A replacement that reads
// back is held to the reference reader: the generator's `sweep` step
// replayed the same seeded draws through that reader and recorded, for
// every copy, the cells of its first sheet or its refusal, so a copy the
// codec still reads must hold what the reader read in it. The container's
// own faults — chains made to loop, a stream size past the file, a
// directory entry pointing outside, a mini stream without its root — are
// each asserted by variant and exact text. An abort would end the test
// process before its summary, so a marker line precedes each case and the
// summary is each test's last line. The seeds are named below, and the
// generator is written out, so the inputs are the same on every run and
// every target.

///|
/// A deterministic 64-bit generator (splitmix64).
struct SplitMix {
  mut state : UInt64
}

///|
/// The next number of the generator.
fn SplitMix::next(self : SplitMix) -> UInt64 {
  self.state += 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// The replacement sweep's seed: the bytes of "XLS2026".
const SEED_REPLACEMENT : UInt64 = 0x584C5332303236UL

///|
/// The random-string sweep's seed: the bytes of "XLS2027".
const SEED_RANDOM : UInt64 = 0x584C5332303237UL

///|
/// The sweep's files: its label and its name under `.github/fixtures/xls/reference/`.
fn swept() -> Array[(String, String)] {
  [("written", "xlwt_small.xls"), ("hand-built", "syn_tiny.xls")]
}

///|
/// `whole` cut to its first `length` bytes.
fn cut(whole : Bytes, length : Int32) -> Bytes {
  Bytes::makei(length, i => whole[i])
}

///|
/// `whole` with the byte at `at` replaced by `value`.
fn replaced(whole : Bytes, at : Int32, value : Byte) -> Bytes {
  Bytes::makei(whole.length(), i => if i == at { value } else { whole[i] })
}

///|
/// What the codec answers for `bytes`: the first sheet's grid, or its
/// refusal.
priv enum Answer {
  Grid(XlsGrid)
  Refused(@types.DataError)
}

///|
/// Read the first sheet of `bytes` through the codec. A trap ends the
/// process.
fn read_first(bytes : Bytes) -> Answer {
  let outcome : Result[XlsGrid, @types.DataError] = Ok(sheet_grid(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(grid) => Grid(grid)
    Err(e) => Refused(e)
  }
}

///|
/// The sweep's next replacement of `whole`: the offset and the value, as
/// `rng` draws them — never the byte that is already there.
fn draw(rng : SplitMix, whole : Bytes) -> (Int32, Byte) {
  let at = (rng.next() % whole.length().to_uint64()).to_int()
  let mut value = ((rng.next() >> 8) & 0xFFUL).to_byte()
  if value == whole[at] {
    value = (value.to_int() ^ 0xFF).to_byte()
  }
  (at, value)
}

///|
/// Whether the grid is what the reference reader got from the same bytes,
/// as `sweep.json` spells it: the date mode, and every cell of the sheet
/// the reader marked blank being absent and every other cell agreeing in
/// place, kind, value and format. Answers what differs, or nothing.
fn reads_as(grid : XlsGrid, spec : Json) -> String raise @types.DataError {
  let dated = has_field(spec, "datemode") && jint(field(spec, "datemode")) == 1
  if grid.date_1904() != dated {
    return "the codec's date mode is \{grid.date_1904()}, the reference reader's \{dated}"
  }
  let wants = jarray(field(spec, "cells")).map(want_of)
  let cells = grid.cells()
  let kept = wants.filter(w => !w.blank)
  if cells.length() != kept.length() {
    return "the codec answers \{cells.length()} cells, the reference reader \{kept.length()}"
  }
  for want in wants {
    if want.blank {
      for cell in cells {
        if cell.row() == want.row && cell.col() == want.col {
          return "the codec answers a cell at (\{want.row}, \{want.col}), which the reference reader marks blank"
        }
      }
    }
  }
  for i, cell in cells {
    let want = kept[i]
    if cell.row() != want.row || cell.col() != want.col {
      return "cell \{i}: the codec places it at (\{cell.row()}, \{cell.col()}), the reference reader at (\{want.row}, \{want.col})"
    }
    let value = cell.value()
    if !agreed(value, want) {
      return "cell (\{want.row}, \{want.col}): the codec read \{spelled(value)}; the reference reader [\"\{want.kind}\", \"\{want.text.escape()}\", \{want.key}, \"\{want.code.escape()}\"]"
    }
  }
  ""
}

///|
test "every truncation of a valid file raises DataError, and nothing aborts" {
  // A compound file's directory is its last sector, and the workbook
  // stream's last record is followed by nothing the reader needs: a cut
  // anywhere shortens the file past what its header and table still name.
  let mut cases = 0
  for (label, name) in swept() {
    let whole = fixture(".github/fixtures/xls/reference/\{name}")
    for length in 0..<whole.length() {
      println("truncation case \{label} \{length}")
      match read_first(cut(whole, length)) {
        Grid(_) =>
          fail("\{label}: the file truncated to \{length} bytes read back")
        Refused(_) => ()
      }
    }
    cases += whole.length()
    println(
      "truncations \{label} (\{name}): \{whole.length()} cases, all raised DataError, 0 aborted; DONE",
    )
  }
  println(
    "truncations total: \{cases} cases over \{swept().length()} files, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of each valid file never abort, and read back what the reference reader read" {
  // The generator replays this sweep's draws through the reference reader
  // and records, for each copy, the cells it got or its refusal: a copy
  // the codec reads back must hold what the reference reader read in it.
  // A copy one reader refuses and the other reads is counted, not failed:
  // the format has no checksum, and a reader owes a damaged file nothing
  // but an answer.
  let sweep = fixture_json(".github/fixtures/xls/reference/sweep.json")
  if jstring(field(sweep, "seed_replacement")) != "0x00584c5332303236" {
    fail("sweep.json was replayed with another seed than the test's")
  }
  let recorded = field(sweep, "files")
  let mut both = 0
  let mut codec_only = 0
  let mut reference_only = 0
  let mut neither = 0
  let mut compared = 0
  let mut all = 0
  // The differences, all of them: the test fails with the list.
  let differences : Array[String] = []
  for (label, name) in swept() {
    let whole = fixture(".github/fixtures/xls/reference/\{name}")
    let cases = jarray(field(recorded, name))
    if cases.length() != 200 {
      fail("\{label}: the sweep records \{cases.length()} cases, not 200")
    }
    let rng = SplitMix::{ state: SEED_REPLACEMENT, }
    let mut file_both = 0
    for case, spec in cases {
      println("replacement case \{label} \{case}")
      let (at, value) = draw(rng, whole)
      // The generator's replay of the sweep draws the same replacement.
      if at != jint(field(spec, "at")) ||
        value.to_int() != jint(field(spec, "value")) {
        fail(
          "\{label}, case \{case}: the sweep replaces byte \{at} with \{value}, the generator's replay byte \{jint(field(spec, "at"))} with \{jint(field(spec, "value"))}",
        )
      }
      all += 1
      let reference_opens = jbool(field(spec, "reference_opens"))
      match read_first(replaced(whole, at, value)) {
        Grid(grid) =>
          if reference_opens {
            let difference = reads_as(grid, spec)
            if difference != "" {
              differences.push(
                "\{label}, case \{case}, byte \{at} to \{value}: \{difference}",
              )
            }
            compared += jarray(field(spec, "cells")).length()
            both += 1
            file_both += 1
          } else {
            codec_only += 1
            println(
              "the codec reads, the reference reader refuses: \{label}, case \{case}, byte \{at} to \{value}: \{jstring(field(spec, "reference_error"))}",
            )
          }
        Refused(error) =>
          if reference_opens {
            reference_only += 1
            println(
              "the reference reader reads, the codec refuses: \{label}, case \{case}, byte \{at} to \{value}: \{error.message()}",
            )
          } else {
            neither += 1
          }
      }
    }
    println(
      "replacement agreement \{label} (\{name}): \{cases.length()} cases, \{file_both} opened by both readers and compared; DONE",
    )
  }
  if both == 0 {
    fail("no replacement was opened by both readers")
  }
  if !differences.is_empty() {
    fail(
      "\{differences.length()} replacements the codec and the reference reader read differently:\n\{differences.join("\n")}",
    )
  }
  println(
    "replacement agreement total: \{all} cases, \{both} opened by both readers and \{compared} cells compared, none different; \{codec_only} opened by the codec alone; \{reference_only} opened by the reference reader alone; \{neither} refused by both; 0 aborted; DONE",
  )
}

///|
test "200 random byte strings raise DataError, and nothing aborts" {
  let rng = SplitMix::{ state: SEED_RANDOM, }
  let mut shortest = 6000
  let mut longest = 0
  for case in 0..<200 {
    println("random case \{case}")
    let length = (rng.next() % 6001UL).to_int()
    if length < shortest {
      shortest = length
    }
    if length > longest {
      longest = length
    }
    let bytes = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    match read_first(bytes) {
      Grid(_) =>
        fail("random byte string \{case} (\{length} bytes) read back as a grid")
      Refused(_) => ()
    }
  }
  println(
    "random strings: 200 cases, lengths \{shortest} to \{longest}, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 random byte strings after the compound file's signature raise DataError, and nothing aborts" {
  // The head spells the container's signature, so what refuses them is
  // the reading of the header, the table and the stream that follow it: a
  // sweep that reaches past the first eight bytes.
  let rng = SplitMix::{ state: SEED_RANDOM + 1UL, }
  let signature = fixture(".github/fixtures/xls/reference/syn_tiny.xls")[0:8]
  let mut raised_by = 0
  for case in 0..<200 {
    println("random-after-signature case \{case}")
    let length = (rng.next() % 6001UL).to_int()
    let bytes = Bytes::makei(length + 8, i => {
      if i < 8 {
        signature[i]
      } else {
        (rng.next() & 0xFFUL).to_byte()
      }
    })
    match read_first(bytes) {
      Grid(_) =>
        fail(
          "random byte string \{case} after the signature (\{length + 8} bytes) read back as a grid",
        )
      Refused(error) => if variant(error) == "Unsupported" { raised_by += 1 }
    }
  }
  println(
    "random strings after the signature: 200 cases, all raised DataError (\{raised_by} of them by name), 0 aborted; DONE",
  )
}

///|
test "the container's own faults raise DataError by variant and exact text, and nothing aborts" {
  // Chains made to loop, a stream size past the file, a directory entry
  // pointing outside, a mini stream without its root: each file broken in
  // one place, its refusal written in its sidecar by the generator.
  let faults : Array[(String, Array[String])] = [
    (
      "chains made to loop",
      [
        "broken_stream_chain_loop.xls", "broken_directory_loop.xls", "broken_difat_loop.xls",
        "broken_root_chain_loop.xls", "broken_mini_chain_loop.xls",
      ],
    ),
    (
      "a stream size past the file",
      [
        "broken_stream_size_past.xls", "broken_root_size_past.xls", "broken_stream_size_negative.xls",
      ],
    ),
    (
      "a directory entry pointing outside",
      [
        "broken_stream_start_out.xls", "broken_stream_start_end.xls", "broken_directory_out.xls",
        "broken_directory_end.xls", "broken_root_start_out.xls", "broken_mini_sector_out.xls",
        "broken_mini_table_out.xls", "broken_fat_sector_out.xls",
      ],
    ),
    (
      "a mini stream without its root",
      [
        "broken_mini_no_root.xls", "broken_mini_table_missing.xls", "broken_mini_table_ends.xls",
      ],
    ),
  ]
  let mut cases = 0
  for (what, names) in faults {
    for name in names {
      println("container fault case \{name}")
      let bytes = fixture(".github/fixtures/xls/reference/\{name}")
      let sidecar = fixture_json(".github/fixtures/xls/reference/\{name}.json")
      // Both entries read the container first: the sheet names meet the
      // same refusal the grid does.
      let names_outcome : Result[Array[String], @types.DataError] = Ok(
        sheet_names(bytes),
      ) catch {
        e => Err(e)
      }
      match names_outcome {
        Ok(_) =>
          fail(
            "\{name}: the sheet names read; its sidecar says the codec refuses it",
          )
        Err(e) => {
          let difference = refusal_difference(name, e, sidecar)
          if difference != "" {
            fail("the sheet names: " + difference)
          }
        }
      }
      match read_first(bytes) {
        Grid(_) =>
          fail("\{name} read as a grid; its sidecar says the codec refuses it")
        Refused(e) => {
          let difference = refusal_difference(name, e, sidecar)
          if difference != "" {
            fail(difference)
          }
        }
      }
      cases += 1
    }
    println(
      "container fault, \{what}: \{names.length()} cases, each raised DataError by variant and exact text, 0 aborted; DONE",
    )
  }
  println(
    "container faults total: \{cases} cases, each raised DataError by variant and exact text, 0 aborted; DONE",
  )
}
