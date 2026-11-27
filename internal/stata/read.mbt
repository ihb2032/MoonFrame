// The Stata dataset reader: the two header families the format has — the
// binary header of releases 113 to 116 and the tagged header of 117 to
// 119 — the row-major data block, and the long-string table.

///|
/// One located parse refusal — the reader's error vocabulary.
fn bad(what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("stata: \{what}"),
  )
}

///|
/// The storage type a variable's cells ride. `Str` is a fixed-width
/// string of as many bytes, NUL-padded; `StrL` is an eight-byte key into
/// the long-string table.
priv enum Storage {
  Byte
  Int
  Long
  Float
  Double
  Str(Int32)
  StrL
}

///|
/// The width in bytes of one cell under this storage.
fn Storage::width(self : Storage) -> Int32 {
  match self {
    Byte => 1
    Int => 2
    Long | Float => 4
    Double | StrL => 8
    Str(width) => width
  }
}

///|
/// The storage a binary header's type byte names: `1` to `244` a
/// fixed-width string of that width, and the five numeric types above
/// them. Any other code is refused by what it says.
fn binary_storage(code : Int32) -> Storage raise @types.DataError {
  if code >= 1 && code <= 244 {
    return Str(code)
  }
  match code {
    251 => Byte
    252 => Int
    253 => Long
    254 => Float
    255 => Double
    _ =>
      raise @types.DataError::Unsupported(
        "the variable type code \{code} names no storage this reader reads",
      )
  }
}

///|
/// The storage a tagged header's two-byte type code names: `1` to
/// `2045` a fixed-width string of that width, the long-string key at
/// `32768`, and the five numeric types counting down from `65530`. Any
/// other code is refused by what it says.
fn tagged_storage(code : Int32) -> Storage raise @types.DataError {
  if code >= 1 && code <= 2045 {
    return Str(code)
  }
  match code {
    32768 => StrL
    65526 => Double
    65527 => Float
    65528 => Long
    65529 => Int
    65530 => Byte
    _ =>
      raise @types.DataError::Unsupported(
        "the variable type code \{code} names no storage this reader reads",
      )
  }
}

///|
/// One variable as its header describes it: its name, its storage, its
/// display format, and the offset its cell starts at inside a row.
priv struct Variable {
  name : String
  storage : Storage
  format : String
  offset : Int32
}

///|
/// One record of the long-string table: its kind byte, and where its
/// payload starts and how long it is.
priv struct StrLEntry {
  kind : Int32
  start : Int32
  length : Int32
}

///|
/// What the header establishes before any cell is read: the observation
/// count, the variables, the data block's place and row width, and — in
/// the tagged releases, which have one — the long-string table.
priv struct Layout {
  nobs : Int64
  variables : Array[Variable]
  row_width : Int32
  data_start : Int32
  table : Map[UInt64, StrLEntry]
}

///|
/// The date family a display format names, by the letters it opens with.
/// `%td` is a count of days and `%tc` and `%tC` a count of milliseconds.
/// Every other format — the weekly, monthly, quarterly, half-yearly and
/// yearly families, and the old `%d` — leaves its column a number.
priv enum DateKind {
  Plain
  Day
  Clock
}

///|
/// The date family `format` names.
fn date_kind(format : String) -> DateKind {
  if format.has_prefix("%td") {
    Day
  } else if format.has_prefix("%tc") || format.has_prefix("%tC") {
    Clock
  } else {
    Plain
  }
}

///|
/// The file's bytes under a reading position, read in the file's byte
/// order and decoded in its release's text encoding. Every read is
/// checked against what remains before it indexes: one that would leave
/// the file refuses, naming the offset it was at, so no count the file
/// carries reaches an index, a slice, or an allocation unchecked. The
/// position never passes the byte length, which is what keeps the
/// subtraction form of those checks exact.
priv struct Cursor {
  bytes : Bytes
  mut pos : Int32
  mut big : Bool
  mut utf8 : Bool
}

///|
/// Refuse unless `need` bytes remain at the position. A negative `need`
/// is a length the file got wrong rather than a short file, and says so.
fn Cursor::short64(self : Cursor, need : Int64) -> Unit raise @types.DataError {
  if need < 0L {
    raise bad("a length of \{need} bytes at offset \{self.pos} is negative")
  }
  if (self.bytes.length() - self.pos).to_int64() < need {
    raise bad(
      "the file ends at byte \{self.bytes.length()} before the \{need} bytes needed at offset \{self.pos}",
    )
  }
}

