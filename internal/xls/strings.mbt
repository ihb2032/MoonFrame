// The strings the records carry — a character count, a flags byte, and
// the characters in one byte or two each — as the record holding the
// string and the CONTINUE records after it spell them. A string's
// characters may be cut by a record's end, and the record after the cut
// opens with a flags byte saying how its own stretch of them is spelled;
// its rich-text runs and its phonetic data may be cut as well, with no
// flags byte. Nothing of a string is decoded before the records have been
// shown to hold it.

///|
/// A string's bytes under a reading point: the record the string begins
/// in and every CONTINUE record after it, each a stretch the point moves
/// through.
priv struct Segments {
  stream : Bytes
  /// Where each record's body begins in the workbook stream.
  starts : Array[Int32]
  /// How many bytes each record's body holds.
  lengths : Array[Int32]
  /// The record the reading point is in.
  mut seg : Int32
  /// The reading point's offset in that record's body.
  mut pos : Int32
}

///|
/// The records carrying the string of the record `first`: its body and
/// the body of every CONTINUE record directly after it. Answers them, and
/// the byte of the stream past the last of those records.
fn segments(
  stream : Bytes,
  first : Record,
) -> (Segments, Int32) raise @types.DataError {
  let starts : Array[Int32] = [first.body()]
  let lengths : Array[Int32] = [first.len]
  let mut at = first.after()
  while at < stream.length() && u16_at(stream, at) == 0x003C {
    // 0x003C: CONTINUE.
    let next = record_at(stream, at)
    starts.push(next.body())
    lengths.push(next.len)
    at = next.after()
  }
  (Segments::{ stream, starts, lengths, seg: 0, pos: 0, }, at)
}

///|
/// The bytes left in the record under the reading point.
fn Segments::left(self : Segments) -> Int32 {
  self.lengths[self.seg] - self.pos
}

///|
/// The byte of the workbook stream at the reading point.
fn Segments::here(self : Segments) -> Int32 {
  self.starts[self.seg] + self.pos
}

///|
/// Move the reading point to the start of the next record, when the point
/// is at the end of the one it is in.
fn Segments::settle(self : Segments) -> Unit {
  while self.left() == 0 && self.seg + 1 < self.starts.length() {
    self.seg = self.seg + 1
    self.pos = 0
  }
}

///|
/// Whether the reading point is past the last byte of the last record.
fn Segments::exhausted(self : Segments) -> Bool {
  self.seg + 1 == self.starts.length() && self.left() == 0
}

///|
/// Move the reading point on to the next record when the one it is in is
/// read to its end, and refuse when no record is left. Raises
/// `ParseError`, naming the byte: the string ends inside its data.
fn Segments::step(
  self : Segments,
  what : String,
) -> Unit raise @types.DataError {
  self.settle()
  if self.exhausted() {
    raise bad(
      "byte \{self.here()} of the workbook stream: the \{what} ends inside its data",
    )
  }
}

///|
/// Refuse unless the record under the reading point holds `count` bytes
/// more, naming `part` of the string as what they belong to.
fn Segments::need(
  self : Segments,
  count : Int32,
  what : String,
  part : String,
) -> Unit raise @types.DataError {
  if self.left() < count {
    raise bad(
      "byte \{self.here()} of the workbook stream: the \{what} ends inside its \{part}",
    )
  }
}

///|
/// `count` bytes of the record under the reading point, which the caller
/// has shown it holds: the reading point moves past them, and their byte
/// in the stream is answered.
fn Segments::take(self : Segments, count : Int32) -> Int32 {
  let from = self.here()
  self.pos = self.pos + count
  from
}

