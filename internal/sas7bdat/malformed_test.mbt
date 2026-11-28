// Blackbox malformed-input sweep. Two valid files — a data set from the
// corpus and the 32-bit reference table — are truncated at every length;
// they and a BINARY-compressed table have one byte replaced in 200 copies
// each; then 200 random byte strings. No call may abort, and none may
// raise anything but `DataError`. A cut never reads back: the page length
// must divide what follows the header, and the pages must hold the rows
// the header declares. A replacement may read back — the format has no
// checksum, so a changed cell byte is a different value — but then as a
// table with as many cells in every column as there are rows. A marker
// line precedes each case and the summary is each test's last line. The
// seeds are named below, and the generator is written out, so the inputs
// are the same on every run and every target.

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
/// The replacement sweep's seed.
const SEED_REPLACEMENT : UInt64 = 0x5341533742444136UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x5341533742444137UL

///|
/// What one call answered: `None` when it raised `DataError`, `Some` with
/// the table otherwise. A trap ends the process before the summary.
fn read_outcome(bytes : Bytes) -> (Array[(String, @series.Series)], Int32)? {
  let outcome : Result[_, @types.DataError] = Ok(read_sas7bdat_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(table) => Some(table)
    Err(_) => None
  }
}

///|
/// That a table read back is well formed: at least one column, and as
/// many cells in every column as there are rows.
fn well_formed(
  columns : Array[(String, @series.Series)],
  height : Int32,
) -> Bool {
  if height < 0 || columns.is_empty() {
    false
  } else {
    let mut ok = true
    for _, (_name, series) in columns {
      if series.len() != height {
        ok = false
      }
    }
    ok
  }
}

