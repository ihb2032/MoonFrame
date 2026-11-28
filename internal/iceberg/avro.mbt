// An Avro container: its magic, the metadata map of its header, the sync
// marker every block ends with, and the blocks a reader walks. A compressed
// block declares only its compressed size, so what it inflates to is
// bounded; every count, length and marker is checked against the bytes
// that remain before it is used.

///|
/// How many bytes a block may inflate to.
const MAX_BLOCK_BYTES : Int32 = 16777216

///|
/// How many metadata entries a header may carry.
const MAX_METADATA : Int64 = 1024L

///|
/// The block codecs a container's header may name.
priv enum Codec {
  NoCodec
  Deflate
  Snappy
  Zstd
}

///|
/// The codec the header names at `at`, a name this reader does not
/// inflate raising `ParseError`.
fn codec_named(name : String, at : Int32) -> Codec raise @types.DataError {
  match name {
    "null" => NoCodec
    "deflate" => Deflate
    "snappy" => Snappy
    "zstandard" | "zstd" => Zstd
    _ =>
      raise malformed(
        "byte \{at}: the header names the block codec \"\{name}\", which this reader does not inflate",
      )
  }
}

///|
/// The unsigned 32-bit big-endian integer at `at`.
fn be32(bytes : Bytes, at : Int32) -> UInt32 {
  (bytes[at].to_int().reinterpret_as_uint() << 24) |
  (bytes[at + 1].to_int().reinterpret_as_uint() << 16) |
  (bytes[at + 2].to_int().reinterpret_as_uint() << 8) |
  bytes[at + 3].to_int().reinterpret_as_uint()
}

///|
/// Whether two byte strings of one length say the same.
fn same_bytes(a : Bytes, b : Bytes) -> Bool {
  a.range_equal(start=0, b, other_start=0, len=a.length())
}

///|
/// A block's bytes as the writer encoded them, before its codec compressed
/// them — inflated under the bound `MAX_BLOCK_BYTES`. A snappy block ends
/// with a checksum over exactly these bytes, checked here against them.
/// Raises `ParseError` when the block does not decompress within the bound
/// or its checksum does not match.
fn inflate(
  codec : Codec,
  payload : Bytes,
  at : Int32,
) -> Bytes raise @types.DataError {
  match codec {
    NoCodec => payload
    Deflate =>
      @flate.inflate_all(payload, max_output=MAX_BLOCK_BYTES) catch {
        _ =>
          raise malformed(
            "byte \{at}: a deflate block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
          )
      }
    Snappy => {
      // The snappy stream, then four bytes: the block's CRC-32.
      if payload.length() < 4 {
        raise malformed("byte \{at}: a snappy block shorter than its checksum")
      }
      let stream = payload.exact_view(end=payload.length() - 4).to_owned()
      let out = @snappy.decompress_raw(stream, max_output=MAX_BLOCK_BYTES) catch {
        _ =>
          raise malformed(
            "byte \{at}: a snappy block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
          )
      }
      if @checksum.crc32(out) != be32(payload, payload.length() - 4) {
        raise malformed(
          "byte \{at}: a snappy block whose checksum does not match its bytes",
        )
      }
      out
    }
    Zstd =>
      @zstd.decompress(payload, max_output=MAX_BLOCK_BYTES) catch {
        _ =>
          raise malformed(
            "byte \{at}: a zstandard block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
          )
      }
  }
}

///|
/// A cursor over one run of bytes: the run, where the values read so far
/// reach, and what the run is — for the refusals, which name the byte.
priv struct Cursor {
  bytes : Bytes
  mut at : Int32
  origin : String
}

///|
/// How many bytes are still unread.
fn Cursor::remaining(self : Cursor) -> Int32 {
  self.bytes.length() - self.at
}

///|
/// The refusal for a value the bytes end inside.
fn Cursor::ended(self : Cursor, start : Int32) -> @types.DataError {
  malformed("byte \{start} of \{self.origin}: the bytes end inside a value")
}

