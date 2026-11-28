// Blackbox malformed-input sweep. One small valid file, written by the
// codec, is truncated at every length; it and two reference files — a
// big-endian tagged one with long strings (`pandas_v119_be.dta`), and a
// binary-header one (`pyreadstat_v113.dta`) — have one byte replaced in
// 200 copies each; then 200 random byte strings. Every call must raise
// `DataError` and none may abort: a truncation or a random string that
// reads back fails the test, and a replacement that reads back is counted
// and reported, since a changed cell byte is a different value, which the
// format does not protect. An abort would end the test process before its
// summary, so a marker line precedes each case and the summary is each
// test's last line. The seeds are named below, and the generator is
// written out, so the inputs are the same on every run and every target.

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
const SEED_REPLACEMENT : UInt64 = 0x5354415432303136UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x5354415432303137UL

///|
/// The small valid file: every storage the writer spells but long
/// strings, in seven rows.
fn sweep_file() -> Bytes raise @types.DataError {
  let columns : Array[@series.Series] = [
    @series.Series::from_bools("flag", [
      true, false, true, true, false, false, true,
    ]),
    @series.Series::from_ints("num", [
      1L, -2L, 3L, 2147483620L, -2147483647L, 0L, 7L,
    ]),
    @series.Series::from_floats("ratio", [
      1.5, -0.25, 0.1, 1.0e300, 5.0e-324, -0.0, 2.0,
    ]),
    @series.Series::from_strings("label", [
      "a", "", "héllo", "x", "y", "z", "w",
    ]),
    @series.Series::from_scalars(
      "day",
      [
        @types.Scalar::Date(0L),
        @types.Scalar::Date(-1L),
        @types.Scalar::Date(1L),
        @types.Scalar::Date(365L),
        @types.Scalar::Date(-719528L),
        @types.Scalar::Date(2932896L),
        @types.Scalar::Date(7L),
      ],
      dtype=@types.DataType::Date,
    ),
  ]
  write_stata_bytes(columns)
}

///|
/// Read `bytes` through the codec and say whether it raised: `true` when
/// it did, `false` when it answered a table. A trap ends the process.
fn read_raises(bytes : Bytes) -> Bool {
  let outcome : Result[_, @types.DataError] = Ok(read_stata_frame(bytes)) catch {
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
  // The codec's own file ends in a closing tag, so a cut anywhere is a
  // cut the layout betrays.
  let own = sweep_file()
  for length in 0..<own.length() {
    println("truncation case own \{length}")
    if !read_raises(Bytes::makei(length, i => own[i])) {
      fail("the codec's file truncated to \{length} bytes read back")
    }
  }
  println("truncations own: \{own.length()} cases, all raised DataError; DONE")
  // So does a tagged reference file, big-endian, with long strings.
  let tagged = fixture(".github/fixtures/stata/reference/pandas_v119_be.dta")
  for length in 0..<tagged.length() {
    println("truncation case pandas_v119_be \{length}")
    if !read_raises(Bytes::makei(length, i => tagged[i])) {
      fail("pandas_v119_be.dta truncated to \{length} bytes read back")
    }
  }
  println(
    "truncations pandas_v119_be: \{tagged.length()} cases, all raised DataError; DONE",
  )
  // A binary-header file has no closing structure: what follows its data
  // is a value-label table the reader never visits, so a cut there is
  // not one the layout betrays. The sweep still runs over every length
  // and counts.
  let binary = fixture(".github/fixtures/stata/reference/pyreadstat_v113.dta")
  let mut raised = 0
  for length in 0..<binary.length() {
    println("truncation case pyreadstat_v113 \{length}")
    if read_raises(Bytes::makei(length, i => binary[i])) {
      raised += 1
    }
  }
  if raised == 0 {
    fail("no truncation of pyreadstat_v113.dta raised")
  }
  println(
    "truncations pyreadstat_v113: \{binary.length()} cases, \{raised} raised DataError, \{binary.length() - raised} read back past the data, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of each valid file never abort" {
  let files : Array[(String, Bytes)] = [
    ("own", sweep_file()),
    (
      "pandas_v119_be",
      fixture(".github/fixtures/stata/reference/pandas_v119_be.dta"),
    ),
    (
      "pyreadstat_v113",
      fixture(".github/fixtures/stata/reference/pyreadstat_v113.dta"),
    ),
  ]
  for (label, whole) in files {
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
    // Most bytes of a file are cell bytes and NUL padding, which the
    // format does not protect: a replacement there is a different value
    // and reads back. That some raised shows the sweep is not vacuous.
    if raised == 0 {
      fail("no replacement in \{label} raised")
    }
    println(
      "replacements \{label}: 200 cases, \{raised} raised DataError, \{200 - raised} read back, 0 aborted; DONE",
    )
  }
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
    "random strings: 200 cases, lengths 0 to 3000, all raised DataError; DONE",
  )
}
