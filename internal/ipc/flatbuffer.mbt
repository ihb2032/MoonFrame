// The FlatBuffers wire format the Arrow metadata speaks — a minimal,
// bounds-checked reader over `Bytes`. Nothing here is generated code: the
// caller asks a table for a field by its id and gets the value, an option
// that is `None` when the field is absent, or a refusal when a vtable, an
// offset, or a length would leave the buffer — so a truncated or hostile
// message surfaces as a located error upstream instead of a bounds abort.
// The metadata is little-endian whoever wrote the file; the body's
// endianness is the schema's own and is read by the record-batch decoder.

///|
/// Every refusal the metadata reader raises: the payload is not a message
/// this reader can walk.
fn malformed(what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("malformed Arrow IPC: \{what}"),
  )
}

///|
/// Whether `width` bytes at `at` sit inside `bytes` — the subtraction
/// form, so a hostile offset near the `Int32` ceiling cannot fold
/// `at + width` back inside the bound.
fn fb_fits(bytes : Bytes, at : Int32, width : Int32) -> Bool {
  at >= 0 && width <= bytes.length() - at
}

///|
fn fb_u8(bytes : Bytes, at : Int32) -> Int32 raise @types.DataError {
  if fb_fits(bytes, at, 1) {
    bytes[at].to_int()
  } else {
    raise malformed("a message ends inside a byte field")
  }
}

///|
fn fb_u16(bytes : Bytes, at : Int32) -> Int32 raise @types.DataError {
  if fb_fits(bytes, at, 2) {
    bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
  } else {
    raise malformed("a message ends inside a 16-bit field")
  }
}

///|
/// An unsigned 32-bit little-endian integer that must fit a signed
/// `Int32`: every offset and length the metadata carries does, and one
/// that does not is a hostile value, not a buffer this reader can walk.
fn fb_u32(bytes : Bytes, at : Int32) -> Int32 raise @types.DataError {
  if fb_fits(bytes, at, 4) {
    let high = bytes[at + 3].to_int()
    if high >= 128 {
      raise malformed("an offset or length past 2^31")
    }
    bytes[at].to_int() |
    (bytes[at + 1].to_int() << 8) |
    (bytes[at + 2].to_int() << 16) |
    (high << 24)
  } else {
    raise malformed("a message ends inside a 32-bit field")
  }
}

///|
fn fb_i16(bytes : Bytes, at : Int32) -> Int32 raise @types.DataError {
  fb_u16(bytes, at) << 16 >> 16
}

///|
fn fb_i32(bytes : Bytes, at : Int32) -> Int32 raise @types.DataError {
  if fb_fits(bytes, at, 4) {
    bytes[at].to_int() |
    (bytes[at + 1].to_int() << 8) |
    (bytes[at + 2].to_int() << 16) |
    (bytes[at + 3].to_int() << 24)
  } else {
    raise malformed("a message ends inside a 32-bit field")
  }
}

///|
fn fb_i64(bytes : Bytes, at : Int32) -> Int64 raise @types.DataError {
  if fb_fits(bytes, at, 8) {
    let mut v : UInt64 = 0UL
    for i in [7, 6, 5, 4, 3, 2, 1, 0] {
      v = (v << 8) | bytes[at + i].to_int().to_uint64()
    }
    v.reinterpret_as_int64()
  } else {
    raise malformed("a message ends inside a 64-bit field")
  }
}

///|
/// One table's place in a metadata buffer: the buffer and the position
/// of the table's own soffset.
priv struct FbTable {
  bytes : Bytes
  pos : Int32
}

///|
/// The position a `u32` at `at` points to — the offset is relative to
/// its own position.
fn fb_indirect(bytes : Bytes, at : Int32) -> Int32 raise @types.DataError {
  // Summed in 64 bits, so an offset near the ceiling cannot wrap.
  let target = at.to_int64() + fb_u32(bytes, at).to_int64()
  if target < bytes.length().to_int64() {
    target.to_int()
  } else {
    raise malformed("an offset leaves the message")
  }
}

///|
/// The root table of a metadata buffer — the `u32` at its head points to
/// it.
fn fb_root(bytes : Bytes) -> FbTable raise @types.DataError {
  let pos = fb_indirect(bytes, 0)
  if pos >= 4 {
    { bytes, pos, }
  } else {
    raise malformed("the root table overlaps the root offset")
  }
}