///|
/// One byte.
fn Cursor::byte(self : Cursor) -> Int32 raise @types.DataError {
  if self.at < self.bytes.length() {
    let b = self.bytes[self.at].to_int()
    self.at = self.at + 1
    b
  } else {
    raise self.ended(self.at)
  }
}

///|
/// The next `count` bytes, which must all be there.
fn Cursor::take(self : Cursor, count : Int32) -> Bytes raise @types.DataError {
  let start = self.at
  if count >= 0 && count <= self.remaining() {
    let out = self.bytes
      .exact_view(start=self.at, end=self.at + count)
      .to_owned()
    self.at = self.at + count
    out
  } else {
    raise self.ended(start)
  }
}

///|
/// A variable-length integer: seven payload bits a byte, least significant
/// first, the top bit of every byte but the last saying one more follows.
/// Ten bytes hold 64 bits, and the tenth may carry only the lowest of them.
fn Cursor::varint(self : Cursor) -> UInt64 raise @types.DataError {
  let start = self.at
  let mut result : UInt64 = 0UL
  for i in 0..<9 {
    let b = self.byte()
    result = result | ((b & 0x7F).to_uint64() << (7 * i))
    if (b & 0x80) == 0 {
      return result
    }
  }
  // The tenth byte: the sixty-third bit alone, with nothing after it.
  let last = self.byte()
  if last > 1 {
    raise malformed(
      "byte \{start} of \{self.origin}: a variable-length integer wider than 64 bits",
    )
  }
  result | (last.to_uint64() << 63)
}

///|
/// A signed 64-bit value, zigzag-encoded.
fn Cursor::long(self : Cursor) -> Int64 raise @types.DataError {
  let u = self.varint()
  let value = (u >> 1).reinterpret_as_int64()
  if (u & 1UL) == 0UL {
    value
  } else {
    value ^ -1L
  }
}

///|
/// A byte length: not negative, and no longer than the bytes still unread —
/// so a length can never ask for what the bytes do not hold.
fn Cursor::length(self : Cursor) -> Int32 raise @types.DataError {
  let start = self.at
  let v = self.long()
  if v < 0L || v > self.remaining().to_int64() {
    raise malformed(
      "byte \{start} of \{self.origin}: a length of \{v} bytes that the bytes cannot hold",
    )
  }
  v.to_int()
}

///|
/// A little-endian unsigned integer of `width` bytes, at most eight.
fn Cursor::le(self : Cursor, width : Int32) -> UInt64 raise @types.DataError {
  let mut v : UInt64 = 0UL
  for i in 0..<width {
    v = v | (self.byte().to_uint64() << (8 * i))
  }
  v
}

///|
/// A string: its byte length, then its UTF-8 bytes.
fn Cursor::string(self : Cursor) -> String raise @types.DataError {
  let start = self.at
  let bytes = self.take(self.length())
  @utf8.decode(bytes) catch {
    _ =>
      raise malformed(
        "byte \{start} of \{self.origin}: a string that is not valid UTF-8",
      )
  }
}

///|
/// How many items a collection block holds: a positive count, or a negative
/// count naming a block whose byte size follows and is passed over.
fn Cursor::block_count(self : Cursor) -> Int64 raise @types.DataError {
  let start = self.at
  let declared = self.long()
  if declared == -9223372036854775808L {
    raise malformed(
      "byte \{start} of \{self.origin}: a collection block of \{declared} items",
    )
  }
  if declared < 0L {
    ignore(self.long())
    -declared
  } else {
    declared
  }
}

///|
/// The container's header: its metadata map, its block codec and its sync
/// marker.
priv struct Header {
  metadata : Map[String, String]
  codec : Codec
  sync : Bytes
}

