// The Thrift compact protocol the parquet metadata speaks — a minimal,
// parquet-shaped reader and writer over `Bytes`: the varint / zigzag
// integer codings, the field-header delta scheme, the boolean field
// types, binary, and lists, exactly as the parquet thrift bindings
// encode them. Structs themselves are not modelled: the reader yields
// field events (id + wire type) and the caller decodes the fields it
// knows, skipping the rest by wire type — the forward-compatibility
// rule every thrift reader applies.

///|
/// A field's compact wire type — the low nibble of a field header.
priv enum WireType {
  Stop
  BoolTrue
  BoolFalse
  I32V // byte / i16 / i32 share the varint coding
  I64V
  BinaryV
  ListV
  StructV
}

///|
/// One decoded field header: the field id (absolute, already un-delta'd)
/// and its wire type. `Stop` is the struct terminator.
priv struct FieldHeader {
  id : Int32
  wire : WireType
}

///|
/// The reader cursor — an offset into a byte array with the compact
/// primitives decoded in place. Every method advances; a malformed
// sequence refuses with `None` / `false` rather than aborting, so a
// truncated or hostile footer surfaces as a located error upstream.
priv struct ThriftReader {
  bytes : Bytes
  mut pos : Int32
}

///|
/// The reader over a byte slice, starting at its head.
fn thrift_reader(bytes : Bytes) -> ThriftReader {
  { bytes, pos: 0, }
}

///|
/// The next byte as an unsigned value, or `None` at the end of the
/// buffer — the bounds check every read funnels through.
fn ThriftReader::byte(self : ThriftReader) -> Int32? {
  if self.pos >= 0 && self.pos < self.bytes.length() {
    let v = self.bytes[self.pos].to_int()
    self.pos = self.pos + 1
    Some(v)
  } else {
    None
  }
}

///|
/// An unsigned LEB128 varint — the compact protocol's length prefix and
/// integer carrier.
fn ThriftReader::varint(self : ThriftReader) -> UInt64? {
  let mut result : UInt64 = 0UL
  let mut shift = 0
  for _ in 0..<10 {
    match self.byte() {
      Some(b) => {
        result = result | ((b & 0x7F).to_uint64() << shift)
        if b < 0x80 {
          return Some(result)
        }
        shift = shift + 7
      }
      None => return None
    }
  }
  None
}

///|
/// A zigzag-coded signed 64-bit integer.
fn ThriftReader::zigzag_i64(self : ThriftReader) -> Int64? {
  match self.varint() {
    Some(u) => {
      let value = (u >> 1).reinterpret_as_int64()
      if (u & 1UL) == 0UL {
        Some(value)
      } else {
        Some(value ^ -1L)
      }
    }
    None => None
  }
}

///|
/// A zigzag-coded signed 32-bit integer (the i32 fields the parquet
/// metadata carries — enums, sizes, precisions).
fn ThriftReader::zigzag_i32(self : ThriftReader) -> Int32? {
  match self.zigzag_i64() {
    Some(v) =>
      if v >= -2147483648L && v <= 2147483647L {
        Some(v.to_int())
      } else {
        None
      }
    None => None
  }
}

///|
/// A length-prefixed byte string.
fn ThriftReader::binary(self : ThriftReader) -> Bytes? {
  match self.varint() {
    Some(len) => {
      if len > 0x1000_0000UL {
        return None
      }
      let n = len.to_int()
      // The subtraction form: `pos` never passes the buffer's length,
      // so it cannot wrap, while `pos + n` folds back inside on a
      // hostile length near the Int32 ceiling.
      if n < 0 || n > self.bytes.length() - self.pos {
        return None
      }
      let start = self.pos
      let source = self.bytes
      let out = Bytes::makei(n, i => source[start + i])
      self.pos = self.pos + n
      Some(out)
    }
    None => None
  }
}

///|
/// A length-prefixed byte string as `String` (the schema names and
/// paths the metadata carries are UTF-8 text — decoded strictly, a
/// malformed sequence is a malformed field, not a lossy name).
fn ThriftReader::text(self : ThriftReader) -> String? {
  match self.binary() {
    Some(b) => Some(@utf8.decode(b)) catch { _ => None }
    None => None
  }
}

///|
/// The next field header of a struct, or `None` past the end. A field
// id delta above 15 carries its own zigzag id; a stop byte ends the
// struct.
fn ThriftReader::field_header(
  self : ThriftReader,
  last_id : Int32,
) -> FieldHeader? {
  match self.byte() {
    None => None
    Some(b) => {
      let nibble = b & 0x0F
      if nibble == 0 {
        return Some({ id: 0, wire: Stop, })
      }
      let wire : WireType = match nibble {
        1 => BoolTrue
        2 => BoolFalse
        3 | 4 | 5 => I32V
        6 => I64V
        8 => BinaryV
        9 | 10 => ListV
        12 => StructV
        _ => return None
      }
      let delta = b >> 4
      if delta == 0 {
        match self.zigzag_i32() {
          Some(id) => Some({ id, wire, })
          None => None
        }
      } else {
        Some({ id: last_id + delta, wire, })
      }
    }
  }
}