///|
/// Refuse unless `need` bytes remain at the position.
fn Cursor::short(self : Cursor, need : Int32) -> Unit raise @types.DataError {
  self.short64(need.to_int64())
}

///|
/// Step over `count` bytes.
fn Cursor::skip(self : Cursor, count : Int32) -> Unit raise @types.DataError {
  self.short(count)
  self.pos = self.pos + count
}

///|
/// Step over a `count` too wide for the machine word's arithmetic. The
/// check that precedes the narrowing proves it fits the file, and so the
/// word.
fn Cursor::skip64(self : Cursor, count : Int64) -> Unit raise @types.DataError {
  self.short64(count)
  self.pos = self.pos + count.to_int()
}

///|
/// Whether the bytes at the position are `text`; the position does not
/// move.
fn Cursor::looks(self : Cursor, text : Bytes) -> Bool raise @types.DataError {
  self.short(text.length())
  let mut same = true
  for i in 0..<text.length() {
    if self.bytes[self.pos + i] != text[i] {
      same = false
    }
  }
  same
}

///|
/// Consume `text` where the position is, or refuse: the layout's tags
/// are what place everything after them.
fn Cursor::tag(self : Cursor, text : Bytes) -> Unit raise @types.DataError {
  self.short(text.length())
  for i in 0..<text.length() {
    if self.bytes[self.pos + i] != text[i] {
      raise bad(
        "expected the tag \{latin1(text, 0, text.length())} at offset \{self.pos}",
      )
    }
  }
  self.pos = self.pos + text.length()
}

///|
/// A one-byte unsigned integer.
fn Cursor::u8(self : Cursor) -> Int32 raise @types.DataError {
  self.short(1)
  let value = self.bytes[self.pos].to_int()
  self.pos = self.pos + 1
  value
}

///|
/// A one-byte signed integer, as a 64-bit count.
fn Cursor::i8(self : Cursor) -> Int64 raise @types.DataError {
  let value = self.u8()
  if value >= 128 {
    (value - 256).to_int64()
  } else {
    value.to_int64()
  }
}

///|
/// A two-byte unsigned integer.
fn Cursor::u16(self : Cursor) -> Int32 raise @types.DataError {
  self.short(2)
  let first = self.bytes[self.pos].to_int()
  let second = self.bytes[self.pos + 1].to_int()
  self.pos = self.pos + 2
  if self.big {
    (first << 8) | second
  } else {
    (second << 8) | first
  }
}

///|
/// A two-byte signed integer, as a 64-bit count.
fn Cursor::i16(self : Cursor) -> Int64 raise @types.DataError {
  let value = self.u16()
  if value >= 32768 {
    (value - 65536).to_int64()
  } else {
    value.to_int64()
  }
}

///|
/// A four-byte unsigned integer, as a 64-bit count.
fn Cursor::u32(self : Cursor) -> Int64 raise @types.DataError {
  self.short(4)
  let mut value = 0L
  if self.big {
    for i in 0..<4 {
      value = (value << 8) | self.bytes[self.pos + i].to_int64()
    }
  } else {
    for i = 3; i >= 0; i = i - 1 {
      value = (value << 8) | self.bytes[self.pos + i].to_int64()
    }
  }
  self.pos = self.pos + 4
  value
}

///|
/// A four-byte signed integer, as a 64-bit count.
fn Cursor::i32(self : Cursor) -> Int64 raise @types.DataError {
  let value = self.u32()
  if value >= 2147483648L {
    value - 4294967296L
  } else {
    value
  }
}

///|
/// An eight-byte unsigned integer.
fn Cursor::u64(self : Cursor) -> UInt64 raise @types.DataError {
  self.short(8)
  let mut value = 0UL
  if self.big {
    for i in 0..<8 {
      value = (value << 8) | self.bytes[self.pos + i].to_uint64()
    }
  } else {
    for i = 7; i >= 0; i = i - 1 {
      value = (value << 8) | self.bytes[self.pos + i].to_uint64()
    }
  }
  self.pos = self.pos + 8
  value
}