///|
/// The header at the cursor: the magic, the metadata map, and the sync
/// marker. Raises `ParseError` for bytes that do not open with the magic,
/// a header with more than `MAX_METADATA` entries, a codec this reader
/// does not inflate, and a file that ends inside its header.
fn read_header(cur : Cursor) -> Header raise @types.DataError {
  let size = cur.bytes.length()
  if cur.remaining() < 4 {
    raise malformed("a file of \{size} bytes, too short for the magic")
  }
  let magic = cur.take(4)
  if magic[0] != b'O' ||
    magic[1] != b'b' ||
    magic[2] != b'j' ||
    magic[3] != b'\x01' {
    raise malformed("byte 0: a file that does not open with the Avro magic")
  }
  let metadata : Map[String, String] = Map([])
  let mut codec_name : String? = None
  let mut codec_at = 0
  let mut entries = 0L
  while true {
    let start = cur.at
    let count = cur.block_count()
    if count == 0L {
      break
    }
    entries = entries + count
    if entries > MAX_METADATA {
      raise malformed(
        "byte \{start}: a header with more than \{MAX_METADATA} metadata entries",
      )
    }
    for _ in 0L..<count {
      let key = cur.string()
      let at = cur.at
      let value = cur.string()
      metadata[key] = value
      if key == "avro.codec" {
        codec_name = Some(value)
        codec_at = at
      }
    }
  }
  if cur.remaining() < 16 {
    raise malformed(
      "byte \{cur.at} of \{cur.origin}: a file that ends inside its sync marker",
    )
  }
  let sync = cur.take(16)
  let codec = match codec_name {
    None => NoCodec
    Some(name) => codec_named(name, codec_at)
  }
  Header::{ metadata, codec, sync, }
}

///|
/// The metadata member `key` of a container's header, which must carry it.
fn Header::text(
  self : Header,
  key : String,
  what : String,
) -> String raise @types.DataError {
  match self.metadata.get(key) {
    Some(found) => found
    None => raise malformed("\{what}: the header names no \"\{key}\"")
  }
}

///|
/// The blocks that follow a container's header, walked one at a time.
priv struct Blocks {
  bytes : Bytes
  sync : Bytes
  codec : Codec
  mut at : Int32
}

///|
/// The next block: a cursor over its inflated bytes and how many records
/// it holds, or `None` at the end of the file. A block of no records closes
/// the file — the reference writes one for a manifest list that names no
/// manifest — and nothing may follow it. Raises `ParseError` for a negative
/// record count, for a count or a size past what the file holds, for a
/// sync marker that differs from the file's, for bytes past a closing
/// block, and for a block that inflates to fewer bytes than its records
/// need.
fn Blocks::next(self : Blocks) -> (Cursor, Int64)? raise @types.DataError {
  if self.at >= self.bytes.length() {
    return None
  }
  let at = self.at
  let cur = Cursor::{ bytes: self.bytes, at: self.at, origin: "the file", }
  let count = cur.long()
  if count < 0L {
    raise malformed("byte \{at}: a block of \{count} records")
  }
  let size = cur.long()
  if size < 0L || size > (cur.remaining() - 16).to_int64() {
    raise malformed(
      "byte \{at}: a block of \{size} bytes, past what the file holds",
    )
  }
  let payload = cur.take(size.to_int())
  let marker_at = cur.at
  let marker = cur.take(16)
  if !same_bytes(marker, self.sync) {
    raise malformed(
      "byte \{marker_at}: a block whose sync marker differs from the file's",
    )
  }
  self.at = cur.at
  if count == 0L {
    if cur.remaining() != 0 {
      raise malformed(
        "byte \{cur.at}: \{cur.remaining()} bytes past a block of no records",
      )
    }
    return None
  }
  let block = Cursor::{
    bytes: inflate(self.codec, payload, at),
    at: 0,
    origin: "the block at byte \{at}",
  }
  if count > block.bytes.length().to_int64() {
    raise malformed(
      "byte \{at}: a block of \{count} records in \{block.bytes.length()} bytes",
    )
  }
  Some((block, count))
}

///|
/// A container opened for reading: its header and the blocks that follow.
priv struct Container {
  header : Header
  blocks : Blocks
}

///|
/// The container in `bytes`, named `what` in its refusals.
fn open_container(
  bytes : Bytes,
  what : String,
) -> Container raise @types.DataError {
  let cur = Cursor::{ bytes, at: 0, origin: "\{what} as a file", }
  let header = read_header(cur)
  Container::{
    header,
    blocks: Blocks::{
      bytes,
      sync: header.sync,
      codec: header.codec,
      at: cur.at,
    },
  }
}
