// The Arrow IPC reader: a payload opened once — its schema mapped field by
// field, its messages located — and its record batches decoded on demand,
// in stream order, into the columns a projection asks for. A batch's body
// is a depth-first walk: each field's node says how many cells it holds
// and how many are null, and the buffers it consumes follow — a validity
// bitmap where the field can be null, then the values' own buffers —
// ahead of its children's. A field the projection leaves out is stepped
// over by the counts its schema gives, so its buffers are never read.
//
// Every count a payload declares is bounded before anything is sized by
// it. A buffer is asked for by the most bytes its node can need: an
// uncompressed buffer may be longer (a writer pads); a compressed one may
// not inflate past it by more than that padding. A node's cell count is
// checked against its own buffers before the count allocates anything —
// the offsets of a list before its cells, the children of a struct before
// its presence — so a hostile count cannot name memory its bytes do not
// back. A null column has no buffer to be bounded by, and its cells are
// counted against a budget instead.

///|
/// The refusal for a cell or a type the mapping cannot carry: the payload
/// is well formed, and no dtype of this frame holds what it carries.
fn cannot_carry(what : String) -> @types.DataError {
  @types.DataError::Unsupported("Arrow IPC: \{what}")
}

///|
/// How many bytes past a buffer's need a writer's padding may run: the
/// largest alignment the format recommends.
const BUFFER_PADDING : Int32 = 64

///|
/// The cells a null column may hold in one batch, or one column over a
/// payload. Every other count is bounded by the bytes backing it before
/// it allocates; these two are the ones left to a budget, past which the
/// column refuses loudly instead of letting the decode build more boxed
/// cells than the process can hold.
const CELL_BUDGET : Int64 = 134217728L

///|
/// One buffer of a record batch's body as the decoder reads it: the bytes
/// it sits in — the payload's own, or the copy a compressed buffer
/// inflated into — and where it starts in them.
priv struct Buf {
  bytes : Bytes
  base : Int32
  len : Int32
}

///|
/// Refuse unless the buffer holds at least `need` bytes.
fn Buf::needs(
  self : Buf,
  need : Int64,
  what : String,
) -> Unit raise @types.DataError {
  if need < 0L || need > self.len.to_int64() {
    raise malformed(what)
  }
}

///|
/// `width` bytes at `at`, in the body's endianness, as an unsigned 64-bit
/// value.
fn Buf::uint(
  self : Buf,
  at : Int32,
  width : Int32,
  big : Bool,
) -> UInt64 raise @types.DataError {
  if at < 0 || at > self.len - width {
    raise malformed("a buffer ends inside a value")
  }
  let bytes = self.bytes
  let from = self.base + at
  let mut v : UInt64 = 0UL
  let mut i = 0
  while i < width {
    let byte = if big {
      bytes[from + i].to_uint64()
    } else {
      bytes[from + width - 1 - i].to_uint64()
    }
    v = (v << 8) | byte
    i += 1
  }
  v
}

///|
/// The integer at element `index`, `width` bytes wide — sign-extended when
/// the type is signed. An unsigned value wider than `Int64` comes back
/// negative, which its caller refuses.
fn Buf::int(
  self : Buf,
  index : Int32,
  width : Int32,
  signed : Bool,
  big : Bool,
) -> Int64 raise @types.DataError {
  let v = self.uint(index * width, width, big)
  let shift = 64 - width * 8
  if signed && shift > 0 {
    (v << shift.to_int()).reinterpret_as_int64() >> shift.to_int()
  } else {
    v.reinterpret_as_int64()
  }
}

///|
/// Bit `index` of a bitmap — the bits of a byte from the least
/// significant up, whoever wrote the body.
fn Buf::bit(self : Buf, index : Int32) -> Bool raise @types.DataError {
  let at = index / 8
  if at < 0 || at >= self.len {
    raise malformed("a bitmap ends before its node's last cell")
  }
  let byte = self.bytes[self.base + at].to_int()
  ((byte >> (index % 8)) & 1) == 1
}

///|
/// The bytes of a bitmap over `length` cells.
fn bitmap_bytes(length : Int32) -> Int64 {
  ((length + 7) / 8).to_int64()
}

