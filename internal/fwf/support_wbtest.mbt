// The test support: a fixture and its sidecar read from under
// `.github/fixtures/fwf/reference/`, the sidecar's fields parsed back, a file's text
// split into the lines a reader hands the codec, the recipe that turns a
// reading's options into the lines the inference reads, an answer of the
// codec checked against one the reference gave, and the seeded generator
// the sweeps draw from. the generator beside them wrote the sidecars; every
// cell and boundary in them is the reference reader's own answer.

///|
/// What a call answered: a layout, or its refusal.
enum Outcome {
  Answered(FwfLayout)
  Refused(@types.DataError)
}

///|
/// A test's own failure, in the error type the codec raises.
fn problem(what : String) -> @types.DataError {
  @types.DataError::ParseError(@types.ParseErrorDetail::Message(what))
}

///|
/// A fixture file's text, which must be there: a missing fixture fails the
/// test it belongs to rather than skipping it.
fn fixture_text(path : String) -> String raise @types.DataError {
  @fs.read_file_to_string(path) catch {
    _ => raise problem("cannot read the fixture \{path}")
  }
}

///|
/// A fixture file parsed as JSON.
fn fixture_json(path : String) -> Json raise @types.DataError {
  let text = fixture_text(path)
  @json.parse(text) catch {
    _ => raise problem("the fixture \{path} is not JSON")
  }
}

///|
/// A JSON value's field, which must be there.
fn field(value : Json, name : String) -> Json raise @types.DataError {
  if value is Object(fields) {
    match fields.get(name) {
      Some(found) => found
      None => raise problem("the JSON carries no field \"\{name}\"")
    }
  } else {
    raise problem("the JSON value is not an object")
  }
}

///|
/// A JSON value that must be an array.
fn jarray(value : Json) -> Array[Json] raise @types.DataError {
  if value is Array(items) {
    items
  } else {
    raise problem("the JSON value is not an array")
  }
}

///|
/// A JSON value that must be a string.
fn jstring(value : Json) -> String raise @types.DataError {
  if value is String(text) {
    text
  } else {
    raise problem("the JSON value is not a string")
  }
}

///|
/// A JSON array of strings, as strings.
fn jstrings(value : Json) -> Array[String] raise @types.DataError {
  jarray(value).map(jstring)
}

///|
/// A JSON value that must be a whole number.
fn jint(value : Json) -> Int32 raise @types.DataError {
  if value is Number(number, ..) {
    number.to_int()
  } else {
    raise problem("the JSON value is not a number")
  }
}

///|
/// A file's text as the lines a reader hands the codec: a line ends at a
/// line feed, at a carriage return and line feed together, or at a
/// carriage return alone, and the terminator is not part of the line. A
/// final terminator ends the last line and starts no new one.
fn split_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  let units = text.code_units()
  let count = units.length()
  let mut from = 0
  let mut at = 0
  let mut after_cr = false
  while at < count {
    let unit = units[at].to_int()
    if after_cr && unit == 0x0A {
      // the line feed of a carriage return and line feed pair
      from = at + 1
      after_cr = false
      at += 1
      continue
    }
    after_cr = false
    if unit == 0x0D || unit == 0x0A {
      lines.push(text[from:at].to_owned())
      from = at + 1
      after_cr = unit == 0x0D
    }
    at += 1
  }
  if from < count {
    lines.push(text[from:].to_owned())
  }
  lines
}

