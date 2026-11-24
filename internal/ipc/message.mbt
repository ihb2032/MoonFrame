// The Arrow IPC message layer: the encapsulated message framing of both
// the stream format and the file format, and the three message headers a
// tabular payload carries — a schema, a dictionary batch, and a record
// batch. A message is a length-prefixed FlatBuffers metadata buffer,
// padded to eight bytes, followed by its body; the current framing puts a
// continuation marker ahead of the length, and the framing before it
// (metadata version V4's first spelling) has the length alone, padded to
// cover the marker's four bytes — this reader takes both, message by
// message. The body is not touched here: a header says where the body
// lies and how long it is, so a reader can step over a message without
// decoding anything in it.

///|
/// One node of a record batch's layout tree: a field's own length and
/// null count, in the order the schema spells the fields, a parent ahead
/// of its children. A null count of `-1` says the writer did not count.
priv struct FieldNode {
  length : Int64
  null_count : Int64
}

///|
/// One buffer of a record batch's body: where it starts and how long it
/// is, both relative to the body's head.
priv struct BufferRef {
  offset : Int64
  length : Int64
}

///|
/// The codec a compressed record batch's buffers are compressed with —
/// every buffer of the batch alike. Read off a batch's header, and named
/// to the writer by the io layer.
pub(all) enum BodyCodec {
  Lz4Frame
  Zstd
}

///|
/// A record batch's header: its row count and its layout tree — the
/// nodes, and the buffers in the order the nodes' fields consume them.
priv struct BatchHeader {
  length : Int64
  nodes : Array[FieldNode]
  buffers : Array[BufferRef]
  codec : BodyCodec?
}

///|
/// What a message's header carries. The tensor headers are not a tabular
/// payload and refuse when met.
priv enum Header {
  Schema(FbTable)
  Dictionary(Int64, BatchHeader, Bool)
  Batch(BatchHeader)
}

///|
/// One message of a byte stream: its header, where its body begins, and
/// where the next message begins — the body's end, the writer having
/// padded the body the way it padded the metadata.
priv struct IpcMessage {
  header : Header
  body_at : Int32
  next : Int32
}

///|
/// What sits at a position of a byte stream: a message, or the end of the
/// stream — its end marker, or the last byte of the data.
priv enum Framed {
  Message(IpcMessage)
  End
}

///|
/// The file format's marker at both ends of a file: `ARROW1` and two
/// zero bytes at the head, `ARROW1` at the tail.
const FILE_MAGIC : Bytes = b"ARROW1"

///|
/// The head marker is padded to eight bytes.
const FILE_HEAD : Int32 = 8

///|
/// The tail: the footer's length in four bytes, then the six-byte marker.
const FILE_TAIL : Int32 = 10

///|
/// The continuation marker ahead of the current framing's length.
const CONTINUATION : Int32 = -1

///|
/// The metadata versions this reader takes: V1 through V5.
const MAX_METADATA_VERSION : Int32 = 4

///|
/// The header union's members.
const HEADER_SCHEMA : Int32 = 1

///|
const HEADER_DICTIONARY : Int32 = 2

///|
const HEADER_BATCH : Int32 = 3

///|
fn unsupported_ipc(what : String) -> @types.DataError {
  @types.DataError::Unsupported("Arrow IPC: \{what}")
}

///|
/// The record batch whose header is the table `table`.
fn read_batch_header(table : FbTable) -> BatchHeader raise @types.DataError {
  let length = table.i64(0)
  let rows = match length {
    Some(n) => n
    None => 0L
  }
  if rows < 0L || rows > 2147483647L {
    raise malformed("a record batch's row count leaves the Int32 range")
  }
  let nodes : Array[FieldNode] = []
  let node_vector = table.vector(1)
  if node_vector is Some(v) {
    for i in 0..<v.len {
      let at = v.struct_at(i, 16)
      nodes.push({
        length: fb_i64(v.bytes, at),
        null_count: fb_i64(v.bytes, at + 8),
      })
    }
  }
  let buffers : Array[BufferRef] = []
  let buffer_vector = table.vector(2)
  if buffer_vector is Some(v) {
    for i in 0..<v.len {
      let at = v.struct_at(i, 16)
      buffers.push({
        offset: fb_i64(v.bytes, at),
        length: fb_i64(v.bytes, at + 8),
      })
    }
  }
  let codec = read_body_codec(table.table(3))
  { length: rows, nodes, buffers, codec, }
}

///|
/// The codec a batch's compression table names, `None` for an
/// uncompressed batch: `0` is LZ4 frames and `1` Zstandard, and a table
/// that leaves the field out names the first, the schema's default. The
/// method field beside it is not read: it spells whether a buffer is
/// compressed, which each buffer's own prefix says.
fn read_body_codec(table : FbTable?) -> BodyCodec? raise @types.DataError {
  match table {
    None => None
    Some(compression) => {
      let codec = compression.u8(0)
      if codec is None || codec is Some(0) {
        Some(Lz4Frame)
      } else if codec is Some(1) {
        Some(Zstd)
      } else {
        raise malformed(
          "a record batch names a compression codec it does not carry",
        )
      }
    }
  }
}

