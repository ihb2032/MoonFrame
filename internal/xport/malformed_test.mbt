// Blackbox malformed-input sweep. One small valid file, written by the
// codec, is truncated at every length; it and two reference files have one
// byte replaced in 200 copies each; then 200 random byte strings. No call
// may abort, and none may raise anything but `DataError`. Whatever reads
// back must be a well-formed prefix of the table (a truncation) or the same
// shape with changed bytes (a replacement): the format holds no observation
// count and no checksum, so a cut that leaves the whole header is a valid
// file of no observation, and a changed cell byte is a different value. A
// marker line precedes each case and the summary is each test's last line.
// The seeds are named below, and the generator is written out, so the
// inputs are the same on every run and every target.

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
const SEED_REPLACEMENT : UInt64 = 0x5850545232303136UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x5850545232303137UL

///|
/// The small valid file: a `Bool`, an `Int`, a `Float`, a `Date` and a
/// `String` column in seven rows 45 bytes wide, so that five bytes of
/// blank padding end the file. Its observations start at byte 1440.
fn sweep_file() -> Bytes raise @types.DataError {
  write_xport_bytes([
    @series.Series::from_scalars(
      "flag",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Bool(false),
        @types.Scalar::Bool(true),
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_ints("num", [
      1L, -2L, 3L, 2147483620L, -2147483647L, 0L, 7L,
    ]),
    @series.Series::from_floats("ratio", [
      1.5, -0.25, 0.1, 1.0e75, 5.397605346934028e-79, 2.0, -7.5,
    ]),
    @series.Series::from_date_options("day", [
      Some(0L),
      Some(-1L),
      Some(1L),
      Some(365L),
      Some(-719528L),
      Some(2932896L),
      Some(7L),
    ]),
    @series.Series::from_string_options("label", [
      Some("a"),
      Some(""),
      Some("héllo wörld"),
      Some("x"),
      Some("y"),
      Some("z"),
      Some("w"),
    ]),
  ])
}

///|
/// What one call answered: `None` when it raised `DataError`, `Some` with
/// the table otherwise. A trap ends the process before the summary.
fn read_outcome(bytes : Bytes) -> (Array[(String, @series.Series)], Int32)? {
  let outcome : Result[_, @types.DataError] = Ok(read_xport_frame(bytes)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(table) => Some(table)
    Err(_) => None
  }
}

///|
/// `whole` with the byte at `at` replaced by `value`.
fn replaced(whole : Bytes, at : Int32, value : Byte) -> Bytes {
  Bytes::makei(whole.length(), i => if i == at { value } else { whole[i] })
}

///|
/// Whether `part` is a well-formed prefix of `whole`: as many columns, in
/// the same order, each with the same name and dtype and with its cells the
/// first cells of the whole's.
fn is_prefix(
  part : Array[(String, @series.Series)],
  whole : Array[(String, @series.Series)],
) -> Bool {
  if part.length() != whole.length() {
    return false
  }
  for i, (name, series) in part {
    let (whole_name, whole_series) = whole[i]
    if name != whole_name ||
      series.dtype() != whole_series.dtype() ||
      series.len() > whole_series.len() {
      return false
    }
    let cells = series.to_scalars()
    let whole_cells = whole_series.to_scalars()
    for row in 0..<cells.length() {
      if !cell_equal(cells[row], whole_cells[row]) {
        return false
      }
    }
  }
  true
}

///|
test "every truncation of a valid file raises DataError but the cut at the end of the header, and nothing aborts" {
  let own = sweep_file()
  // Five NAMESTRs of 140 bytes fill 720 bytes of records; the observation
  // header record follows; then seven rows of 45 bytes, padded to 320.
  let data_start = 1440
  assert_eq(own.length(), data_start + 320)
  let names : ReadOnlyArray[String] = ["flag", "num", "ratio", "day", "label"]
  let mut raised = 0
  let mut read_back = 0
  for length in 0..<own.length() {
    println("truncation case own \{length}")
    match read_outcome(cut_to(own, length)) {
      None => raised += 1
      Some((columns, height)) => {
        // The header complete and no observation is a well-formed file:
        // the same columns, with no cell.
        if length != data_start {
          fail("the codec's file cut to \{length} bytes read back")
        }
        if height != 0 || columns.length() != names.length() {
          fail(
            "the cut at \{length} read back as \{height} rows and \{columns.length()} columns",
          )
        }
        for i, (name, series) in columns {
          if name != names[i] || series.len() != 0 {
            fail(
              "the cut at \{length} reads column \{i + 1} as \"\{name}\", \{series.len()} cells",
            )
          }
        }
        read_back += 1
      }
    }
  }
  if read_back != 1 {
    fail(
      "\{read_back} truncations of the codec's file read back, not the one at the header's end",
    )
  }
  println(
    "truncations own: \{own.length()} cases, \{raised} raised DataError, \{read_back} read back as the well-formed file of no observation the header alone is (the cut at byte \{data_start}), 0 aborted; DONE",
  )
}

///|
test "every truncation of two reference files raises DataError or reads back as a well-formed prefix, and nothing aborts" {
  let files : ReadOnlyArray[(String, Int32)] = [
    ("plain_pyrs", 1000),
    ("text_pyrs", 1000),
  ]
  for (label, least) in files {
    let whole = fixture(".github/fixtures/xport/reference/\{label}.xpt")
    if whole.length() < least {
      fail(
        "\{label}.xpt is \{whole.length()} bytes, shorter than the sweep expects",
      )
    }
    let (columns, _) = read_xport_frame(whole)
    let mut raised = 0
    let mut read_back = 0
    let mut rows = 0
    for length in 0..<whole.length() {
      println("truncation case \{label} \{length}")
      match read_outcome(cut_to(whole, length)) {
        None => raised += 1
        Some((part, height)) => {
          if !is_prefix(part, columns) {
            fail(
              "\{label}.xpt cut to \{length} bytes read back as something that is not a prefix of the table",
            )
          }
          read_back += 1
          rows += height
          println(
            "truncation \{label}: the cut at byte \{length} reads back as the table's first \{height} rows",
          )
        }
      }
    }
    if read_back == 0 {
      fail(
        "no truncation of \{label}.xpt read back, where the cut at its header's end must",
      )
    }
    println(
      "truncations \{label}: \{whole.length()} cases, \{raised} raised DataError, \{read_back} read back as a well-formed prefix (\{rows} rows in all), 0 aborted; DONE",
    )
  }
}

///|
test "200 single-byte replacements of each valid file never abort, and whatever reads back has the same shape" {
  let files : ReadOnlyArray[(String, Bytes)] = [
    ("own", sweep_file()),
    ("plain_pyrs", fixture(".github/fixtures/xport/reference/plain_pyrs.xpt")),
    ("text_pyrs", fixture(".github/fixtures/xport/reference/text_pyrs.xpt")),
  ]
  let total = 600
  let mut raised_all = 0
  let mut read_all = 0
  let mut same_all = 0
  for (label, whole) in files {
    let (columns, height) = read_xport_frame(whole)
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
          // The same shape: as many columns, each with as many cells as
          // there are rows. A replacement in a NAMESTR may retype a
          // column or rename it; one in the data is a changed cell.
          if mutant.length() != columns.length() {
            fail(
              "\{label}: the replacement at byte \{at} read back with \{mutant.length()} columns, not \{columns.length()}",
            )
          }
          for _, (_, series) in mutant {
            if series.len() != mutant_height {
              fail(
                "\{label}: the replacement at byte \{at} read back a column of \{series.len()} cells in \{mutant_height} rows",
              )
            }
          }
          // Whether the table came back exactly as it was: the changed
          // byte then lies in a field the reader does not look at.
          let mut identical = mutant_height == height
          for i, (name, series) in mutant {
            if columns[i].0 != name || !columns[i].1.equal(series) {
              identical = false
            }
          }
          if identical {
            same += 1
          }
          read_back += 1
        }
      }
    }
    // Most bytes of a file are cell bytes, which the format does not
    // protect: a replacement there is a different value and reads back.
    // That some raised shows the sweep is not vacuous.
    if raised == 0 {
      fail("no replacement in \{label} raised")
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