///|
/// One string as the records spell it, read from the reading point of
/// `s` and left past it: its character count — `count_bytes` bytes wide
/// inside the string when that is not zero, and `count` otherwise, which
/// the record spells before the string — its flags byte, the count of its
/// rich-text runs and the size of its phonetic data where the flags name
/// them, its characters, and then those runs and that data, stepped over.
/// A stretch of characters the record cuts opens, in the record after it,
/// with a flags byte of its own, so one string may spell one stretch in
/// one byte a character and the next in two. `what` names the string, for
/// the refusals. Raises `ParseError`, naming the byte, for a header, a
/// character, a run or the phonetic data the records do not hold, and for
/// characters that are not well-formed UTF-16.
fn read_string(
  s : Segments,
  count_bytes : Int32,
  count : Int32,
  what : String,
) -> String raise @types.DataError {
  s.settle()
  let cch = if count_bytes == 2 {
    s.need(2, what, "character count")
    u16_at(s.stream, s.take(2))
  } else if count_bytes == 1 {
    s.need(1, what, "character count")
    s.stream[s.take(1)].to_int()
  } else {
    count
  }
  s.need(1, what, "flags")
  let flags = s.stream[s.take(1)].to_int()
  // The flags' bits: 0 — two bytes a character; 2 — phonetic data
  // follows; 3 — rich-text runs follow.
  let runs = if (flags & 8) != 0 {
    s.need(2, what, "rich-text run count")
    u16_at(s.stream, s.take(2))
  } else {
    0
  }
  let phonetic_at = s.here()
  let phonetic = if (flags & 4) != 0 {
    s.need(4, what, "phonetic data size")
    i32_at(s.stream, s.take(4))
  } else {
    0
  }
  if phonetic < 0 {
    raise bad(
      "byte \{phonetic_at} of the workbook stream: the \{what} claims \{phonetic} bytes of phonetic data",
    )
  }
  let mut wide = (flags & 1) == 1
  let out = StringBuilder()
  let mut remaining = cch
  let mut opening = true
  while remaining > 0 {
    if opening {
      opening = false
    } else {
      // The stretch after a cut opens with a flags byte of its own; only
      // its first bit, the width of a character, is read.
      s.step(what)
      s.need(1, what, "characters")
      wide = (s.stream[s.take(1)].to_int() & 1) == 1
    }
    let width = if wide { 2 } else { 1 }
    // Whole characters this record holds from here.
    let avail = s.left() / width
    let take = if avail < remaining { avail } else { remaining }
    if take > 0 {
      let from = s.take(take * width)
      out.write_string(characters(s.stream, from, take, wide, what))
      remaining = remaining - take
    }
    if remaining > 0 && s.left() != 0 {
      // A byte of a two-byte character, or more, that no whole character
      // uses: the cut does not fall between characters.
      raise bad(
        "byte \{s.here()} of the workbook stream: the characters of the \{what} are cut inside a character at the record's end",
      )
    }
  }
  for _ in 0..<runs {
    // A run is never cut: the record after a cut opens with the next one.
    s.step(what)
    s.need(4, what, "rich-text runs")
    ignore(s.take(4))
  }
  let mut to_skip = phonetic
  while to_skip > 0 {
    s.step(what)
    let take = if s.left() < to_skip { s.left() } else { to_skip }
    ignore(s.take(take))
    to_skip = to_skip - take
  }
  s.settle()
  out.to_string()
}

///|
/// The text of `count` characters at `from` of the stream: `count` UTF-16
/// code units when `wide`, and `count` one-byte characters otherwise,
/// each the low byte of its code unit — the code units U+0000 to U+00FF.
/// Raises `ParseError`, naming the byte, for characters that are not
/// well-formed UTF-16: a surrogate with no pair.
fn characters(
  stream : Bytes,
  from : Int32,
  count : Int32,
  wide : Bool,
  what : String,
) -> String raise @types.DataError {
  let units = if wide {
    stream[from:from + 2 * count]
  } else {
    // A one-byte character widened to the code unit it spells.
    Bytes::makei(2 * count, i => {
      if (i & 1) == 0 {
        stream[from + (i >> 1)]
      } else {
        b'\x00'
      }
    })
  }
  @utf16.decode(units, endianness=Little) catch {
    Malformed(_) =>
      raise bad(
        "byte \{from} of the workbook stream: the characters of the \{what} are not well-formed UTF-16",
      )
  }
}
