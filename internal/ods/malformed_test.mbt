// Blackbox malformed-input sweep. One small valid workbook from each
// writer — odfpy's `odfpy_small.ods` and ezodf's `ezodf_grid.ods`, as the
// generator wrote them — is truncated at every length; each has one byte
// replaced in 200 copies; then random byte strings. No call may abort,
// and no call may raise anything but `DataError`. A truncation or a
// random string that reads back fails the test; a replacement that reads
// back is counted and reported, and must then answer the cells the whole
// file answers — the archive's checksums cover every entry, so a changed
// byte that still reads changed no entry. An abort would end the test
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
/// The replacement sweep's seed.
const SEED_REPLACEMENT : UInt64 = 0x4F44533230323636UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x4F44533230323637UL

///|
/// One small valid workbook from each writer: its writer and its file's
/// name under `.github/fixtures/ods/reference/`.
fn small() -> Array[(String, String)] {
  [("odfpy", "odfpy_small.ods"), ("ezodf", "ezodf_grid.ods")]
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
/// The cells of the first sheet `bytes` answers, each spelled; a refusal
/// is `<refused: …>` and no sheet at all is `<none>`.
fn answer(bytes : Bytes) -> String {
  let outcome : Result[OdsGrid, @types.DataError] = Ok(sheet_grid(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(grid) => grid.cells().map(cell_text).join(" | ")
    Err(error) => "<refused: \{error.message()}>"
  }
}

///|
/// Whether `bytes` is refused: `true` when reading it raised `DataError`.
/// An abort ends the process.
fn is_refused(bytes : Bytes) -> Bool {
  let outcome : Result[_, @types.DataError] = Ok(sheet_names(bytes)) catch {
    e => Err(e)
  }
  outcome is Err(_)
}

///|
/// The sweep's next replacement of `whole`: the offset and the value, as
/// `rng` draws them.
fn draw(rng : SplitMix, whole : Bytes) -> (Int32, Byte) {
  let at = (rng.next() % whole.length().to_uint64()).to_int()
  let mut value = ((rng.next() >> 8) & 0xFFUL).to_byte()
  if value == whole[at] {
    value = (value.to_int() ^ 0xFF).to_byte()
  }
  (at, value)
}

///|
test "every truncation of a valid workbook from each writer raises DataError, and nothing aborts" {
  // The archive's directory is its last record: a cut anywhere removes or
  // shortens it, and nothing is left to read the entries by.
  let files = small()
  let mut cases = 0
  for (writer, name) in files {
    let whole = fixture(".github/fixtures/ods/reference/\{name}")
    for length in 0..<whole.length() {
      println("truncation case \{writer} \{length}")
      if !is_refused(cut(whole, length)) {
        fail("\{writer}: the workbook truncated to \{length} bytes read back")
      }
    }
    cases += whole.length()
    println(
      "truncations \{writer}: \{whole.length()} cases, all raised DataError, 0 aborted; DONE",
    )
  }
  println(
    "truncations total: \{cases} cases over \{files.length()} workbooks, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of a valid workbook from each writer never abort, and never answer other cells" {
  let files = small()
  let mut raised_all = 0
  let mut total = 0
  let mut index = 0
  for (writer, name) in files {
    let whole = fixture(".github/fixtures/ods/reference/\{name}")
    let wanted = answer(whole)
    if wanted.has_prefix("<refused") || wanted.is_empty() {
      fail("\{writer}: the whole workbook does not answer cells")
    }
    let rng = SplitMix::{
      state: SEED_REPLACEMENT + index.to_int64().reinterpret_as_uint64(),
    }
    let mut raised = 0
    for case in 0..<200 {
      println("replacement case \{writer} \{case}")
      let (at, value) = draw(rng, whole)
      let copy = replaced(whole, at, value)
      let outcome : Result[OdsGrid, @types.DataError] = Ok(sheet_grid(copy)) catch {
        e => Err(e)
      }
      match outcome {
        Ok(grid) => {
          let got = grid.cells().map(cell_text).join(" | ")
          if got != wanted {
            fail(
              "\{writer}, case \{case}: byte \{at} to \{value} read back as \{got}; the whole file answers \{wanted}",
            )
          }
        }
        Err(_) => raised += 1
      }
    }
    // A byte of the archive's own bookkeeping is free to change; that
    // some raised shows the sweep is not vacuous.
    if raised == 0 {
      fail("no replacement in \{writer} raised")
    }
    println(
      "replacements \{writer}: 200 cases, \{raised} raised DataError, \{200 - raised} read back with the whole file's cells, 0 aborted; DONE",
    )
    raised_all += raised
    total += 200
    index += 1
  }
  println(
    "replacements total: \{total} cases, \{raised_all} raised DataError, \{total - raised_all} read back with the whole file's cells, 0 aborted; DONE",
  )
}

///|
test "200 random byte strings raise DataError, and nothing aborts" {
  let rng = SplitMix::{ state: SEED_RANDOM, }
  let mut shortest = 3000
  let mut longest = 0
  for case in 0..<200 {
    println("random case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    if length < shortest {
      shortest = length
    }
    if length > longest {
      longest = length
    }
    let bytes = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    if !is_refused(bytes) {
      fail("random byte string \{case} (\{length} bytes) read back")
    }
  }
  println(
    "random strings: 200 cases, lengths \{shortest} to \{longest}, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 byte strings after the archive's first bytes raise DataError, and nothing aborts" {
  // The head spells a local file header and the spreadsheet's mimetype,
  // so the tail is what refuses them: a sweep that reaches the directory.
  let rng = SplitMix::{ state: SEED_RANDOM + 1UL, }
  let head = Bytes::makei(84, i => {
    fixture(".github/fixtures/ods/reference/odfpy_small.ods")[i]
  })
  let mut shortest = 3000
  let mut longest = 0
  for case in 0..<200 {
    println("random-after-head case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    if length < shortest {
      shortest = length
    }
    if length > longest {
      longest = length
    }
    let tail = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    if !is_refused(head + tail) {
      fail(
        "random byte string \{case} after the archive's head (\{length + 84} bytes) read back",
      )
    }
  }
  println(
    "random strings after the head: 200 cases, lengths \{shortest + 84} to \{longest + 84}, all raised DataError, 0 aborted; DONE",
  )
}