///|
/// Which of a node's `length` cells are present. A node that counts no
/// nulls is all present, whatever bitmap it still carries; one that
/// counts nulls reads its bitmap; and one whose writer did not count
/// (`-1`) reads the bitmap when the node carries one and is all present
/// when it carries none. The node's cells have been bounded by their
/// buffers before this sizes anything.
fn validity_of(
  buffer : Buf,
  length : Int32,
  null_count : Int64,
) -> Array[Bool] raise @types.DataError {
  if null_count == 0L || (null_count < 0L && buffer.len == 0) {
    return Array::make(length, true)
  }
  buffer.needs(
    bitmap_bytes(length),
    "a node counts nulls its validity bitmap is too short to place",
  )
  let present : Array[Bool] = Array::make(length, true)
  for i in 0..<length {
    present[i] = buffer.bit(i)
  }
  present
}

///|
/// The dictionaries read so far, each by the id the schema gave it, with
/// the values its batches have carried — extended by a delta batch,
/// replaced by any other.
priv struct Dictionaries {
  ids : Array[Int64]
  values : Array[Array[@types.Scalar]]
}

///|
fn Dictionaries::get(self : Dictionaries, id : Int64) -> Array[@types.Scalar]? {
  for i, known in self.ids {
    if known == id {
      return Some(self.values[i])
    }
  }
  None
}

///|
fn Dictionaries::set(
  self : Dictionaries,
  id : Int64,
  cells : Array[@types.Scalar],
  delta : Bool,
) -> Unit {
  for i, known in self.ids {
    if known == id {
      if delta {
        self.values[i].append(cells)
      } else {
        self.values[i] = cells
      }
      return
    }
  }
  self.ids.push(id)
  self.values.push(cells)
}

///|
/// The decoder's place in one record batch: the body, the layout tree it
/// is walking, and the next node and buffer of it.
priv struct Decode {
  data : Bytes
  body_at : Int32
  body_len : Int32
  nodes : Array[FieldNode]
  buffers : Array[BufferRef]
  mut node : Int32
  mut buffer : Int32
  codec : BodyCodec?
  big : Bool
  dictionaries : Dictionaries
  mut column : String
}

///|
fn Decode::take_node(self : Decode) -> FieldNode raise @types.DataError {
  if self.node < 0 || self.node >= self.nodes.length() {
    raise malformed(
      "a record batch's fields ask for more nodes than it carries",
    )
  }
  let node = self.nodes[self.node]
  self.node += 1
  node
}

///|
/// The next buffer of the body, inflated when the batch is compressed.
/// `need` is the most bytes the node can read from the buffer; an
/// uncompressed buffer may be longer, a writer padding it.
fn Decode::take_buffer(
  self : Decode,
  need : Int64,
) -> Buf raise @types.DataError {
  if self.buffer < 0 || self.buffer >= self.buffers.length() {
    raise malformed(
      "a record batch's fields ask for more buffers than it carries",
    )
  }
  let reference = self.buffers[self.buffer]
  self.buffer += 1
  if reference.offset < 0L ||
    reference.length < 0L ||
    reference.offset > self.body_len.to_int64() - reference.length {
    raise malformed("a buffer leaves its record batch's body")
  }
  let at = self.body_at + reference.offset.to_int()
  let len = reference.length.to_int()
  match self.codec {
    None => Buf::{ bytes: self.data, base: at, len, }
    // An empty buffer of a compressed batch carries no header at all.
    Some(_) if len == 0 => Buf::{ bytes: self.data, base: at, len, }
    Some(codec) => self.inflated(codec, at, len, need)
  }
}

///|
/// The next buffer of the body, held to at least `need` bytes.
fn Decode::bounded(
  self : Decode,
  need : Int64,
  what : String,
) -> Buf raise @types.DataError {
  let buffer = self.take_buffer(need)
  buffer.needs(need, what)
  buffer
}

///|
/// The header every non-empty buffer of a compressed batch opens with:
/// the uncompressed length as an `Int64`, or `-1` when the writer stored
/// the buffer as it is.
const COMPRESSED_HEADER : Int32 = 8