///|
/// The position of field `id`'s value in the table, or `None` when the
/// table's vtable ends before the field or marks it absent. Raises when
/// the soffset or the vtable itself leaves the buffer.
fn FbTable::field(self : FbTable, id : Int32) -> Int32? raise @types.DataError {
  let soffset = fb_i32(self.bytes, self.pos)
  let vtable = self.pos.to_int64() - soffset.to_int64()
  if vtable < 0 || vtable + 2 > self.bytes.length().to_int64() {
    raise malformed("a table's vtable leaves the message")
  }
  let size = fb_u16(self.bytes, vtable.to_int())
  let entry = vtable + 4 + 2 * id.to_int64()
  let inside = size >= 4 && entry + 2 <= vtable + size.to_int64()
  if !inside {
    return None
  }
  let offset = fb_u16(self.bytes, entry.to_int())
  if offset == 0 {
    None
  } else {
    let at = self.pos.to_int64() + offset.to_int64()
    if at < self.bytes.length().to_int64() {
      Some(at.to_int())
    } else {
      raise malformed("a field offset leaves the message")
    }
  }
}

///|
fn FbTable::i16(self : FbTable, id : Int32) -> Int32? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    Some(fb_i16(self.bytes, p))
  } else {
    None
  }
}

///|
fn FbTable::i32(self : FbTable, id : Int32) -> Int32? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    Some(fb_i32(self.bytes, p))
  } else {
    None
  }
}

///|
fn FbTable::i64(self : FbTable, id : Int32) -> Int64? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    Some(fb_i64(self.bytes, p))
  } else {
    None
  }
}

///|
/// A `bool` field — a byte, non-zero meaning `true`.
fn FbTable::boolean(self : FbTable, id : Int32) -> Bool? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    Some(fb_u8(self.bytes, p) != 0)
  } else {
    None
  }
}

///|
/// The table a field points to.
fn FbTable::table(
  self : FbTable,
  id : Int32,
) -> FbTable? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    Some({ bytes: self.bytes, pos: fb_indirect(self.bytes, p), })
  } else {
    None
  }
}

///|
/// The text a string field carries, decoded from its UTF-8 bytes.
fn FbTable::text(self : FbTable, id : Int32) -> String? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    let start = fb_indirect(self.bytes, p)
    let len = fb_u32(self.bytes, start)
    let from = start + 4
    if !fb_fits(self.bytes, from, len) {
      raise malformed("a string leaves the message")
    }
    let source = self.bytes
    let bytes = Bytes::makei(len, i => source[from + i])
    let text = @utf8.decode(bytes) catch {
      _ => raise malformed("a string is not UTF-8")
    }
    Some(text)
  } else {
    None
  }
}

///|
/// A vector's elements: where the first one starts and how many there
/// are. The count is read once, here; an element is read by its index
/// from the start.
priv struct FbVector {
  bytes : Bytes
  start : Int32
  len : Int32
}

///|
fn FbTable::vector(
  self : FbTable,
  id : Int32,
) -> FbVector? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    // The count's own read bounded the buffer, so the first element's
    // place is inside it.
    let count_at = fb_indirect(self.bytes, p)
    let len = fb_u32(self.bytes, count_at)
    Some({ bytes: self.bytes, start: count_at + 4, len, })
  } else {
    None
  }
}

///|
/// The position of element `index` of a vector of inline structs `width`
/// bytes wide, refusing an index past the vector and a vector that leaves
/// the message.
fn FbVector::struct_at(
  self : FbVector,
  index : Int32,
  width : Int32,
) -> Int32 raise @types.DataError {
  // Every caller indexes inside `0..<len`.
  let at = self.start.to_int64() + index.to_int64() * width.to_int64()
  if at + width.to_int64() <= self.bytes.length().to_int64() {
    at.to_int()
  } else {
    raise malformed("a struct vector leaves the message")
  }
}

///|
/// A vector of tables, read whole: each element is an offset to its
/// table.
fn FbTable::tables(
  self : FbTable,
  id : Int32,
) -> Array[FbTable]? raise @types.DataError {
  let vector = self.vector(id)
  if vector is Some(v) {
    let out : Array[FbTable] = []
    for i in 0..<v.len {
      let slot = v.struct_at(i, 4)
      out.push({ bytes: v.bytes, pos: fb_indirect(v.bytes, slot), })
    }
    Some(out)
  } else {
    None
  }
}

///|
/// A `ubyte` field — the type of a union's member.
fn FbTable::u8(self : FbTable, id : Int32) -> Int32? raise @types.DataError {
  let at = self.field(id)
  if at is Some(p) {
    Some(fb_u8(self.bytes, p))
  } else {
    None
  }
}
