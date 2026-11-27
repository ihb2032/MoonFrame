// Blackbox malformed-input sweep. One small valid file the reference
// writer wrote is truncated at every length; it, a bytecode-compressed
// file the reference writer wrote, and a zlib-compressed file the
// reference writer wrote each have one byte replaced in 200 copies; then
// 200 random byte strings. Every call must raise `DataError` and none
// may abort: a
// truncation or a random string that reads back fails the test, and a
// replacement that reads back is counted and reported, since a changed
// cell byte is a different value, which the format does not protect. An
// abort would end the test process before its summary, so a marker line
// precedes each case and the summary is each test's last line. The seeds
// are named below, and the generator is written out, so the inputs are
// the same on every run and every target.

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
const SEED_REPLACEMENT : UInt64 = 0x5350535332303236UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x5350535332303237UL

///|
/// Read `bytes` through the codec and say whether it raised: `true` when
/// it did, `false` when it answered a table. A trap ends the process.
fn read_raises(bytes : Bytes) -> Bool {
  let outcome : Result[_, @types.DataError] = Ok(read_spss_frame(bytes)) catch {
    e => Err(e)
  }
  outcome is Err(_)
}

///|
/// `whole` with the byte at `at` replaced by `value`.
fn replaced(whole : Bytes, at : Int32, value : Byte) -> Bytes {
  Bytes::makei(whole.length(), i => if i == at { value } else { whole[i] })
}

///|
test "every truncation of a valid file raises DataError, and nothing aborts" {
  // An uncompressed file declares its case count, so a cut anywhere —
  // in its dictionary, or in data it promised — is a cut the layout
  // betrays.
  let whole = fixture(".github/fixtures/spss/reference/pyrs_four_rows.sav")
  for length in 0..<whole.length() {
    println("truncation case pyrs_four_rows \{length}")
    if !read_raises(cut(whole, length)) {
      fail("pyrs_four_rows.sav truncated to \{length} bytes read back")
    }
  }
  println(
    "truncations pyrs_four_rows.sav: \{whole.length()} cases, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of each valid file never abort" {
  let files : Array[(String, String)] = [
    ("pyrs_four_rows.sav", ".github/fixtures/spss/reference/pyrs_four_rows.sav"),
    (
      "pyrs_extremes_rows.sav", ".github/fixtures/spss/reference/pyrs_extremes_rows.sav",
    ),
    ("pyrs_zsav.zsav", ".github/fixtures/spss/reference/pyrs_zsav.zsav"),
  ]
  let mut raised_all = 0
  let mut read_all = 0
  for (label, path) in files {
    let whole = fixture(path)
    let rng = SplitMix::{ state: SEED_REPLACEMENT, }
    let mut raised = 0
    for case in 0..<200 {
      println("replacement case \{label} \{case}")
      let at = (rng.next() % whole.length().to_uint64()).to_int()
      let mut value = ((rng.next() >> 8) & 0xFFUL).to_byte()
      if value == whole[at] {
        value = (value.to_int() ^ 0xFF).to_byte()
      }
      if read_raises(replaced(whole, at, value)) {
        raised += 1
      }
    }
    // Most bytes of these files are cell bytes, a product name, a label
    // or a creation date, which the cells do not depend on: a
    // replacement there reads back. That some raised shows the sweep is
    // not vacuous.
    if raised == 0 {
      fail("no replacement in \{label} raised")
    }
    println(
      "replacements \{label}: 200 cases, \{raised} raised DataError, \{200 - raised} read back, 0 aborted; DONE",
    )
    raised_all += raised
    read_all += 200 - raised
  }
  println(
    "replacements total: 600 cases, \{raised_all} raised DataError, \{read_all} read back, 0 aborted; DONE",
  )
}

///|
test "200 random byte strings raise DataError, and nothing aborts" {
  let rng = SplitMix::{ state: SEED_RANDOM, }
  for case in 0..<200 {
    println("random case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    let bytes = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    if !read_raises(bytes) {
      fail(
        "random byte string \{case} (\{length} bytes) read back as a dataset",
      )
    }
  }
  println(
    "random strings: 200 cases, lengths 0 to 3000, all raised DataError, 0 aborted; DONE",
  )
}