///|
/// One non-empty buffer of a compressed batch, read from the header it
/// opens with.
fn Decode::inflated(
  self : Decode,
  codec : BodyCodec,
  at : Int32,
  len : Int32,
  need : Int64,
) -> Buf raise @types.DataError {
  if len < COMPRESSED_HEADER {
    raise malformed("a compressed buffer is shorter than its header")
  }
  let declared = fb_i64(self.data, at)
  if declared == -1L {
    {
      bytes: self.data,
      base: at + COMPRESSED_HEADER,
      len: len - COMPRESSED_HEADER,
    }
  } else if declared < 0L {
    raise malformed("a compressed buffer's header is negative")
  } else if declared > need + BUFFER_PADDING.to_int64() {
    raise malformed(
      "a compressed buffer declares \{declared} bytes, more than the \{need} its node can read",
    )
  } else {
    inflate_buffer(
      codec,
      self.data.clamped_view(start=at + COMPRESSED_HEADER, end=at + len),
      declared.to_int(),
    )
  }
}

///|
/// The decoder's place after every field is read: the nodes and the
/// buffers are spent exactly, with none the schema does not account for.
fn Decode::settled(self : Decode) -> Unit raise @types.DataError {
  if self.node != self.nodes.length() || self.buffer != self.buffers.length() {
    raise malformed(
      "a record batch carries nodes or buffers its schema does not account for",
    )
  }
}

///|
/// Step over a field's whole subtree without reading a byte of it.
fn Decode::skip(self : Decode, plan : FieldPlan) -> Unit raise @types.DataError {
  let buffers = plan.buffer_count()
  if buffers < 0 {
    raise cannot_carry(
      "column \"\{plan.name}\" carries \{plan.refusal}, whose layout this reader cannot step over",
    )
  }
  let nodes = plan.node_count()
  if nodes > self.nodes.length() - self.node ||
    buffers > self.buffers.length() - self.buffer {
    raise malformed("a record batch's fields ask for more than it carries")
  }
  self.node += nodes
  self.buffer += buffers
}

///|
/// A node's cell count, within the `Int32` a column is indexed by.
fn node_length(node : FieldNode) -> Int32 raise @types.DataError {
  if node.length < 0L || node.length > 2147483647L {
    raise malformed("a node's cell count leaves the Int32 range")
  }
  node.length.to_int()
}

///|
/// The dtype a field reads as.
fn carried_dtype(plan : FieldPlan) -> @types.DataType raise @types.DataError {
  match plan.dtype {
    Some(dtype) => dtype
    None => raise refuse_field(plan, plan.name)
  }
}

///|
/// The refusal a field the mapping does not carry meets when decoded.
fn refuse_field(plan : FieldPlan, column : String) -> @types.DataError {
  cannot_carry(
    "column \"\{column}\" carries \{plan.refusal}, which has no dtype to read as",
  )
}

///|
/// Decode one field's node into its cells. A dictionary-encoded field's
/// node carries indices into the dictionary its batches carried; the
/// dictionary's own values are the same field without the encoding, which
/// is what `decode_values` reads.
fn decode_field(
  d : Decode,
  plan : FieldPlan,
) -> Array[@types.Scalar] raise @types.DataError {
  let node = d.take_node()
  let length = node_length(node)
  if plan.encoded {
    if plan.shape is Refused {
      raise refuse_field(plan, d.column)
    }
    let width = plan.index_bit_width / 8
    if width != 1 && width != 2 && width != 4 && width != 8 {
      raise cannot_carry(
        "column \"\{d.column}\" carries dictionary indices of \{plan.index_bit_width} bits",
      )
    }
    let validity = d.take_buffer(bitmap_bytes(length))
    let indices = d.bounded(
      length.to_int64() * width.to_int64(),
      "a dictionary's indices end before its node's last cell",
    )
    let values = match d.dictionaries.get(plan.dictionary_id) {
      Some(v) => v
      None =>
        raise malformed(
          "a record batch reads dictionary \{plan.dictionary_id} before a batch carries it",
        )
    }
    let present = validity_of(validity, length, node.null_count)
    let count = values.length().to_int64()
    let cells : Array[@types.Scalar] = []
    for i in 0..<length {
      if present[i] {
        let index = indices.int(i, width, plan.index_signed, d.big)
        if index < 0L || index >= count {
          raise cannot_carry(
            "column \"\{d.column}\" carries a dictionary index (\{index}) past its dictionary's \{values.length()} values",
          )
        }
        cells.push(values[index.to_int()])
      } else {
        cells.push(@types.Scalar::Null)
      }
    }
    return cells
  }
  decode_values(d, plan, node, length)
}