///|
/// The text of `lines` as a file spells it, a line feed after each.
fn joined(lines : Array[String]) -> String {
  let out = StringBuilder()
  for line in lines {
    out.write_string(line)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// The part of `line` before its first `marker`; the whole line without one.
fn before_marker(line : String, marker : String) -> String {
  let mut cut = -1
  for i, ch in line.iter() {
    if ch.to_string() == marker {
      cut = i
      break
    }
  }
  if cut < 0 {
    line
  } else {
    String::from_iter(line.iter().take(cut))
  }
}

///|
/// The lines and the window a reading hands the inference: the lines its
/// `skiprows` does not name, each cut at its first comment character where
/// the reading has a marker, and its `infer_nrows`.
fn inference_lines(
  lines : Array[String],
  options : Json,
) -> (Array[String], Int32) raise @types.DataError {
  let skipped = match field(options, "skiprows") {
    Null => []
    named => jarray(named).map(jint)
  }
  let marker = match field(options, "comment") {
    Null => ""
    named => jstring(named)
  }
  let selected : Array[String] = []
  for i, line in lines {
    if skipped.contains(i) {
      continue
    }
    selected.push(if marker == "" { line } else { before_marker(line, marker) })
  }
  (selected, jint(field(options, "infer_nrows")))
}

///|
/// What a call answered: the layout, or its refusal.
fn attempt(make : () -> FwfLayout raise @types.DataError) -> Outcome {
  let outcome : Result[FwfLayout, @types.DataError] = Ok(make()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(layout) => Outcome::Answered(layout)
    Err(error) => Outcome::Refused(error)
  }
}

///|
/// A layout's boundaries as two arrays spelled alike for a comparison.
fn boundaries(layout : FwfLayout) -> String {
  let starts = layout.starts
  let ends = layout.ends
  let out = StringBuilder()
  for c in 0..<layout.len() {
    if c > 0 {
      out.write_char(' ')
    }
    out.write_string("(\{starts[c]}, \{ends[c]})")
  }
  out.to_string()
}

///|
/// The boundaries a sidecar spells, in the same form.
fn spelled_boundaries(colspecs : Array[Json]) -> String raise @types.DataError {
  let out = StringBuilder()
  for c, spec in colspecs {
    if c > 0 {
      out.write_char(' ')
    }
    let pair = jarray(spec)
    out.write_string("(\{jint(pair[0])}, \{jint(pair[1])})")
  }
  out.to_string()
}

///|
/// One line's cells as the sidecar spells them.
fn spelled_cells(value : Json) -> String raise @types.DataError {
  jarray(value).map(jstring).join(" | ")
}

///|
/// Where the codec's refusal of an inference differs from the reference's:
/// nothing when they say the same thing. The codec refuses with
/// `InvalidOperation`, its text beginning `fwf: `, for the fact the
/// reference names — no line to read, or lines with nothing but
/// separators, in which case how many lines were read and how long the
/// longest was. `selected` are the lines the inference read and `window`
/// its limit.
fn refusal_difference(
  place : String,
  error : @types.DataError,
  theirs : String,
  selected : Array[String],
  window : Int32,
) -> String {
  match error {
    InvalidOperation(detail) => {
      let count = if window < selected.length() {
        window
      } else {
        selected.length()
      }
      let mut longest = 0
      for line in selected {
        let length = line.iter().count()
        if length > longest {
          longest = length
        }
      }
      let wanted = if theirs.has_prefix("No rows from which to infer") {
        "fwf: no line to read a layout from"
      } else if theirs.has_prefix("No columns to parse from file") {
        "fwf: no field: \{count} lines read, the longest \{longest} characters, and every character a space, a tab, a carriage return or a line feed"
      } else {
        "<a refusal this test does not know: \{theirs}>"
      }
      if detail == wanted {
        ""
      } else {
        "\{place}: the codec refuses with \"\{detail}\"; the reference says \"\{theirs}\", which reads here as \"\{wanted}\""
      }
    }
    other =>
      "\{place}: the codec refuses with \{other.to_string()}, not InvalidOperation"
  }
}

///|
/// A line built by placing each cell at the first character of its field,
/// the field's characters before it filled with spaces: the line a writer
/// of left-aligned cells produces. The cells must fit their fields — each
/// is as long as its field at most, as a cut cell is.
fn put_cells(
  cells : Array[String],
  layout : FwfLayout,
) -> String raise @types.DataError {
  if cells.length() != layout.len() {
    raise problem(
      "\{cells.length()} cells for a layout of \{layout.len()} fields",
    )
  }
  let starts = layout.starts
  let ends = layout.ends
  let out = StringBuilder()
  let mut at = 0
  for c in 0..<cells.length() {
    let width = ends[c] - starts[c]
    let length = cells[c].iter().count()
    if length > width {
      raise problem(
        "the cell \"\{cells[c]}\" is \{length} characters in a field of \{width}",
      )
    }
    while at < starts[c] {
      out.write_char(' ')
      at += 1
    }
    out.write_string(cells[c])
    at += length
    while at < ends[c] {
      out.write_char(' ')
      at += 1
    }
  }
  out.to_string()
}

///|
/// `line` with the character at `at` — counted in characters — replaced by
/// `replacement`.
fn replace_char(line : String, at : Int32, replacement : String) -> String {
  let head = String::from_iter(line.iter().take(at))
  let tail = String::from_iter(line.iter().drop(at + 1))
  "\{head}\{replacement}\{tail}"
}

// ── the sweeps' generator ────────────────────────────────────────────

///|
/// A deterministic 64-bit generator (splitmix64), the generator the
/// fixture generator replays the sweeps with.
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
/// The replacement sweep's seed, as `sweep.json` spells it.
const SEED_REPLACEMENTS : UInt64 = 0x4657463230323631UL

///|
/// The random-text sweep's seed, as `sweep.json` spells it.
const SEED_RANDOM : UInt64 = 0x4657463230323632UL

///|
/// The seed of the sweep over random strings of code units, which no
/// file can hold and the reference is not asked about.
const SEED_UNITS : UInt64 = 0x4657463230323633UL

///|
/// How many ranges a random character of the random texts is drawn from.
const DRAWN_RANGE_COUNT : Int32 = 7

///|
/// Where a random character of the random texts is drawn: range `which` —
/// control characters (tab, line feed, vertical tab, form feed, carriage
/// return), ASCII, Latin-1, combining marks, Greek, CJK, and the second
/// plane — as its lowest code point and the one past its highest, the
/// table the fixture generator draws from.
fn drawn_range(which : Int32) -> (Int32, Int32) {
  match which {
    0 => (0x09, 0x0E)
    1 => (0x20, 0x7F)
    2 => (0xA0, 0x100)
    3 => (0x300, 0x370)
    4 => (0x370, 0x400)
    5 => (0x4E00, 0x9FA6)
    _ => (0x10000, 0x10400)
  }
}

///|
/// A character drawn as the fixture generator draws one: a range, then an
/// offset in it.
fn drawn_point(rng : SplitMix) -> Char {
  let which = (rng.next() % DRAWN_RANGE_COUNT.to_uint64()).to_int()
  let (low, high) = drawn_range(which)
  let offset = rng.next() % (high - low).to_uint64()
  (low.to_uint64() + offset).to_int().unsafe_to_char()
}

///|
/// A text drawn as the fixture generator draws one: `length` characters,
/// each by `drawn_point`.
fn drawn_text(rng : SplitMix, length : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<length {
    out.write_char(drawn_point(rng))
  }
  out.to_string()
}

///|
/// A string of `length` code units drawn from the whole range, surrogate
/// halves among them: a string a file cannot hold in UTF-8 and a reader
/// may still be handed.
fn drawn_units(rng : SplitMix, length : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<length {
    let unit = (rng.next() % 0x10000UL).to_uint16()
    out.write_char(unit.unsafe_to_char())
  }
  out.to_string()
}

///|
/// The seed as `sweep.json` spells it: sixteen lowercase hexadecimal
/// digits after `0x`.
fn spelled_seed(seed : UInt64) -> String {
  let digits = "0123456789abcdef".code_units()
  let out = StringBuilder()
  out.write_string("0x")
  for shift in [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0] {
    let digit = digits[(seed >> shift).to_int() & 15].to_int()
    out.write_char(digit.to_byte().to_char())
  }
  out.to_string()
}