///|
/// Skip one value of the given wire type — the unknown-field rule. A
// list skips its elements by their own type; a struct skips until its
// stop byte.
fn ThriftReader::skip(self : ThriftReader, wire : WireType) -> Bool {
  match wire {
    Stop | BoolTrue | BoolFalse => true
    I32V | I64V => self.varint() is Some(_)
    BinaryV => self.binary() is Some(_)
    ListV =>
      match self.byte() {
        None => false
        Some(h) => {
          let size = h >> 4
          let elem = h & 0x0F
          let count = if size == 15 {
            match self.varint() {
              Some(v) => v
              None => return false
            }
          } else {
            size.to_uint64()
          }
          if count > 0x1000_0000UL {
            return false
          }
          let elem_wire = match elem {
            1 | 2 => BoolTrue
            3 | 4 | 5 => I32V
            6 => I64V
            8 => BinaryV
            9 | 10 => ListV
            12 => StructV
            _ => return false
          }
          let mut ok = true
          for _ in 0..<count.to_int() {
            if !self.skip(elem_wire) {
              ok = false
              break
            }
          }
          ok
        }
      }
    StructV => self.skip_struct()
  }
}

///|
/// Skip a whole nested struct — field headers until stop.
fn ThriftReader::skip_struct(self : ThriftReader) -> Bool {
  let mut last = 0
  let mut ok = false
  for ;; {
    match self.field_header(last) {
      None => break
      Some(header) =>
        if header.wire is Stop {
          ok = true
          break
        } else if self.skip(header.wire) {
          last = header.id
        } else {
          break
        }
    }
  }
  ok
}

// ── writer ───────────────────────────────────────────────────────────

///|
/// The compact-protocol writer — appends into a growing byte buffer,
/// tracking the last field id per struct level so field headers carry
/// their delta.
priv struct ThriftWriter {
  buf : Array[Byte]
  stack : Array[Int32]
  mut last_id : Int32
}

///|
fn thrift_writer() -> ThriftWriter {
  { buf: [], stack: [], last_id: 0, }
}

///|
/// Begin a struct field: remembers the enclosing id context and resets
/// the delta base, exactly what nesting into a struct means.
fn ThriftWriter::struct_field_begin(self : ThriftWriter, id : Int32) -> Unit {
  self.field_header(id, 12)
  self.stack.push(self.last_id)
  self.last_id = 0
}

///|
/// End the innermost struct: the stop byte and the id context restored.
fn ThriftWriter::struct_end(self : ThriftWriter) -> Unit {
  self.buf.push(b'\x00')
  match self.stack.pop() {
    Some(id) => self.last_id = id
    None => self.last_id = 0
  }
}

///|
/// One field header with the delta coding; a delta outside `[1, 15]`
/// spells the absolute zigzag id after the wire byte.
fn ThriftWriter::field_header(
  self : ThriftWriter,
  id : Int32,
  wire : Int32,
) -> Unit {
  let delta = id - self.last_id
  if delta > 0 && delta <= 15 {
    self.buf.push(((delta << 4) | wire).to_byte())
  } else {
    self.buf.push(wire.to_byte())
    self.write_zigzag(id.to_int64())
  }
  self.last_id = id
}

///|
/// The zigzag varint of a signed value.
fn ThriftWriter::write_zigzag(self : ThriftWriter, v : Int64) -> Unit {
  self.write_varint(((v << 1) ^ (v >> 63)).reinterpret_as_uint64())
}

///|
/// An unsigned LEB128 varint.
fn ThriftWriter::write_varint(self : ThriftWriter, v : UInt64) -> Unit {
  let mut rest = v
  for ;; {
    if rest < 0x80UL {
      self.buf.push(rest.to_byte())
      break
    }
    self.buf.push(((rest & 0x7FUL) | 0x80UL).to_byte())
    rest = rest >> 7
  }
}

///|
/// An i32 field (byte / i16 / i32 share the varint wire).
fn ThriftWriter::i32_field(self : ThriftWriter, id : Int32, v : Int32) -> Unit {
  self.field_header(id, 5)
  self.write_zigzag(v.to_int64())
}

///|
/// An i64 field.
fn ThriftWriter::i64_field(self : ThriftWriter, id : Int32, v : Int64) -> Unit {
  self.field_header(id, 6)
  self.write_zigzag(v)
}

///|
/// A boolean field — the value rides the field header's type nibble.

///|
/// A binary field.
fn ThriftWriter::binary_field(
  self : ThriftWriter,
  id : Int32,
  v : Bytes,
) -> Unit {
  self.field_header(id, 8)
  self.write_varint(v.length().to_uint64())
  for b in v {
    self.buf.push(b)
  }
}

///|
/// A string field.
fn ThriftWriter::text_field(
  self : ThriftWriter,
  id : Int32,
  v : String,
) -> Unit {
  self.binary_field(id, @utf8.encode(v))
}

///|
/// A list header of the given element wire type.
fn ThriftWriter::list_header(
  self : ThriftWriter,
  size : Int32,
  elem_wire : Int32,
) -> Unit {
  if size < 15 {
    self.buf.push(((size << 4) | elem_wire).to_byte())
  } else {
    self.buf.push((0xF0 | elem_wire).to_byte())
    self.write_varint(size.to_uint64())
  }
}

///|
/// The accumulated bytes.
fn ThriftWriter::finish(self : ThriftWriter) -> Bytes {
  Bytes::from_array(self.buf)
}
