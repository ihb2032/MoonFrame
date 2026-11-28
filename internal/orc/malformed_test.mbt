// Blackbox malformed-input sweep. One small valid file under each
// compression kind — none, zlib, snappy, lz4 and zstd, all written by the
// reference writer — is truncated at every length; each has one byte
// replaced in 200 copies; then random byte strings. No call may abort,
// and no call may raise anything but `DataError`: a truncation or a
// random string that reads back fails the test, and a replacement that
// reads back is counted and reported, since the format has no checksum
// and a changed byte of a cell is a different value. An abort would end
// the test process before its summary, so a marker line precedes each
// case and the summary is each test's last line. The seeds are named
// below, and the generator is written out, so the inputs are the same on
// every run and every target.

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
const SEED_REPLACEMENT : UInt64 = 0x4F52433230323636UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x4F52433230323637UL

///|
/// One small valid file under each compression kind: its kind's name and
/// its file's name under `.github/fixtures/orc/reference/`.
fn small() -> Array[(String, String)] {
  [
    ("uncompressed", "pyorc_small_uncompressed.orc"),
    ("zlib", "pyorc_small_zlib.orc"),
    ("snappy", "pyorc_small_snappy.orc"),
    ("lz4", "pyorc_small_lz4.orc"),
    ("zstd", "pyorc_small_zstd.orc"),
  ]
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
/// Read `bytes` through the codec and say whether it refused: `true` when
/// it raised `DataError`, `false` when it answered a frame. An abort ends
/// the process.
fn refused(bytes : Bytes) -> Bool {
  let outcome : Result[_, @types.DataError] = Ok(read_orc_frame(bytes)) catch {
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
test "every truncation of a valid file under each compression kind raises DataError, and nothing aborts" {
  // The last byte names the PostScript's length, and the PostScript names
  // the footer's: a cut anywhere moves or shortens one of them, and the
  // tail the file has left does not hold together.
  let files = small()
  let mut cases = 0
  for (label, name) in files {
    let whole = fixture(".github/fixtures/orc/reference/\{name}")
    for length in 0..<whole.length() {
      println("truncation case \{label} \{length}")
      if !refused(cut(whole, length)) {
        fail("\{label}: the file truncated to \{length} bytes read back")
      }
    }
    cases += whole.length()
    println(
      "truncations \{label}: \{whole.length()} cases, all raised DataError, 0 aborted; DONE",
    )
  }
  println(
    "truncations total: \{cases} cases over \{files.length()} files, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of each valid file never abort" {
  let files = small()
  let mut raised_all = 0
  for (label, name) in files {
    let whole = fixture(".github/fixtures/orc/reference/\{name}")
    let rng = SplitMix::{ state: SEED_REPLACEMENT, }
    let mut raised = 0
    for case in 0..<200 {
      println("replacement case \{label} \{case}")
      let (at, value) = draw(rng, whole)
      if refused(replaced(whole, at, value)) {
        raised += 1
      }
    }
    // A byte of a cell, a name or a statistic the codec never reads is
    // free to change; the small files' streams are tiny, and most of
    // their blocks are stored as they are. That some raised shows the
    // sweep is not vacuous.
    if raised == 0 {
      fail("no replacement in \{label} raised")
    }
    println(
      "replacements \{label}: 200 cases, \{raised} raised DataError, \{200 - raised} read back, 0 aborted; DONE",
    )
    raised_all += raised
  }
  println(
    "replacements total: \{200 * files.length()} cases, \{raised_all} raised DataError, \{200 * files.length() - raised_all} read back, 0 aborted; DONE",
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
    if !refused(bytes) {
      fail("random byte string \{case} (\{length} bytes) read back as a frame")
    }
  }
  println(
    "random strings: 200 cases, lengths \{shortest} to \{longest}, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 random byte strings after the magic raise DataError, and nothing aborts" {
  // The head spells the format's magic, so the tail is what refuses them:
  // a sweep that reaches the PostScript, the footer and the counts.
  let rng = SplitMix::{ state: SEED_RANDOM + 1UL, }
  let mut shortest = 3003
  let mut longest = 3
  for case in 0..<200 {
    println("random-after-magic case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    if length + 3 < shortest {
      shortest = length + 3
    }
    if length + 3 > longest {
      longest = length + 3
    }
    let bytes = Bytes::makei(length + 3, i => {
      if i < 3 {
        b"ORC"[i]
      } else {
        (rng.next() & 0xFFUL).to_byte()
      }
    })
    if !refused(bytes) {
      fail(
        "random byte string \{case} after the magic (\{length + 3} bytes) read back as a frame",
      )
    }
  }
  println(
    "random strings after the magic: 200 cases, lengths \{shortest} to \{longest}, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "every replacement both readers open gives the same cells" {
  // The generator replays this sweep's cases through the reference reader
  // and records, for each copy, the cells it gave or its refusal: a copy
  // the codec reads back must hold what the reference reader read in it.
  // A copy one reader refuses and the other reads is counted, not
  // failed: the format has no checksum, and the two readers owe a damaged
  // file nothing but an answer.
  let sweep = fixture_json(".github/fixtures/orc/reference/sweep.json")
  let recorded = field(sweep, "files")
  let files = small()
  let mut both = 0
  let mut codec_only = 0
  let mut reference_only = 0
  let mut neither = 0
  let mut compared = 0
  for (label, name) in files {
    let whole = fixture(".github/fixtures/orc/reference/\{name}")
    let cases = jarray(field(recorded, name))
    if cases.length() != 200 {
      fail("\{label}: the sweep records \{cases.length()} cases, not 200")
    }
    let rng = SplitMix::{ state: SEED_REPLACEMENT, }
    let mut file_both = 0
    for case, spec in cases {
      let (at, value) = draw(rng, whole)
      // The generator's replay of the sweep draws the same replacement.
      if at != jint(field(spec, "at")) ||
        value.to_int() != jint(field(spec, "value")) {
        fail(
          "\{label}, case \{case}: the sweep replaces byte \{at} with \{value}, the generator's replay byte \{jint(field(spec, "at"))} with \{jint(field(spec, "value"))}",
        )
      }
      let outcome : Result[
        (Array[(String, @series.Series)], Int32),
        @types.DataError,
      ] = Ok(read_orc_frame(replaced(whole, at, value))) catch { e => Err(e) }
      let reference_opens = jbool(field(spec, "reference_opens"))
      match outcome {
        Ok((columns, _)) =>
          if reference_opens {
            compared += compare_cells(
              "\{label}, case \{case}",
              columns,
              jarray(field(spec, "cells")),
            )
            both += 1
            file_both += 1
          } else {
            codec_only += 1
            println(
              "the codec reads, the reference reader refuses: \{label}, case \{case}, byte \{at} to \{value}: \{jstring(field(spec, "reference_error"))}",
            )
          }
        Err(error) =>
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
      "replacement agreement \{label}: \{cases.length()} cases, \{file_both} opened by both readers; DONE",
    )
  }
  if both == 0 {
    fail("no replacement was opened by both readers")
  }
  println(
    "replacement agreement total: \{both + codec_only + reference_only + neither} cases, \{both} opened by both readers and \{compared} cells compared, none different; \{codec_only} opened by the codec alone; \{reference_only} opened by the reference reader alone; \{neither} refused by both; DONE",
  )
}