///|
/// The message whose metadata is `meta`: the body begins right after the
/// metadata, at `body_at`, and runs the length the header declares. The
/// body must end by `end`, the end of the message region.
fn read_message(
  meta : Bytes,
  body_at : Int32,
  end : Int32,
) -> IpcMessage raise @types.DataError {
  let table = fb_root(meta)
  let version = table.i16(0)
  if version is Some(v) && v > MAX_METADATA_VERSION {
    raise unsupported_ipc("a metadata version past V5 (this one is \{v + 1})")
  }
  let header_type = table.u8(1)
  let body_length = table.i64(3)
  let body_rows = match body_length {
    Some(n) => n
    None => 0L
  }
  if body_rows < 0L || body_rows > 2147483647L {
    raise malformed("a message's body length leaves the Int32 range")
  }
  let next = body_at.to_int64() + body_rows
  if next > end.to_int64() {
    raise malformed("a message's body is truncated")
  }
  let header = match header_type {
    Some(HEADER_SCHEMA) =>
      match table.table(2) {
        Some(schema) => Schema(schema)
        None => raise malformed("a schema message carries no schema")
      }
    Some(HEADER_DICTIONARY) =>
      match table.table(2) {
        Some(dictionary) => read_dictionary_header(dictionary)
        None => raise malformed("a dictionary message carries no batch")
      }
    Some(HEADER_BATCH) =>
      match table.table(2) {
        Some(batch) => Batch(read_batch_header(batch))
        None => raise malformed("a record batch message carries no batch")
      }
    Some(_) =>
      raise unsupported_ipc(
        "a tensor or sparse tensor message, which is not a tabular payload",
      )
    None => raise malformed("a message names no header")
  }
  { header, body_at, next: next.to_int(), }
}

///|
/// The dictionary batch a message header spells: the dictionary's id,
/// the batch that carries its values, and whether the batch extends the
/// dictionary already read rather than replacing it.
fn read_dictionary_header(table : FbTable) -> Header raise @types.DataError {
  let id = table.i64(0)
  let delta = table.boolean(2)
  match table.table(1) {
    Some(data) =>
      Dictionary(
        match id {
          Some(v) => v
          None => 0L
        },
        read_batch_header(data),
        match delta {
          Some(d) => d
          None => false
        },
      )
    None => raise malformed("a dictionary message carries no batch")
  }
}

///|
/// What sits at `pos` in `data`, whose message region ends at `end`: the
/// message that begins there, or the end of the stream. The end is the
/// end marker (a zero length after the continuation marker) or the last
/// byte of the region — the framing before the marker wrote no end marker
/// at all, so a stream that simply stops is a complete stream.
fn frame_message(
  data : Bytes,
  pos : Int32,
  end : Int32,
) -> Framed raise @types.DataError {
  if pos == end {
    return End
  }
  if pos > end || end > data.length() || !fb_fits(data, pos, 4) {
    raise malformed("a message's length prefix is truncated")
  }
  let first = fb_i32(data, pos)
  let (prefix, meta_length) = if first == CONTINUATION {
    if !fb_fits(data, pos, 8) {
      raise malformed("a message's length prefix is truncated")
    }
    let declared = fb_i32(data, pos + 4)
    if declared == 0 {
      return End
    }
    (8, declared)
  } else if first == 0 {
    // The framing before the continuation marker ends a stream with a
    // zero length alone.
    return End
  } else {
    (4, first)
  }
  // The smallest FlatBuffers message — a root offset and one empty table —
  // does not fit in less; a length under it is not a message.
  if meta_length < 8 {
    raise malformed("a message's metadata length is not one a message has")
  }
  let meta_at = pos + prefix
  if !fb_fits(data, meta_at, meta_length) ||
    meta_at.to_int64() + meta_length.to_int64() > end.to_int64() {
    raise malformed("a message's metadata is truncated")
  }
  let meta = Bytes::makei(meta_length, i => data[meta_at + i])
  Message(read_message(meta, meta_at + meta_length, end))
}

///|
/// Where the message region of a payload ends: the footer's position for
/// the file format, the end of the data for the stream format. A file is
/// recognised by its head marker, which must come back at the tail around
/// a footer length that lands the footer inside the file.
fn message_region(bytes : Bytes) -> (Int32, Int32) raise @types.DataError {
  let len = bytes.length()
  if fb_fits(bytes, 0, FILE_HEAD) && looks_like_file_head(bytes) {
    if len < FILE_HEAD + FILE_TAIL {
      raise malformed("an Arrow file is too short to hold a footer")
    }
    let footer_length = fb_i32(bytes, len - FILE_TAIL)
    let footer_at = len - FILE_TAIL - footer_length
    if footer_length < 0 || footer_at < FILE_HEAD || !file_tail_is_marker(bytes) {
      raise malformed("an Arrow file's footer length leaves the file")
    }
    (FILE_HEAD, footer_at)
  } else {
    (0, len)
  }
}

///|
/// Whether the payload opens with the file format's head marker: the six
/// bytes of `ARROW1` and two zero bytes. The caller has made sure the
/// eight bytes are there.
fn looks_like_file_head(bytes : Bytes) -> Bool {
  for i in 0..<6 {
    if bytes[i] != FILE_MAGIC[i] {
      return false
    }
  }
  bytes[6] == b'\x00' && bytes[7] == b'\x00'
}

///|
fn file_tail_is_marker(bytes : Bytes) -> Bool {
  let len = bytes.length()
  for i in 0..<6 {
    if bytes[len - 6 + i] != FILE_MAGIC[i] {
      return false
    }
  }
  true
}