///|
test "every truncation of two valid files raises DataError, and nothing aborts" {
  let files : ReadOnlyArray[String] = ["cars", "w32_pyrs"]
  let mut cases_all = 0
  let mut raised_all = 0
  let mut read_all = 0
  for label in files {
    let whole = fixture(".github/fixtures/sas7bdat/reference/\{label}.sas7bdat")
    // The file is valid, and nothing shorter than it can be: a cut leaves
    // bytes after the header that are not a whole number of pages, or
    // pages holding fewer rows than the header declares.
    let outcome = read_outcome(whole)
    if !(outcome is Some(_)) {
      fail("\{label}.sas7bdat does not read back whole")
    }
    let mut raised = 0
    let mut read_back = 0
    for length in 0..<whole.length() {
      println("truncation case \{label} \{length}")
      match read_outcome(cut_to(whole, length)) {
        None => raised += 1
        Some((columns, height)) => {
          if !well_formed(columns, height) {
            fail(
              "\{label}.sas7bdat cut to \{length} bytes read back as a malformed table",
            )
          }
          println(
            "truncation \{label}: the cut at byte \{length} reads back as a table of \{height} rows and \{columns.length()} columns",
          )
          read_back += 1
        }
      }
    }
    if read_back != 0 {
      fail(
        "\{read_back} truncations of \{label}.sas7bdat read back, where the page arithmetic forbids any",
      )
    }
    cases_all += whole.length()
    raised_all += raised
    read_all += read_back
    println(
      "truncations \{label}: \{whole.length()} cases, \{raised} raised DataError, \{read_back} read back, 0 aborted; DONE",
    )
  }
  println(
    "truncations total: \{cases_all} cases, \{raised_all} raised DataError, \{read_all} read back, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of each valid file never abort, and whatever reads back is well formed" {
  let files : ReadOnlyArray[String] = ["cars", "w32_pyrs", "rdc32_pyrs"]
  let total = 600
  let mut raised_all = 0
  let mut read_all = 0
  let mut same_all = 0
  for label in files {
    let whole = fixture(".github/fixtures/sas7bdat/reference/\{label}.sas7bdat")
    let (columns, height) = read_sas7bdat_frame(whole)
    let rng = SplitMix::{ state: SEED_REPLACEMENT, }
    let mut raised = 0
    let mut read_back = 0
    let mut same = 0
    for case in 0..<200 {
      println("replacement case \{label} \{case}")
      let at = (rng.next() % whole.length().to_uint64()).to_int()
      let mut value = ((rng.next() >> 8) & 0xFFUL).to_byte()
      if value == whole[at] {
        value = (value.to_int() ^ 0xFF).to_byte()
      }
      match read_outcome(replaced(whole, at, value)) {
        None => raised += 1
        Some((mutant, mutant_height)) => {
          if !well_formed(mutant, mutant_height) {
            fail(
              "\{label}: the replacement at byte \{at} read back as a malformed table",
            )
          }
          // Whether the table came back exactly as it was: the changed
          // byte then lies in a field the reader does not look at.
          let mut identical = mutant_height == height &&
            mutant.length() == columns.length()
          if identical {
            for i, (_name, series) in mutant {
              if !columns[i].1.equal(series) {
                identical = false
              }
            }
          }
          if identical {
            same += 1
          }
          read_back += 1
        }
      }
    }
    // Most bytes of a file lie in the padding of its pages, which the
    // reader does not look at; that some raised, or came back as another
    // table, shows the sweep is not vacuous. (In a file whose one page of
    // 65536 bytes holds a few compressed rows, two bytes in a hundred are
    // read at all.)
    if raised == 0 && read_back == same {
      fail("no replacement in \{label} raised or changed the table")
    }
    raised_all += raised
    read_all += read_back
    same_all += same
    println(
      "replacements \{label}: 200 cases, \{raised} raised DataError, \{read_back} read back (\{same} of them the very same table: the byte lies where the reader does not look), 0 aborted; DONE",
    )
  }
  if read_all == 0 {
    fail(
      "no replacement read back: the sweep would prove nothing about reading back",
    )
  }
  println(
    "replacements total: \{total} cases, \{raised_all} raised DataError, \{read_all} read back, \{same_all} the very same table, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements inside the bytes the reader reads never abort, and whatever reads back is well formed" {
  // The 32-bit reference table, and the places its map says the reader
  // reads: the header's fixed part, the page's header and pointers, every
  // subheader, and the rows. A page is mostly padding, so a replacement
  // anywhere in the file mostly lands where nothing looks; here every one
  // lands in a field.
  let whole = fixture(".github/fixtures/sas7bdat/reference/w32_pyrs.sas7bdat")
  let map = fixture_json(
    ".github/fixtures/sas7bdat/reference/w32_pyrs.map.json",
  )
  let page_at = jlong(field(map, "page_at")).to_int()
  let lead = jlong(field(map, "lead")).to_int()
  let pointer = jlong(field(map, "pointer")).to_int()
  let pointers = jarray(field(map, "pointers"))
  let hot : Array[Int32] = []
  for at in 0..<288 {
    hot.push(at)
  }
  let pointers_end = page_at + lead + 8 + pointer * pointers.length()
  for at in page_at..<pointers_end {
    hot.push(at)
  }
  for item in pointers {
    let length = jlong(field(item, "length")).to_int()
    let sub_at = jlong(field(item, "sub_at")).to_int()
    for at in sub_at..<(sub_at + length) {
      hot.push(at)
    }
  }
  let rows_at = jlong(field(map, "rows_at")).to_int()
  let rows = rows_at +
    jlong(field(map, "row_length")).to_int() *
    jlong(field(map, "row_count")).to_int()
  for at in rows_at..<rows {
    hot.push(at)
  }
  let (columns, height) = read_sas7bdat_frame(whole)
  let rng = SplitMix::{ state: SEED_REPLACEMENT ^ 0x484F5421UL, }
  let mut raised = 0
  let mut read_back = 0
  let mut same = 0
  for case in 0..<200 {
    println("hot replacement case \{case}")
    let at = hot[(rng.next() % hot.length().to_uint64()).to_int()]
    let mut value = ((rng.next() >> 8) & 0xFFUL).to_byte()
    if value == whole[at] {
      value = (value.to_int() ^ 0xFF).to_byte()
    }
    match read_outcome(replaced(whole, at, value)) {
      None => raised += 1
      Some((mutant, mutant_height)) => {
        if !well_formed(mutant, mutant_height) {
          fail("the replacement at byte \{at} read back as a malformed table")
        }
        let mut identical = mutant_height == height &&
          mutant.length() == columns.length()
        if identical {
          for i, (_name, series) in mutant {
            if !columns[i].1.equal(series) {
              identical = false
            }
          }
        }
        if identical {
          same += 1
        }
        read_back += 1
      }
    }
  }
  // A field the reader checks refuses; one it copies — a name's letters, a
  // cell's bytes — or never looks at — most of a subheader's own bytes —
  // reads back. That a good number raised shows the sweep is not vacuous.
  if raised < 15 || read_back < 100 {
    fail("\{raised} of the replacements raised and \{read_back} read back")
  }
  println(
    "replacements in the bytes the reader reads: \{hot.length()} bytes, 200 cases, \{raised} raised DataError, \{read_back} read back (\{same} of them the very same table), 0 aborted; DONE",
  )
}

///|
test "200 random byte strings raise DataError, and nothing aborts" {
  let rng = SplitMix::{ state: SEED_RANDOM, }
  for case in 0..<200 {
    println("random case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    let bytes = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    match read_outcome(bytes) {
      None => ()
      Some(_) =>
        fail(
          "random byte string \{case} (\{length} bytes) read back as a table",
        )
    }
  }
  println(
    "random strings: 200 cases, lengths 0 to 3000, all raised DataError; DONE",
  )
}

///|
test "the file's magic with random bytes behind it raises DataError, and nothing aborts" {
  // The 32 bytes every data set opens with, then noise: past the first
  // check, into the header's and the pages' arithmetic.
  let rng = SplitMix::{ state: SEED_RANDOM ^ 0x4D41474943UL, }
  let magic = cut_to(
    fixture(".github/fixtures/sas7bdat/reference/w32_pyrs.sas7bdat"),
    32,
  )
  let mut raised = 0
  for case in 0..<200 {
    println("magic case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    let noise = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    match read_outcome(magic + noise) {
      None => raised += 1
      Some(_) =>
        fail(
          "the magic with \{length} random bytes behind it read back as a table",
        )
    }
  }
  assert_eq(raised, 200)
  println("magic with noise: 200 cases, all raised DataError; DONE")
}
