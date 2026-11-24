// The FlatBuffers writer, the counterpart of the reader: a buffer built
// from its tail forward, the way every FlatBuffers builder works. What is
// written first lands at the end of the finished buffer, and the finished
// buffer is the build array reversed — so a table can be written after the
// strings, vectors, and tables it points to, when their places are known.
// A place is a mark: the length of the build array right after the thing
// was written, which is its distance from the finished buffer's end.

///|
/// The build array, back to front, and the largest alignment anything in
/// it asked for.
priv struct Fb {
  buf : Array[Byte]
  mut align : Int32
}

///|
fn Fb::new() -> Fb {
  { buf: [], align: 1, }
}

///|
/// A mark: where the thing just written starts, as its distance from the
/// finished buffer's end.
fn Fb::mark(self : Fb) -> Int32 {
  self.buf.length()
}

///|
/// Pad until what is written next starts on an `alignment` boundary. The
/// finished buffer is padded to the largest of them, so a distance from
/// its end is aligned exactly when the build array's length is.
fn Fb::align_to(self : Fb, alignment : Int32) -> Unit {
  if alignment > self.align {
    self.align = alignment
  }
  while self.buf.length() % alignment != 0 {
    self.buf.push((0).to_byte())
  }
}

///|
/// An integer `width` bytes wide, little-endian in the finished buffer:
/// its most significant byte goes first.
fn Fb::push_int(self : Fb, v : Int64, width : Int32) -> Unit {
  for i = width - 1; i >= 0; i = i - 1 {
    self.buf.push(((v >> (8 * i).to_int()) & 0xFFL).to_byte())
  }
}

///|
fn Fb::u8(self : Fb, v : Int32) -> Unit {
  self.push_int(v.to_int64(), 1)
}

///|
fn Fb::boolean(self : Fb, v : Bool) -> Unit {
  self.u8(if v { 1 } else { 0 })
}

///|
fn Fb::i16(self : Fb, v : Int32) -> Unit {
  self.align_to(2)
  self.push_int(v.to_int64(), 2)
}

///|
fn Fb::i32(self : Fb, v : Int32) -> Unit {
  self.align_to(4)
  self.push_int(v.to_int64(), 4)
}

///|
fn Fb::i64(self : Fb, v : Int64) -> Unit {
  self.align_to(8)
  self.push_int(v, 8)
}

///|
/// The unsigned offset a field holds when it points to what `target`
/// marks. It is relative to the field's own place: the distance from the
/// field's far end to the target.
fn Fb::offset(self : Fb, target : Int32) -> Unit {
  self.align_to(4)
  self.push_int((self.buf.length() + 4 - target).to_int64(), 4)
}

///|
/// The field of a table that points to what `target` marks — a string, a
/// vector, or another table. Answers the field's own mark, which is what
/// a table's builder records for the field.
fn Fb::refer(self : Fb, target : Int32) -> Int32 {
  self.offset(target)
  self.mark()
}

///|
/// A string: the byte count, then the bytes, then a zero after them — and
/// the count is where a field's offset points. The count and the bytes sit
/// side by side, so the padding that keeps the count on a four-byte
/// boundary goes after the zero, and is written first. Answers the
/// string's mark.
fn Fb::string(self : Fb, text : String) -> Int32 {
  let bytes = @utf8.encode(text)
  self.require(4)
  while (self.buf.length() + bytes.length() + 1) % 4 != 0 {
    self.buf.push((0).to_byte())
  }
  self.buf.push((0).to_byte())
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    self.buf.push(bytes[i])
  }
  self.push_int(bytes.length().to_int64(), 4)
  self.mark()
}

///|
/// Note an alignment the finished buffer is padded to, without padding
/// for it here.
fn Fb::require(self : Fb, alignment : Int32) -> Unit {
  if alignment > self.align {
    self.align = alignment
  }
}

///|
/// A vector of `count` elements, each written by `element` from the last
/// to the first — an element of a table vector is an offset to its table,
/// written `offset(mark)`. Answers the vector's mark, the place of its
/// count.
fn Fb::vector(self : Fb, count : Int32, element : (Int32) -> Unit) -> Int32 {
  for i = count - 1; i >= 0; i = i - 1 {
    self.align_to(4)
    element(i)
  }
  self.i32(count)
  self.mark()
}

///|
/// A vector of `count` inline structs, each written by `element` from the
/// last to the first. Every struct starts on an eight-byte boundary,
/// which puts the count ahead of it on a four-byte one.
fn Fb::structs(self : Fb, count : Int32, element : (Int32) -> Unit) -> Int32 {
  for i = count - 1; i >= 0; i = i - 1 {
    self.align_to(8)
    element(i)
  }
  self.i32(count)
  self.mark()
}

///|
/// One field of a table as its builder records it: the field's id, the
/// mark after the field was written, and the field's width in bytes.
priv struct FieldMark {
  id : Int32
  mark : Int32
  width : Int32
}

///|
/// Finish the table whose fields were written already, highest id first.
/// The table is its soffset to a vtable that is written right before it,
/// so the soffset is the vtable's length; the vtable holds the table's own
/// length and, per field, the field's distance from the table's start,
/// zero for a field the table leaves out. Answers the table's mark.
fn Fb::table(self : Fb, fields : Array[FieldMark]) -> Int32 {
  let entries = 1 + highest_id(fields)
  let size = 4 + 2 * entries
  self.align_to(4)
  self.i32(size)
  let start = self.mark()
  for id = entries - 1; id >= 0; id = id - 1 {
    self.i16(field_offset(fields, id, start))
  }
  self.i16(4 + widest(fields, start))
  self.i16(size)
  start
}

///|
/// The highest field id a table's fields name: zero for a table with none.
fn highest_id(fields : Array[FieldMark]) -> Int32 {
  let mut highest = -1
  for field in fields {
    if field.id > highest {
      highest = field.id
    }
  }
  highest
}

///|
/// A field's distance from the table's start — four bytes, the soffset,
/// and on to where the field was written — or zero when no field of that
/// id is present.
fn field_offset(fields : Array[FieldMark], id : Int32, start : Int32) -> Int32 {
  for field in fields {
    if field.id == id {
      return start - field.mark
    }
  }
  0
}

///|
/// How far the table runs past its start: to the end of its widest field.
fn widest(fields : Array[FieldMark], start : Int32) -> Int32 {
  let mut end = 0
  for field in fields {
    let reach = start - field.mark + field.width
    if reach > end {
      end = reach
    }
  }
  end
}

///|
/// The finished buffer: the build array reversed, with the root offset —
/// the last four bytes written — at its head, padded at its end to a
/// multiple of eight, the alignment an encapsulated message's metadata
/// keeps. A mark is a distance from the root offset's far end, so that
/// end is what the build is padded to the largest alignment for, root
/// offset included.
fn Fb::finish(self : Fb, root : Int32) -> Bytes {
  while (self.buf.length() + 4) % self.align != 0 {
    self.buf.push((0).to_byte())
  }
  self.offset(root)
  let len = self.buf.length()
  let source = self.buf
  let out = Bytes::makei(len, i => source[len - 1 - i])
  let padding = (8 - out.length() % 8) % 8
  if padding == 0 {
    out
  } else {
    Bytes::makei(len + padding, i => {
      if i < len {
        source[len - 1 - i]
      } else {
        (0).to_byte()
      }
    })
  }
}