///|
/// Decode one field's node by its type's own layout — the path a plain
/// field takes, and the one a dictionary batch's values take. Every
/// branch takes the node's buffers and bounds the node's cells by them
/// before a cell count sizes anything.
fn decode_values(
  d : Decode,
  plan : FieldPlan,
  node : FieldNode,
  length : Int32,
) -> Array[@types.Scalar] raise @types.DataError {
  match plan.shape {
    Refused => raise refuse_field(plan, d.column)
    Nulls => {
      // No buffer bounds a null column; the budget does.
      if length.to_int64() > CELL_BUDGET {
        raise cannot_carry(
          "column \"\{d.column}\" is a null column of \{length} cells, past the \{CELL_BUDGET}-cell budget",
        )
      }
      Array::make(length, @types.Scalar::Null)
    }
    Leaf(leaf) => leaf_cells(d, leaf, node, length)
    List(fixed, wide) => {
      let validity = d.take_buffer(bitmap_bytes(length))
      // A variable-size list's offsets are bounded before its child is
      // decoded; a fixed-size list's cells are bounded by the child alone.
      let spans = if fixed > 0 {
        ListSpans::Fixed(fixed)
      } else {
        ListSpans::Offsets(list_offsets(d, wide, length))
      }
      let values = decode_field(d, plan.children[0])
      // The offsets are relative to the buffer's first, which a sliced
      // array does not leave at zero, and together they span the child.
      let base = spans.start(0)
      if base < 0L || spans.start(length) - base != values.length().to_int64() {
        raise malformed(
          "a list's child holds a different number of values than its offsets span",
        )
      }
      let present = validity_of(validity, length, node.null_count)
      let cells : Array[@types.Scalar] = []
      for i in 0..<length {
        if present[i] {
          let from = (spans.start(i) - base).to_int()
          let to = (spans.end(i) - base).to_int()
          cells.push(
            @types.Scalar::List(
              @types.ListValue::ListValue(values[from:to].to_owned()),
            ),
          )
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
      cells
    }
    Struct => {
      let validity = d.take_buffer(bitmap_bytes(length))
      // The children are decoded first: each bounds its own cells, and
      // each must hold exactly the struct's.
      let children : Array[Array[@types.Scalar]] = []
      for child in plan.children {
        let cells = decode_field(d, child)
        if cells.length() != length {
          raise malformed(
            "a struct's child holds a different number of cells than the struct",
          )
        }
        children.push(cells)
      }
      let present = validity_of(validity, length, node.null_count)
      let cells : Array[@types.Scalar] = []
      for i in 0..<length {
        if present[i] {
          let fields : Array[@types.FieldValue] = []
          for c, child in plan.children {
            fields.push(
              @types.FieldValue::FieldValue(child.name, children[c][i]),
            )
          }
          cells.push(
            @types.Scalar::Struct(@types.StructValue::StructValue(fields)),
          )
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
      cells
    }
  }
}

///|
/// Where each of a list's cells starts and ends.
priv enum ListSpans {
  /// A fixed-size list: cell `i` spans `i × size` to `(i + 1) × size`.
  Fixed(Int32)
  /// A variable-size list's offsets, `length + 1` of them.
  Offsets(Array[Int64])
}

///|
fn ListSpans::start(self : ListSpans, i : Int32) -> Int64 {
  match self {
    Fixed(size) => i.to_int64() * size.to_int64()
    Offsets(offsets) => offsets[i]
  }
}

///|
fn ListSpans::end(self : ListSpans, i : Int32) -> Int64 {
  match self {
    Fixed(size) => (i.to_int64() + 1L) * size.to_int64()
    Offsets(offsets) => offsets[i + 1]
  }
}

///|
/// A variable-size list's offsets: `length + 1` of them, read from the
/// node's offsets buffer — `Int64` for a large list — each at least the
/// one before it. A node with no cell reads nothing: a writer may leave
/// the buffer empty, or hold the one offset an empty list starts from.
fn list_offsets(
  d : Decode,
  wide : Bool,
  length : Int32,
) -> Array[Int64] raise @types.DataError {
  let width = if wide { 8 } else { 4 }
  if length == 0 {
    ignore(d.take_buffer(width.to_int64()))
    return [0L]
  }
  let buffer = d.bounded(
    (length.to_int64() + 1L) * width.to_int64(),
    "a list's offsets buffer ends before its node's last cell",
  )
  let offsets : Array[Int64] = []
  for i in 0..<=length {
    let at = buffer.int(i, width, true, d.big)
    if i > 0 && at < offsets[i - 1] {
      raise malformed("a list's offsets do not increase")
    }
    offsets.push(at)
  }
  offsets
}

///|
/// The cells of an `Int64` leaf appended to `cells`, each present cell
/// through `cell`: the node's validity buffer, then a buffer the node's
/// cells are bounded by, then the presence.
fn int64_leaf(
  d : Decode,
  cells : Array[@types.Scalar],
  node : FieldNode,
  length : Int32,
  cell~ : (Int64) -> @types.Scalar raise @types.DataError,
) -> Unit raise @types.DataError {
  let validity = d.take_buffer(bitmap_bytes(length))
  let data = d.bounded(
    length.to_int64() * 8L,
    "an Int64 buffer ends before its node's last cell",
  )
  let present = validity_of(validity, length, node.null_count)
  for i in 0..<length {
    if present[i] {
      cells.push(cell(data.int(i, 8, true, d.big)))
    } else {
      cells.push(@types.Scalar::Null)
    }
  }
}

///|
/// The cells of a leaf: the node's validity buffer and its values'
/// buffers are taken and the values bounded by them first, then the
/// presence is read, then the cells.
fn leaf_cells(
  d : Decode,
  leaf : Leaf,
  node : FieldNode,
  length : Int32,
) -> Array[@types.Scalar] raise @types.DataError {
  let cells : Array[@types.Scalar] = []
  match leaf {
    Ints(width, signed) => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let bytes = width / 8
      let data = d.bounded(
        length.to_int64() * bytes.to_int64(),
        "an integer buffer ends before its node's last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          let v = data.int(i, bytes, signed, d.big)
          if !signed && v < 0L {
            raise cannot_carry(
              "column \"\{d.column}\" carries a UInt\{width} cell past Int64's range",
            )
          }
          cells.push(@types.Scalar::Int(v))
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    Floats(single) => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let width = if single { 4 } else { 8 }
      let data = d.bounded(
        length.to_int64() * width.to_int64(),
        "a float buffer ends before its node's last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          let bits = data.uint(i * width, width, d.big)
          cells.push(
            @types.Scalar::Float(
              if single {
                float32_bits_to_double(bits.to_uint())
              } else {
                bits.reinterpret_as_double()
              },
            ),
          )
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    Bools => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let data = d.bounded(
        bitmap_bytes(length),
        "a boolean buffer ends before its node's last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          cells.push(@types.Scalar::Bool(data.bit(i)))
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    Text(wide) => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let width = if wide { 8 } else { 4 }
      let entries = if length > 0 { length.to_int64() + 1L } else { 0L }
      let offsets = d.bounded(
        entries * width.to_int64(),
        "a string's offsets buffer ends before its node's last cell",
      )
      let bounds = text_bounds(offsets, width, length, d.big)
      // The data buffer is asked for after the offsets name its end.
      let data = d.bounded(
        bounds[length],
        "a string's data buffer ends before the offset that closes its last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          cells.push(
            @types.Scalar::String(
              text_of(d, data, bounds[i].to_int(), bounds[i + 1].to_int()),
            ),
          )
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    Bytes(width) => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let data = d.bounded(
        length.to_int64() * width.to_int64(),
        "a binary buffer ends before its node's last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          cells.push(
            @types.Scalar::String(text_of(d, data, i * width, (i + 1) * width)),
          )
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    Decimal128s(scale) => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let data = d.bounded(
        length.to_int64() * 16L,
        "a decimal buffer ends before its node's last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          cells.push(
            @types.Scalar::Decimal(
              decimal128_of(data, i * 16, scale, d.big, d.column),
            ),
          )
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    DateDays => {
      let validity = d.take_buffer(bitmap_bytes(length))
      let data = d.bounded(
        length.to_int64() * 4L,
        "a date buffer ends before its node's last cell",
      )
      let present = validity_of(validity, length, node.null_count)
      for i in 0..<length {
        if present[i] {
          cells.push(@types.Scalar::Date(data.int(i, 4, true, d.big)))
        } else {
          cells.push(@types.Scalar::Null)
        }
      }
    }
    DateMillis =>
      int64_leaf(d, cells, node, length, cell=v => {
        @types.Scalar::Timestamp(scaled(v, 1000L, d.column))
      })
    Timestamps(unit) =>
      int64_leaf(d, cells, node, length, cell=v => {
        @types.Scalar::Timestamp(to_micros(v, unit, d.column))
      })
    Durations(unit) =>
      int64_leaf(d, cells, node, length, cell=v => {
        @types.Scalar::Duration(to_micros(v, unit, d.column))
      })
  }
  cells
}

///|
/// Where each of a string field's `length` cells ends: `length + 1`
/// offsets, each at least the one before it, none negative, none past an
/// `Int32`. A node with no cell reads nothing — a writer may leave its
/// offsets buffer empty.
fn text_bounds(
  offsets : Buf,
  width : Int32,
  length : Int32,
  big : Bool,
) -> Array[Int64] raise @types.DataError {
  if length == 0 {
    return [0L]
  }
  let bounds : Array[Int64] = []
  for i in 0..<=length {
    let at = offsets.int(i, width, true, big)
    if (i > 0 && at < bounds[i - 1]) || at < 0L || at > 2147483647L {
      raise malformed("a string's offsets do not span their data buffer")
    }
    bounds.push(at)
  }
  bounds
}

///|
/// One string cell: its bytes must be UTF-8. A binary column reads only
/// when its bytes are text, and refuses naming the column when they are
/// not.
fn text_of(
  d : Decode,
  data : Buf,
  from : Int32,
  to : Int32,
) -> String raise @types.DataError {
  if from == to {
    return ""
  }
  let start = data.base + from
  @utf8.decode(data.bytes.clamped_view(start~, end=data.base + to)) catch {
    _ =>
      raise malformed(
        "column \"\{d.column}\" carries a cell that is not UTF-8; a binary column reads only when its bytes are text",
      )
  }
}

///|
/// A count of units as microseconds, for a timestamp or a duration: a
/// second or a millisecond count scales up, a microsecond count is its
/// own, and a nanosecond count keeps every digit of its instant when it is
/// a whole number of microseconds — one that is not loses the fraction,
/// and refuses.
fn to_micros(
  count : Int64,
  unit : Int32,
  column : String,
) -> Int64 raise @types.DataError {
  if unit == UNIT_SECOND {
    scaled(count, 1_000_000L, column)
  } else if unit == UNIT_MILLISECOND {
    scaled(count, 1000L, column)
  } else if unit == UNIT_MICROSECOND || count % 1000L == 0L {
    count
  } else {
    raise cannot_carry(
      "column \"\{column}\" carries a nanosecond count that is not a whole microsecond",
    )
  }
}

///|
/// A count of units scaled to microseconds, refusing a product that would
/// leave the `Int64` an instant is counted in.
fn scaled(
  count : Int64,
  factor : Int64,
  column : String,
) -> Int64 raise @types.DataError {
  if count > 9223372036854775L || count < -9223372036854775L {
    raise cannot_carry(
      "column \"\{column}\" carries a timestamp or a span past the range a microsecond count reaches",
    )
  }
  count * factor
}

///|
/// The 32-bit float whose IEEE 754 bits are `bits`, widened to the
/// `Double` that holds every one of its values exactly.
fn float32_bits_to_double(bits : UInt32) -> Double {
  let negative = bits >> 31 == 1U
  let exponent = ((bits >> 23) & 0xFFU).reinterpret_as_int()
  let fraction = bits & 0x7FFFFFU
  let magnitude : Double = if exponent == 255 {
    // An infinity or a NaN: the same exponent and fraction in the wider
    // format, its sign applied with every other value's, below.
    (0x7FF0000000000000UL | (fraction.to_uint64() << 29)).reinterpret_as_double()
  } else if exponent == 0 {
    // Zero, or a subnormal: an integer below 2^23 times the value of the
    // format's least significant bit, a product the `Double` holds
    // exactly.
    fraction.to_double() * FLOAT32_UNIT
  } else {
    // A normal: a 24-bit significand over 2^23, times a power of two.
    (0x800000U | fraction).to_double() /
    8388608.0 *
    ((exponent + 896).to_uint64() << 52).reinterpret_as_double()
  }
  if negative {
    -magnitude
  } else {
    magnitude
  }
}

///|
/// The value of a 32-bit subnormal's least significant bit, 2^-149.
const FLOAT32_UNIT : Double = 1.401298464324817e-45
