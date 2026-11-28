///|
/// The data record as the reader holds it: every case's eight-byte
/// units in file order and floating-point byte order, and the number of
/// cases read.
priv struct Data {
  bytes : Bytes
  rows : Int32
}

///|
/// The eight-byte units one case holds: one for a numeric variable, and
/// as many as a string's width rounds up to.
fn row_units(slots : Array[Slot]) -> Int64 {
  let mut units = 0L
  for slot in slots {
    units += slot.octets.to_int64()
  }
  units
}

///|
/// The data record. Uncompressed, it holds whole cases of eight-byte
/// units, as many as the header declares; bytecode-compressed, its
/// codes are decoded case by case; zlib-compressed, its blocks are
/// inflated first and then read as bytecode. A header that declares no
/// count (-1) reads to the end of the data, which must then end on a
/// case boundary. A declared count is read exactly: data beyond it is
/// passed over, and a count the data cannot hold is refused before any
/// case is read.
fn read_data(c : Cursor, dict : Dictionary) -> Data raise @types.DataError {
  let units = row_units(dict.slots)
  let have = (c.bytes.length() - c.pos).to_int64()
  if dict.compression == 0 {
    let row_bytes = units * 8L
    let held = have / row_bytes
    let rows = if dict.ncases < 0L {
      if held * row_bytes != have {
        raise bad(
          "byte \{c.pos + (held * row_bytes).to_int()}: the data ends inside case \{held + 1L}, which holds \{row_bytes} bytes",
        )
      }
      held
    } else {
      if dict.ncases > held {
        raise bad(
          "byte \{c.pos}: the header declares \{dict.ncases} cases of \{row_bytes} bytes, and the file holds \{held}",
        )
      }
      dict.ncases
    }
    return { bytes: c.take((rows * row_bytes).to_int()), rows: rows.to_int(), }
  }
  let start = c.pos.to_int64()
  let stream = if dict.compression == 2 {
    inflated(c)
  } else {
    { bytes: c.take(have.to_int()), origin: start, held: have, }
  }
  // Eight codes share a group of eight bytes, and each code names at
  // most one unit: so a case of `units` units takes at least this many
  // bytes of codes.
  let least = (units + 7L) / 8L
  let possible = stream.held / least
  if dict.ncases > possible {
    raise bad(
      "\{stream_start(stream)}the header declares \{dict.ncases} cases of \{units} units, and the compressed data holds at most \{possible}",
    )
  }
  let codes = Codes::{
    bytes: stream.bytes,
    group_at: 0,
    index: 8,
    literal: 0,
    sysmis: dict.sysmis,
    big: dict.big_float,
  }
  let out : Array[Byte] = []
  let mut rows = 0L
  let limit = if dict.ncases < 0L { -1L } else { dict.ncases }
  while (limit < 0L || rows < limit) &&
        codes.case(out, units, rows + 1L, stream) {
    rows += 1L
  }
  if rows < limit {
    raise bad(
      "\{stream_at(stream, codes.literal)}the header declares \{dict.ncases} cases and the compressed data holds \{rows}",
    )
  }
  { bytes: Bytes::from_array(out), rows: rows.to_int(), }
}

///|
/// A stream of codes: its bytes, and where they sit — at a byte of the
/// file, or nowhere in it when they are the inflated blocks of a
/// zlib-compressed file. `held` is how many bytes of codes there are.
priv struct Stream {
  bytes : Bytes
  origin : Int64
  held : Int64
}

///|
/// How a refusal names the start of a stream of codes.
fn stream_start(stream : Stream) -> String {
  if stream.origin < 0L {
    "the zlib data: "
  } else {
    "byte \{stream.origin}: "
  }
}

///|
/// How a refusal names byte `at` of a stream of codes.
fn stream_at(stream : Stream, at : Int32) -> String {
  if stream.origin < 0L {
    "the zlib data: "
  } else {
    "byte \{stream.origin + at.to_int64()}: "
  }
}

///|
/// One bytecode stream: eight-byte groups of codes, each followed by the
/// eight-byte values its codes 253 name, in the order of those codes —
/// so a group ends where the last group's values did. A code 0 fills a
/// group out, 252 ends the stream, 254 spells eight blanks, 255 the
/// system-missing value, and every other code a number: the code less
/// the bias, which is 100.
priv struct Codes {
  bytes : Bytes
  mut group_at : Int32
  mut index : Int32
  mut literal : Int32
  sysmis : UInt64
  big : Bool
}

///|
/// Whether a group of codes is current, the next one loaded once the
/// last is spent — from where the last group's values ended. False at
/// the stream's end, which is any remainder shorter than a group.
fn Codes::group(self : Codes) -> Bool {
  if self.index < 8 {
    return true
  }
  let next = self.literal
  if self.bytes.length() - next < 8 {
    return false
  }
  self.group_at = next
  self.literal = next + 8
  self.index = 0
  true
}

///|
/// The next code that is not a filler 0; 0 once the stream has ended,
/// by a code 252 or by running out of groups.
fn Codes::code(self : Codes) -> Int32 {
  while self.group() {
    let code = self.bytes[self.group_at + self.index].to_int()
    self.index = self.index + 1
    if code == 252 {
      return 0
    }
    if code != 0 {
      return code
    }
  }
  0
}