///|
/// A four-byte floating-point cell, widened to `Double` — `None` when
/// its bits lie outside the storage's valid range. The 27 missing codes
/// sit at the top of that range's magnitude side, `.` at `0x7F000000`
/// and `.a` to `.z` a fixed step above it; whatever else lies outside —
/// the infinities, a NaN of no code — counts the same.
fn Cursor::f32_cell(self : Cursor) -> Double? raise @types.DataError {
  self.short(4)
  let b0 = self.bytes[self.pos].to_uint()
  let b1 = self.bytes[self.pos + 1].to_uint()
  let b2 = self.bytes[self.pos + 2].to_uint()
  let b3 = self.bytes[self.pos + 3].to_uint()
  self.pos = self.pos + 4
  let bits : UInt32 = if self.big {
    (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  } else {
    (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
  }
  if (bits & 0x7FFFFFFFU) >= 0x7F000000U {
    None
  } else {
    Some(@types.float32_bits_to_double(bits))
  }
}

///|
/// An eight-byte floating-point cell — `None` when its bits lie outside
/// the storage's valid range. The 27 missing codes sit at the top of
/// that range's magnitude side, `.` at `0x7FE0000000000000` and `.a` to
/// `.z` a fixed step above it; whatever else lies outside — the
/// infinities, a NaN of no code — counts the same.
fn Cursor::f64_cell(self : Cursor) -> Double? raise @types.DataError {
  let bits = self.u64()
  if (bits & 0x7FFFFFFFFFFFFFFFUL) >= 0x7FE0000000000000UL {
    None
  } else {
    Some(bits.reinterpret_as_double())
  }
}

///|
/// `width` bytes at the position as text, cut at the first NUL and
/// decoded in the release's encoding; the position moves past them.
fn Cursor::text(self : Cursor, width : Int32) -> String raise @types.DataError {
  self.short(width)
  let text = decode_text(self.bytes, self.pos, width, self.utf8)
  self.pos = self.pos + width
  text
}

///|
/// The position the map places a section at. One past the file refuses;
/// inside it the count is smaller than the byte length, and so fits the
/// machine word.
fn Cursor::place(self : Cursor, at : UInt64) -> Int32 raise @types.DataError {
  if at > self.bytes.length().to_uint64() {
    raise bad(
      "the map places a section at offset \{at}, past the file's \{self.bytes.length()} bytes",
    )
  }
  at.to_int()
}

///|
/// `count` entries of `each` bytes at the position, as a count the
/// machine word holds — refused when the file is too short to hold them,
/// so nothing is sized by a count the bytes contradict.
fn Cursor::items(
  self : Cursor,
  count : Int64,
  each : Int32,
) -> Int32 raise @types.DataError {
  let have = (self.bytes.length() - self.pos).to_int64()
  if count < 0L || count > 2147483647L || count * each.to_int64() > have {
    raise bad(
      "the header declares \{count} entries of \{each} bytes at offset \{self.pos}, and only \{have} bytes remain",
    )
  }
  count.to_int()
}

///|
/// `width` bytes at `start` as text: cut at the first NUL, then decoded
/// in the release's encoding — UTF-8 from release 118 on, where bytes
/// that are not well-formed UTF-8 read as Latin-1 instead (a file
/// carried up from an earlier release without its text re-encoded stays
/// readable, string by string); Latin-1 before, where every byte is a
/// character. Pure ASCII takes the UTF-8 decoder's fast path under
/// either encoding.
fn decode_text(
  bytes : Bytes,
  start : Int32,
  width : Int32,
  utf8 : Bool,
) -> String {
  let mut end = start
  let stop = start + width
  let mut ascii = true
  while end < stop {
    let b = bytes[end].to_int()
    if b == 0 {
      break
    }
    if b >= 128 {
      ascii = false
    }
    end += 1
  }
  if utf8 || ascii {
    let outcome : Result[String, Unit] = Ok(@utf8.decode(bytes[start:end])) catch {
      _ => Err(())
    }
    match outcome {
      Ok(text) => text
      Err(_) => latin1(bytes, start, end)
    }
  } else {
    latin1(bytes, start, end)
  }
}

///|
/// `bytes[start:end]` as Latin-1 text: one character per byte.
fn latin1(bytes : Bytes, start : Int32, end : Int32) -> String {
  let out = StringBuilder()
  for i in start..<end {
    out.write_char(bytes[i].to_char())
  }
  out.to_string()
}

///|
/// Whether a `byte` cell's stored value is a missing value. The 27
/// codes — `.` at 101, `.a` to `.z` at 102 to 127 — lie above the
/// storage's largest valid value, and the one value below its smallest
/// counts the same: a cell outside the valid range is missing, not data.
fn byte_missing(value : Int64) -> Bool {
  value < -127L || value > 100L
}

///|
/// Whether an `int` cell's stored value is a missing value: the 27 codes
/// occupy 32741 to 32767, above the valid range, which opens at -32767.
fn int_missing(value : Int64) -> Bool {
  value < -32767L || value > 32740L
}

///|
/// Whether a `long` cell's stored value is a missing value: the 27 codes
/// occupy 2147483621 to 2147483647, above the valid range, which opens
/// at -2147483647.
fn long_missing(value : Int64) -> Bool {
  value < -2147483647L || value > 2147483620L
}

///|
/// The observation count as a frame height: a count past the `Int32` a
/// frame's height rides refuses rather than truncating.
fn observation_count(nobs : UInt64) -> Int64 raise @types.DataError {
  if nobs > 2147483647UL {
    raise bad(
      "the file declares \{nobs} observations, past a frame's own height",
    )
  }
  nobs.reinterpret_as_int64()
}

///|
/// The refusal for a release this reader does not read, naming what the
/// file says of itself.
fn refuse_release(found : String) -> @types.DataError {
  @types.DataError::Unsupported(
    "the file declares release \{found}; this reader reads releases 113 to 119",
  )
}

///|
/// The release a tagged header names: three characters, read as a
/// number. Anything but 117, 118 and 119 is refused by what it says.
fn tagged_release(r : Cursor) -> Int32 raise @types.DataError {
  r.short(3)
  let mut value = 0
  let mut numeric = true
  for i in 0..<3 {
    let b = r.bytes[r.pos + i].to_int()
    if b < 48 || b > 57 {
      numeric = false
    } else {
      value = value * 10 + (b - 48)
    }
  }
  let found = latin1(r.bytes, r.pos, r.pos + 3)
  r.pos = r.pos + 3
  if numeric && value >= 117 && value <= 119 {
    value
  } else {
    raise refuse_release(found)
  }
}

///|
/// The byte order a tagged header names, as its `big` flag: `LSF` is
/// little-endian, `MSF` big-endian, and anything else is no dataset.
fn byte_order(r : Cursor) -> Bool raise @types.DataError {
  if r.looks(b"LSF") {
    r.skip(3)
    false
  } else if r.looks(b"MSF") {
    r.skip(3)
    true
  } else {
    raise bad(
      "the byte order field at offset \{r.pos} reads neither LSF nor MSF",
    )
  }
}

///|
/// The data block's length for `nobs` observations of these variables:
/// the row width summed as a 64-bit count, then the block checked
/// against what the file holds from the position on. A block the file
/// cannot hold refuses, naming the counts that disagree with the bytes.
/// A table of no variable has no data whatever its observation count
/// says.
fn data_room(
  r : Cursor,
  storages : Array[Storage],
  nobs : Int64,
) -> Int32 raise @types.DataError {
  let mut row = 0L
  for storage in storages {
    row += storage.width().to_int64()
  }
  let have = (r.bytes.length() - r.pos).to_int64()
  if row > 0L && nobs > have / row {
    raise bad(
      "the data block at offset \{r.pos} declares \{nobs} observations of \{row} bytes, and only \{have} bytes remain",
    )
  }
  (nobs * row).to_int()
}

///|
/// The variables of a header from its three descriptor lists — names,
/// storages and formats — each carrying the offset its cell starts at
/// inside a row. The offsets are narrow: the count was already checked
/// against the descriptor bytes the file holds for it, so a row is never
/// more than eight bytes for every eighty-four of file.
fn zip_variables(
  names : Array[String],
  storages : Array[Storage],
  formats : Array[String],
) -> Array[Variable] {
  let variables : Array[Variable] = []
  let mut offset = 0
  for i in 0..<names.length() {
    variables.push(Variable::{
      name: names[i],
      storage: storages[i],
      format: formats[i],
      offset,
    })
    offset += storages[i].width()
  }
  variables
}

///|
/// The row width of a header's variables.
fn row_width(variables : Array[Variable]) -> Int32 {
  let mut width = 0
  for v in variables {
    width += v.storage.width()
  }
  width
}

///|
/// The eight bytes a cell holds to name the long-string record of the
/// variable-and-observation pair `(v, o)`, as one integer: the pair's low
/// bytes — `v_bytes` of the variable's, then the rest of the
/// observation's — each spelled in the file's byte order, and the eight
/// read back in that order.
fn strl_key(r : Cursor, v : UInt64, o : UInt64, v_bytes : Int32) -> UInt64 {
  let o_bytes = 8 - v_bytes
  let v_mask = (1UL << (v_bytes * 8)) - 1UL
  let o_mask = (1UL << (o_bytes * 8)) - 1UL
  if r.big {
    ((v & v_mask) << (o_bytes * 8)) | (o & o_mask)
  } else {
    (v & v_mask) | ((o & o_mask) << (v_bytes * 8))
  }
}

///|
/// The long-string table of a tagged release: `GSO` record after `GSO`
/// record up to the closing tag. A record's header carries the
/// variable-and-observation pair it belongs to — eight bytes in release
/// 117, read as they are, and twelve in 118 and 119, a four-byte variable
/// number and an eight-byte observation number of which a cell keeps the
/// low two and six bytes in 118 and the low three and five in 119. Every
/// record is collected, referenced or not, and a later record under the
/// same key replaces the earlier one. A record's kind is not judged here:
/// a record no cell names changes nothing.
fn read_strl_table(
  r : Cursor,
  release : Int32,
) -> Map[UInt64, StrLEntry] raise @types.DataError {
  let table : Map[UInt64, StrLEntry] = Map([])
  while r.looks(b"GSO") {
    r.skip(3)
    let key = if release == 117 {
      r.u64()
    } else {
      let v = r.u32().reinterpret_as_uint64()
      let o = r.u64()
      strl_key(r, v, o, if release == 118 { 2 } else { 3 })
    }
    let kind = r.u8()
    let length = r.u32()
    // The payload's place is taken before the position moves past it.
    let start = r.pos
    r.skip64(length)
    table[key] = StrLEntry::{ kind, start, length: length.to_int(), }
  }
  r.tag(b"</strls>")
  table
}

///|
/// The binary header of releases 113 to 116: fixed fields in a fixed
/// order, then one descriptor block per kind — the types, the names, the
/// sort list, the formats, the value-label names, the variable labels —
/// and the expansion fields, which end where the data begins. The sort
/// list, the value-label names, the labels, the dataset label and the
/// timestamp are stepped over unread: none of them changes a cell.
/// `release` is the file's first byte, already read; these releases
/// have no long-string table.
fn read_binary_header(
  r : Cursor,
  release : Int32,
) -> Layout raise @types.DataError {
  if release < 113 || release > 116 {
    raise refuse_release(release.to_string())
  }
  // Byte 1 is 1 for a big-endian file and anything else little-endian:
  // the writers of these releases spell little-endian as 2, and the
  // oldest left the byte zero. Two more bytes — the file type and one
  // the format leaves unused — follow it.
  r.big = r.u8() == 1
  r.skip(2)
  let count = r.u16()
  let nobs = observation_count(r.u32().reinterpret_as_uint64())
  // The dataset label and the creation timestamp.
  r.skip(81)
  r.skip(18)
  // Every variable owes its type byte, its 33-byte name, its two-byte
  // sort slot, its 12-byte format, its 33-byte value-label name and its
  // 81-byte label: a count the file cannot hold refuses here, before
  // anything is sized by it.
  let count = r.items(count.to_int64(), 162)
  let storages : Array[Storage] = []
  for _ in 0..<count {
    storages.push(binary_storage(r.u8()))
  }
  let names : Array[String] = []
  for _ in 0..<count {
    names.push(r.text(33))
  }
  // The sort list: one two-byte slot per variable, and the zero that
  // closes it.
  r.skip(2 * count + 2)
  // Release 113 carries a twelve-byte format where its successors carry
  // forty-nine.
  let format_width = if release == 113 { 12 } else { 49 }
  let formats : Array[String] = []
  for _ in 0..<count {
    formats.push(r.text(format_width))
  }
  // The value-label names and the variable labels.
  r.skip(33 * count)
  r.skip(81 * count)
  // The expansion fields: a type byte and a four-byte length each, then
  // as many bytes as the length says. A type byte of zero closes them,
  // and its length is read with it: the closing field is five bytes, and
  // the data begins after all of them.
  for ;; {
    let kind = r.i8()
    let length = r.i32()
    if kind == 0L {
      break
    }
    r.skip64(length)
  }
  let variables = zip_variables(names, storages, formats)
  let data_start = r.pos
  let data_length = data_room(r, storages, nobs)
  r.skip(data_length)
  Layout::{
    nobs,
    variables,
    row_width: row_width(variables),
    data_start,
    table: Map([]),
  }
}

///|
/// The tagged header of releases 117 to 119: the release, the byte
/// order, the variable count, the observation count, the dataset label
/// and the timestamp, each wrapped in a tag; then a map of fourteen file
/// positions. The map places the sections read here — the types, the
/// names, the formats, the data and the long-string table — and the
/// file's closing tag, each checked to end where its own count says.
/// The sort list, the value-label names, the variable labels, the
/// characteristics and the value-label table are never visited, so a
/// file whose data is whole reads whatever became of them.
fn read_tagged_header(r : Cursor) -> Layout raise @types.DataError {
  r.tag(b"<stata_dta><header><release>")
  let release = tagged_release(r)
  r.utf8 = release >= 118
  r.tag(b"</release><byteorder>")
  r.big = byte_order(r)
  r.tag(b"</byteorder><K>")
  // The variable count is two bytes in 117 and 118 and four in 119; the
  // observation count four in 117 and eight after it.
  let count = if release == 119 { r.u32() } else { r.u16().to_int64() }
  r.tag(b"</K><N>")
  let nobs = if release == 117 {
    observation_count(r.u32().reinterpret_as_uint64())
  } else {
    observation_count(r.u64())
  }
  r.tag(b"</N><label>")
  // The dataset label: its length, then as many bytes.
  if release == 117 {
    r.skip(r.u8())
  } else {
    r.skip(r.u16())
  }
  r.tag(b"</label><timestamp>")
  r.skip(r.u8())
  r.tag(b"</timestamp></header><map>")
  let map : Array[UInt64] = []
  for _ in 0..<14 {
    map.push(r.u64())
  }
  // A variable's name takes 33 bytes in 117 and 129 after it; its format
  // 49 and 57. Every variable owes its type code, its name and its
  // format: a count the file cannot hold refuses here, before anything
  // is sized by it.
  let name_width = if release == 117 { 33 } else { 129 }
  let format_width = if release == 117 { 49 } else { 57 }
  let count = r.items(count, 2 + name_width + format_width)
  let storages : Array[Storage] = []
  r.pos = r.place(map[2])
  r.tag(b"<variable_types>")
  for _ in 0..<count {
    storages.push(tagged_storage(r.u16()))
  }
  r.tag(b"</variable_types>")
  let names : Array[String] = []
  r.pos = r.place(map[3])
  r.tag(b"<varnames>")
  for _ in 0..<count {
    names.push(r.text(name_width))
  }
  r.tag(b"</varnames>")
  let formats : Array[String] = []
  r.pos = r.place(map[5])
  r.tag(b"<formats>")
  for _ in 0..<count {
    formats.push(r.text(format_width))
  }
  r.tag(b"</formats>")
  r.pos = r.place(map[9])
  r.tag(b"<data>")
  let data_start = r.pos
  let data_length = data_room(r, storages, nobs)
  r.skip(data_length)
  r.tag(b"</data>")
  r.pos = r.place(map[10])
  r.tag(b"<strls>")
  let table = read_strl_table(r, release)
  r.pos = r.place(map[12])
  r.tag(b"</stata_dta>")
  let variables = zip_variables(names, storages, formats)
  Layout::{
    nobs,
    variables,
    row_width: row_width(variables),
    data_start,
    table,
  }
}

///|
/// Collect one integer variable's cells: each row's cell is read at its
/// offset and passed through `cell`, which answers the value it
/// contributes or `None` for a missing one. The offsets walk the data
/// block, which was checked to lie inside the file.
fn collect_int(
  r : Cursor,
  layout : Layout,
  offset : Int32,
  cell : (Cursor) -> Int64? raise @types.DataError,
) -> Array[Int64?] raise @types.DataError {
  let cells : Array[Int64?] = []
  let mut at = layout.data_start + offset
  for _ in 0..<layout.nobs.to_int() {
    r.pos = at
    cells.push(cell(r))
    at += layout.row_width
  }
  cells
}

///|
/// Collect one floating-point variable's cells the same way.
fn collect_float(
  r : Cursor,
  layout : Layout,
  offset : Int32,
  cell : (Cursor) -> Double? raise @types.DataError,
) -> Array[Double?] raise @types.DataError {
  let cells : Array[Double?] = []
  let mut at = layout.data_start + offset
  for _ in 0..<layout.nobs.to_int() {
    r.pos = at
    cells.push(cell(r))
    at += layout.row_width
  }
  cells
}

///|
/// The count an integer cell contributes under a date family: the days
/// or milliseconds since the format's epoch, 1960-01-01, moved onto the
/// library's own, 1970-01-01 — 3653 days back for a day count, and
/// 315,619,200,000 milliseconds back for a millisecond count. An
/// integer cell's range leaves room for both shifts.
fn shifted_int(raw : Int64, kind : DateKind) -> Int64 {
  match kind {
    Plain => raw
    Day => raw - 3653L
    Clock => (raw - 315_619_200_000L) * 1000L
  }
}

///|
/// The count a floating-point cell contributes under a date family when
/// it is a whole number no larger in magnitude than 2^53 — wide enough
/// for any day or millisecond count, and narrow enough that the shift
/// and the scaling stay exact. Any other cell answers `None`.
fn shifted_double(value : Double, kind : DateKind) -> Int64? {
  if value.is_finite() &&
    value == value.trunc() &&
    value >= -9007199254740992.0 &&
    value <= 9007199254740992.0 {
    Some(shifted_int(value.to_int64(), kind))
  } else {
    None
  }
}

///|
/// The series an integer variable's cells build under a date family: a
/// day count builds a `Date` column, a millisecond count a `Timestamp`
/// column, and a number an `Int` column.
fn int_series(
  name : String,
  kind : DateKind,
  cells : Array[Int64?],
) -> @series.Series {
  match kind {
    Plain => @series.Series::from_int_options(name, cells)
    Day => @series.Series::from_date_options(name, cells)
    Clock => @series.Series::from_timestamp_options(name, cells)
  }
}

///|
/// The series a floating-point variable builds: a `Float` column, unless
/// the format names a date family and every present cell is a whole
/// number the count can hold — then the shifted counts, as a `Date` or a
/// `Timestamp` column. One cell that is not leaves the whole column a
/// number.
fn float_series(
  name : String,
  kind : DateKind,
  cells : Array[Double?],
) -> @series.Series {
  match kind {
    Plain => @series.Series::from_float_options(name, cells)
    Day | Clock => {
      let counts : Array[Int64?] = []
      for cell in cells {
        match cell {
          None => counts.push(None)
          Some(value) =>
            match shifted_double(value, kind) {
              None => return @series.Series::from_float_options(name, cells)
              Some(count) => counts.push(Some(count))
            }
        }
      }
      if kind is Day {
        @series.Series::from_date_options(name, counts)
      } else {
        @series.Series::from_timestamp_options(name, counts)
      }
    }
  }
}

///|
/// The series a `byte`, `int` or `long` variable builds. `raw` reads one
/// cell's stored value and says whether it lies outside the storage's
/// valid range; a cell inside it contributes its count — the value
/// itself, or its day or millisecond count under a date format — and one
/// outside contributes a missing cell.
fn integer_variable(
  r : Cursor,
  layout : Layout,
  v : Variable,
  raw : (Cursor) -> (Int64, Bool) raise @types.DataError,
) -> @series.Series raise @types.DataError {
  let kind = date_kind(v.format)
  let cells = collect_int(r, layout, v.offset, c => {
    let (value, missing) = raw(c)
    if missing {
      None
    } else {
      Some(shifted_int(value, kind))
    }
  })
  int_series(v.name, kind, cells)
}

///|
/// The text one long-string cell names: its eight-byte key looked up in
/// the table. Key zero is the empty string, which keeps no record. A key
/// with no record is a cell the file contradicts, and names its row and
/// column; so does a record whose text does not end in the NUL its
/// length counts. A record's kind says what it holds: text, which reads
/// with that terminator dropped, or binary data, which reads as no
/// string.
fn strl_text(
  r : Cursor,
  name : String,
  row : Int32,
  table : Map[UInt64, StrLEntry],
) -> String raise @types.DataError {
  let key = r.u64()
  if key == 0UL {
    return ""
  }
  let entry = match table.get(key) {
    Some(entry) => entry
    None =>
      raise bad(
        "row \{row + 1}, column \"\{name}\": the long-string key \{key} names no record in the table",
      )
  }
  match entry.kind {
    130 => {
      // The payload was checked to lie inside the file, so its last byte
      // is a position the file holds.
      if entry.length > 0 &&
        r.bytes[entry.start + entry.length - 1].to_int() != 0 {
        raise bad(
          "offset \{entry.start + entry.length - 1}: a long-string record's text does not end in NUL",
        )
      }
      decode_text(
        r.bytes,
        entry.start,
        entry.length - (if entry.length > 0 { 1 } else { 0 }),
        r.utf8,
      )
    }
    129 =>
      raise @types.DataError::Unsupported(
        "row \{row + 1}, column \"\{name}\": a binary strL, which reads as no string",
      )
    kind =>
      raise @types.DataError::Unsupported(
        "row \{row + 1}, column \"\{name}\": a strL of kind \{kind}, which reads as no string",
      )
  }
}

///|
/// One variable as a series, its cells read row by row.
///
/// A `byte`, `int` or `long` variable is an `Int` column and a `float`
/// or `double` a `Float` column; a string of either kind a `String`
/// column, where an empty string is an empty cell and never a missing
/// one. A variable whose format names a date family becomes a `Date` or
/// a `Timestamp` column instead — a floating-point one only while every
/// present cell is a whole number. A cell outside its storage's valid
/// range is missing in every numeric storage: the 27 codes, `.` and
/// `.a` to `.z`, and whatever else the range excludes.
fn read_variable(
  r : Cursor,
  v : Variable,
  layout : Layout,
) -> @series.Series raise @types.DataError {
  match v.storage {
    Byte =>
      integer_variable(r, layout, v, c => {
        let value = c.i8()
        (value, byte_missing(value))
      })
    Int =>
      integer_variable(r, layout, v, c => {
        let value = c.i16()
        (value, int_missing(value))
      })
    Long =>
      integer_variable(r, layout, v, c => {
        let value = c.i32()
        (value, long_missing(value))
      })
    Float =>
      float_series(
        v.name,
        date_kind(v.format),
        collect_float(r, layout, v.offset, c => c.f32_cell()),
      )
    Double =>
      float_series(
        v.name,
        date_kind(v.format),
        collect_float(r, layout, v.offset, c => c.f64_cell()),
      )
    Str(width) => {
      let cells : Array[String?] = []
      let mut at = layout.data_start + v.offset
      for _ in 0..<layout.nobs.to_int() {
        r.pos = at
        cells.push(Some(r.text(width)))
        at += layout.row_width
      }
      @series.Series::from_string_options(v.name, cells)
    }
    StrL => {
      let cells : Array[String?] = []
      let mut at = layout.data_start + v.offset
      for row in 0..<layout.nobs.to_int() {
        r.pos = at
        cells.push(Some(strl_text(r, v.name, row, layout.table)))
        at += layout.row_width
      }
      @series.Series::from_string_options(v.name, cells)
    }
  }
}

///|
/// The columns of a Stata dataset read from `bytes`, in file order, and
/// the observation count the file declares.
///
/// `bytes` is one whole dataset file. Releases 113 to 119 are read, in
/// either byte order: the binary header of 113 to 116 and the tagged
/// header of 117 to 119, long strings and UTF-8 text included from 117
/// and 118 on. The count answers even for a file of observations and no
/// variable, which reads as no column. The value-label table, the
/// characteristics, the sort list, the dataset label and the timestamp
/// are not applied to any cell: a labelled variable reads as the numbers
/// it stores.
///
/// `projection` keeps only the variables it names, in the file's order: a
/// name the file does not carry builds no column, and the count is the
/// file's own whatever is kept. A variable it leaves out is never read
/// into a cell, so a long-string refusal confined to it does not surface.
///
/// Raises `Unsupported` for a release this reader does not read, a
/// variable type code it does not read, or a long-string cell that holds
/// binary data — each naming what the file says. Raises
/// `ParseError(Message)` for a file whose bytes contradict its layout —
/// one that ends before a field, a section or the data block its own
/// counts describe, that carries a tag or a byte order the layout does
/// not know, or a long-string cell whose key names no record — each
/// naming the byte offset, or the row and column, where it fails.
pub fn read_stata_frame(
  bytes : Bytes,
  projection? : Array[String],
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let r : Cursor = Cursor::{ bytes, pos: 0, big: false, utf8: false, }
  // The first byte tells the two header families apart: `<` opens a
  // tagged header, which is read from that byte again; any other byte is
  // a binary header's release, already consumed.
  let first = r.u8()
  let layout = if first == 60 {
    r.pos = 0
    read_tagged_header(r)
  } else {
    read_binary_header(r, first)
  }
  let picked : Array[(String, @series.Series)] = []
  for v in layout.variables {
    // A projection names the variables to keep; none given keeps them all.
    if projection is Some(names) && !names.contains(v.name) {
      continue
    }
    picked.push((v.name, read_variable(r, v, layout)))
  }
  (picked, layout.nobs.to_int())
}