///|
/// The next unit's eight bytes, appended to `out`; false once the
/// stream has ended before it.
fn Codes::unit(
  self : Codes,
  out : Array[Byte],
  stream : Stream,
) -> Bool raise @types.DataError {
  let code = self.code()
  if code == 0 {
    return false
  }
  if code == 253 {
    if self.bytes.length() - self.literal < 8 {
      raise bad(
        "\{stream_at(stream, self.literal)}the compressed data ends inside the value a code 253 names",
      )
    }
    for i in 0..<8 {
      out.push(self.bytes[self.literal + i])
    }
    self.literal = self.literal + 8
  } else if code == 254 {
    for _ in 0..<8 {
      out.push(b' ')
    }
  } else if code == 255 {
    push_bits(out, self.sysmis, self.big)
  } else {
    push_bits(out, (code.to_double() - 100.0).reinterpret_as_uint64(), self.big)
  }
  true
}

///|
/// Case number `number`, of `units` units, appended to `out`. False
/// when the stream has ended before the case; a stream that ends inside
/// the case contradicts the bytes its codes promised and is refused.
fn Codes::case(
  self : Codes,
  out : Array[Byte],
  units : Int64,
  number : Int64,
  stream : Stream,
) -> Bool raise @types.DataError {
  let before = out.length()
  let mut unit = 0L
  while unit < units {
    if !self.unit(out, stream) {
      if out.length() == before {
        return false
      }
      raise bad(
        "\{stream_at(stream, self.literal)}the compressed data ends inside case \{number}, after \{unit} of its \{units} units",
      )
    }
    unit += 1L
  }
  true
}

///|
/// The data of a zlib-compressed file: its blocks, each a zlib stream
/// of its own, inflated and joined. The header's offsets, the trailer's
/// block count, and every block's two offsets are checked against what
/// the file holds before a byte is inflated, and each block's declared
/// size bounds what it may inflate to.
fn inflated(c : Cursor) -> Stream raise @types.DataError {
  let header_at = c.pos
  let self_at = c.i64()
  let trailer_at = c.i64()
  let trailer_len = c.i64()
  if self_at != header_at.to_int64() {
    raise bad(
      "byte \{header_at}: the zlib header places itself at byte \{self_at}",
    )
  }
  let file = c.bytes.length().to_int64()
  if trailer_at < c.pos.to_int64() ||
    trailer_len < 24L ||
    trailer_len % 24L != 0L ||
    trailer_at > file ||
    trailer_len > file - trailer_at {
    raise bad(
      "byte \{header_at}: the zlib header places a trailer of \{trailer_len} bytes at byte \{trailer_at}, which does not lie in the file",
    )
  }
  let t = Cursor::{
    bytes: c.bytes,
    pos: trailer_at.to_int(),
    big: c.big,
    big_float: c.big_float,
  }
  let bias_at = t.pos
  let bias = t.i64()
  if bias != -100L {
    raise bad("byte \{bias_at}: the zlib trailer's bias is \{bias}, not -100")
  }
  t.skip(8)
  let block_size = t.u32()
  let blocks = t.u32()
  if blocks * 24L != trailer_len - 24L {
    raise bad(
      "byte \{trailer_at + 16L}: the zlib trailer of \{trailer_len} bytes names \{blocks} data blocks, where its length gives \{(trailer_len - 24L) / 24L}",
    )
  }
  let out : Array[Byte] = []
  let mut expected_data = self_at
  let mut expected_file = self_at + 24L
  let mut block = 0L
  while block < blocks {
    let at = t.pos
    let data_at = t.i64()
    let file_at = t.i64()
    let data_len = t.u32()
    let file_len = t.u32()
    if data_at != expected_data {
      raise bad(
        "byte \{at}: zlib data block \{block} places its data at byte \{data_at} of the inflated stream, where \{expected_data} is expected",
      )
    }
    if file_at != expected_file {
      raise bad(
        "byte \{at + 8}: zlib data block \{block} lies at byte \{file_at} of the file, where \{expected_file} is expected",
      )
    }
    if file_at > trailer_at || file_len > trailer_at - file_at {
      raise bad(
        "byte \{at + 16}: zlib data block \{block} claims \{file_len} bytes at byte \{file_at}, which do not lie before the trailer at byte \{trailer_at}",
      )
    }
    if data_len > block_size {
      raise bad(
        "byte \{at + 16}: zlib data block \{block} claims \{data_len} bytes of data, past the trailer's block size of \{block_size}",
      )
    }
    if data_len > file_len * 1040L + 1024L {
      raise bad(
        "byte \{at + 16}: zlib data block \{block} claims \{data_len} bytes of data from \{file_len} bytes, past what zlib can expand",
      )
    }
    let compressed = c.bytes[file_at.to_int():file_at.to_int() +
      file_len.to_int()]
    let inflated : Result[Bytes, @zlib.ZlibError] = Ok(
      @zlib.decompress(compressed, max_output_bytes=data_len.to_int() + 1),
    ) catch {
      e => Err(e)
    }
    let plain = match inflated {
      Ok(plain) => plain
      Err(e) =>
        raise bad(
          "byte \{file_at}: zlib data block \{block} does not inflate: \{e}",
        )
    }
    if plain.length().to_int64() != data_len {
      raise bad(
        "byte \{at + 16}: zlib data block \{block} inflates to \{plain.length()} bytes, where it declares \{data_len}",
      )
    }
    for i in 0..<plain.length() {
      out.push(plain[i])
    }
    expected_data += data_len
    expected_file += file_len
    block += 1L
  }
  if expected_file != trailer_at {
    raise bad(
      "byte \{trailer_at}: the zlib data blocks end at byte \{expected_file}, where the trailer starts",
    )
  }
  { bytes: Bytes::from_array(out), origin: -1L, held: out.length().to_int64(), }
}
