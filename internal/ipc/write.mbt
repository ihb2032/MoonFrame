// The Arrow IPC writer: a frame's columns as a schema message and as
// record batches — one per push — in the stream format or the file
// format. The schema is the first batch's: every later batch must agree
// with it, column for column, name and dtype, the way `vstack` demands,
// and a decimal column's precision and scale are the first batch's too,
// read off its cells. No column is dictionary-encoded; every field is
// nullable, a timestamp carries no time zone, and a float is 64-bit.

///|
/// The Arrow type a MoonFrame dtype is written as. A decimal names its
/// precision and its scale, the window its cells decided.
priv enum ArrowType {
  Int64
  Float64
  Bool
  Utf8
  Date
  Timestamp
  Duration
  Decimal(Int32, Int32)
  List(ArrowType)
  Struct(Array[(String, ArrowType)])
}

///|
/// The metadata version every message is written under.
const METADATA_VERSION : Int32 = 4

///|
/// The precision a decimal's unscaled integer is written in: the
/// sixteen-byte decimal.
const DECIMAL_PRECISION_MAX : Int32 = 38

///|
/// The name a list's child field carries, the one every Arrow writer
/// gives it.
const LIST_ITEM : String = "item"

///|
/// The refusal for a write the interchange does not carry.
fn cannot_write(what : String) -> @types.DataError {
  @types.DataError::InvalidOperation("cannot write Arrow IPC: \{what}")
}

///|
/// Text the metadata or a string cell carries as UTF-8: the encoding does
/// not round-trip an unpaired UTF-16 surrogate, so one refuses before the
/// encoder meets it. `what` names the text — a column's name, a cell.
fn check_utf16(text : String, what : String) -> Unit raise @types.DataError {
  match @text.find_unpaired_surrogate(text) {
    Some(_) =>
      raise cannot_write(
        "\{what} containing an unpaired UTF-16 surrogate, whose UTF-8 spelling would not round-trip",
      )
    None => ()
  }
}

///|
/// The Arrow type a column of `dtype` is written as over `cells`. A
/// decimal's window is read off the cells; when `decided` is given — the
/// type a first batch decided, which a later batch's dtype was checked to
/// spell again — the cells must sit inside its windows instead.
fn arrow_type_of(
  dtype : @types.DataType,
  cells : Array[@types.Scalar],
  column : String,
  decided : ArrowType?,
) -> ArrowType raise @types.DataError {
  match dtype {
    Int => Int64
    Float => Float64
    Bool => Bool
    String => Utf8
    Date => Date
    Timestamp => Timestamp
    Duration => Duration
    Decimal =>
      if decided is Some(Decimal(precision, scale)) {
        let (needed, fraction) = decimal_window(cells, column)
        // The window is fixed: a cell may count no more fraction digits
        // than the scale, and lift no higher than the precision leaves.
        if fraction > scale || needed - fraction > precision - scale {
          raise cannot_write(
            "column \"\{column}\": a later batch's decimal cells need a \{needed}-digit window at scale \{fraction}, outside the precision-\{precision} window the first batch decided at scale \{scale}",
          )
        }
        Decimal(precision, scale)
      } else {
        let (precision, scale) = decimal_window(cells, column)
        Decimal(precision, scale)
      }
    List(element) => {
      // The decided type spells this dtype again, so it is a list when
      // there is one; anything else names no window to keep.
      let below : ArrowType? = if decided is Some(List(inner)) {
        Some(inner)
      } else {
        None
      }
      List(arrow_type_of(element, list_cells(cells), column, below))
    }
    Struct(fields) => {
      let below : Array[(String, ArrowType)]? = if decided
        is Some(Struct(named)) {
        Some(named)
      } else {
        None
      }
      let inner : Array[(String, ArrowType)] = []
      for i, field in fields.fields() {
        let name = field.name()
        check_utf16(name, "a struct field name of column \"\{column}\"")
        let windowed = match below {
          None => None
          Some(named) => named.get(i).map(entry => entry.1)
        }
        inner.push(
          (
            name,
            arrow_type_of(
              field.dtype(),
              struct_cells(cells, i),
              column,
              windowed,
            ),
          ),
        )
      }
      Struct(inner)
    }
    Null =>
      raise cannot_write(
        "a column of dtype Null, which names no buffer to write",
      )
  }
}

///|
/// The cells of a list column's child: every cell's elements in order.
fn list_cells(cells : Array[@types.Scalar]) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  for cell in cells {
    if cell is List(v) {
      for element in v.cells() {
        out.push(element)
      }
    }
  }
  out
}

///|
/// The cells of a struct column's field `index`: each cell's value there,
/// null for a null cell or a field the cell leaves out.
fn struct_cells(
  cells : Array[@types.Scalar],
  index : Int32,
) -> Array[@types.Scalar] {
  cells.map(cell => {
    if cell is Struct(v) {
      match v.fields().get(index) {
        Some(field) => field.value()
        None => @types.Scalar::Null
      }
    } else {
      @types.Scalar::Null
    }
  })
}

///|
/// A decimal's coefficient digits and quantum exponent.
fn decimal_parts(
  value : @types.Dec128,
  column : String,
) -> (Array[Int32], Int32) raise @types.DataError {
  match (value.coefficient_digits(), value.exponent()) {
    (Some(digits), Some(exponent)) => (digits, exponent)
    (_, _) =>
      raise cannot_write(
        "column \"\{column}\": a NaN or infinite decimal cell, which has no fixed-point interchange spelling",
      )
  }
}

///|
/// The narrowest decimal window that holds every cell: the precision, and
/// the scale — the most fraction digits a cell counts. The precision is
/// what the widest cell lifts to under that scale, and at least one digit
/// more than the scale.
fn decimal_window(
  cells : Array[@types.Scalar],
  column : String,
) -> (Int32, Int32) raise @types.DataError {
  let mut scale = 0
  let mut lifted = 0
  for cell in cells {
    if cell is Decimal(value) {
      let (digits, exponent) = decimal_parts(value, column)
      let fraction = -exponent
      if fraction > scale {
        scale = fraction
      }
      let reach = digits.length() + exponent
      if reach > lifted {
        lifted = reach
      }
    }
  }
  // The most fraction digits a cell counts, lifted to at least one digit
  // more than the scale, so the scale never passes the precision.
  let precision = if lifted + scale > scale + 1 {
    lifted + scale
  } else {
    scale + 1
  }
  if precision > DECIMAL_PRECISION_MAX {
    raise cannot_write(
      "column \"\{column}\": its cells leave the decimal interchange's \{DECIMAL_PRECISION_MAX}-digit window",
    )
  }
  (precision, scale)
}

///|
/// One decimal cell's sixteen bytes: the coefficient's digits, lifted by
/// the exponent the column's scale gives it, as a two's-complement
/// integer. The column's window has already held the cell, so the four
/// 32-bit limbs it accumulates over cannot carry past the top.
fn decimal_bytes(
  value : @types.Dec128,
  scale : Int32,
  column : String,
) -> Array[Byte] raise @types.DataError {
  let (digits, exponent) = decimal_parts(value, column)
  let limbs : Array[UInt64] = [0UL, 0UL, 0UL, 0UL]
  let step = fn(digit : Int32) -> Unit {
    let mut carry : UInt64 = digit.to_uint64()
    for i in 0..<4 {
      let current = limbs[i] * 10UL + carry
      limbs[i] = current & 0xFFFFFFFFUL
      carry = current >> 32
    }
  }
  for digit in digits {
    step(digit)
  }
  for _ in 0..<(exponent + scale) {
    step(0)
  }
  if value.is_negative() {
    let mut carry : UInt64 = 1UL
    for i in 0..<4 {
      let current = (limbs[i] ^ 0xFFFFFFFFUL) + carry
      limbs[i] = current & 0xFFFFFFFFUL
      carry = current >> 32
    }
  }
  let out : Array[Byte] = []
  for limb in limbs {
    for shift in [0, 8, 16, 24] {
      out.push(((limb >> shift.to_int()) & 0xFFUL).to_byte())
    }
  }
  out
}

///|
/// A record batch's body under construction, and the layout tree that
/// describes it: the nodes and the buffers in the order the fields wrote
/// them.
priv struct BodyWriter {
  body : Array[Byte]
  nodes : Array[FieldNode]
  buffers : Array[BufferRef]
  codec : BodyCodec?
}

///|
fn BodyWriter::new(codec : BodyCodec?) -> BodyWriter {
  { body: [], nodes: [], buffers: [], codec, }
}

///|
fn BodyWriter::node(
  self : BodyWriter,
  length : Int32,
  null_count : Int32,
) -> Unit {
  self.nodes.push({
    length: length.to_int64(),
    null_count: null_count.to_int64(),
  })
}

///|
/// One buffer of the body, on an eight-byte boundary: compressed when the
/// batch is and the frame is the shorter spelling, and headed by its
/// uncompressed length when the batch is compressed at all. An empty
/// buffer stays empty, as a writer of a compressed batch leaves it.
fn BodyWriter::buffer(self : BodyWriter, raw : Bytes) -> Unit {
  let bytes = match self.codec {
    None => raw
    Some(codec) => compress_or_store(codec, raw)
  }
  while self.body.length() % 8 != 0 {
    self.body.push((0).to_byte())
  }
  self.buffers.push({
    offset: self.body.length().to_int64(),
    length: bytes.length().to_int64(),
  })
  for byte in bytes.iter() {
    self.body.push(byte)
  }
}

///|
fn BodyWriter::finish(self : BodyWriter) -> Bytes {
  while self.body.length() % 8 != 0 {
    self.body.push((0).to_byte())
  }
  Bytes::from_array(self.body)
}

///|
/// A buffer as a compressed batch stores it: behind a header of its
/// uncompressed length as an `Int64` comes the frame — or, when the frame
/// is not the shorter spelling, the bytes themselves behind a header of
/// `-1`.
fn compress_or_store(codec : BodyCodec, raw : Bytes) -> Bytes {
  if raw.length() == 0 {
    return raw
  }
  let out : Array[Byte] = []
  match deflate_buffer(codec, raw) {
    None => {
      push_i64(out, -1L)
      for byte in raw.iter() {
        out.push(byte)
      }
    }
    Some(frame) => {
      push_i64(out, raw.length().to_int64())
      for byte in frame.iter() {
        out.push(byte)
      }
    }
  }
  Bytes::from_array(out)
}

///|

///|
/// The low `width` bytes of `bits`, the least significant first.
fn push_le(out : Array[Byte], bits : UInt64, width : Int32) -> Unit {
  for i in 0..<width {
    out.push(((bits >> (8 * i).to_int()) & 0xFFUL).to_byte())
  }
}

///|
fn push_i32(out : Array[Byte], v : Int32) -> Unit {
  push_le(out, v.to_int64().reinterpret_as_uint64(), 4)
}

///|
fn push_i64(out : Array[Byte], v : Int64) -> Unit {
  push_le(out, v.reinterpret_as_uint64(), 8)
}

///|
/// A bitmap of `count` bits, a byte for eight of them, the first bit of a
/// byte the first of its eight.
fn bitmap_of(count : Int32, bit : (Int32) -> Bool) -> Bytes {
  let out : Array[Byte] = []
  let mut current = 0
  for i in 0..<count {
    if bit(i) {
      current = current | (1 << (i % 8))
    }
    if i % 8 == 7 {
      out.push(current.to_byte())
      current = 0
    }
  }
  if count % 8 != 0 {
    out.push(current.to_byte())
  }
  Bytes::from_array(out)
}

///|
/// One column of a record batch: its node, its validity, the buffers its
/// values need, and its children's — a parent ahead of its children.
fn encode_column(
  w : BodyWriter,
  arrow : ArrowType,
  cells : Array[@types.Scalar],
  column : String,
) -> Unit raise @types.DataError {
  let nulls = cells.filter(cell => cell is Null).length()
  w.node(cells.length(), nulls)
  // A column with no null writes an empty validity buffer, as every
  // Arrow writer does.
  w.buffer(
    if nulls == 0 {
      Bytes::from_array([])
    } else {
      bitmap_of(cells.length(), i => !(cells[i] is Null))
    },
  )
  match arrow {
    Int64 => {
      let out : Array[Byte] = []
      for cell in cells {
        if cell is Int(v) {
          push_i64(out, v)
        } else {
          push_i64(out, 0L)
        }
      }
      w.buffer(Bytes::from_array(out))
    }
    Float64 => {
      let out : Array[Byte] = []
      for cell in cells {
        if cell is Float(v) {
          push_i64(out, v.reinterpret_as_int64())
        } else {
          push_i64(out, 0L)
        }
      }
      w.buffer(Bytes::from_array(out))
    }
    Bool => w.buffer(bitmap_of(cells.length(), i => cells[i] is Bool(true)))
    Utf8 => {
      let offsets : Array[Byte] = []
      let data : Array[Byte] = []
      let mut so_far = 0
      push_i32(offsets, 0)
      for cell in cells {
        if cell is String(text) {
          check_utf16(text, "a string cell of column \"\{column}\"")
          let bytes = @utf8.encode(text)
          so_far += bytes.length()
          for byte in bytes.iter() {
            data.push(byte)
          }
        }
        push_i32(offsets, so_far)
      }
      w.buffer(Bytes::from_array(offsets))
      w.buffer(Bytes::from_array(data))
    }
    Date => {
      let out : Array[Byte] = []
      for cell in cells {
        if cell is Date(v) {
          push_i32(out, v.to_int())
        } else {
          push_i32(out, 0)
        }
      }
      w.buffer(Bytes::from_array(out))
    }
    Timestamp | Duration => {
      let out : Array[Byte] = []
      for cell in cells {
        if cell is Timestamp(v) {
          push_i64(out, v)
        } else if cell is Duration(v) {
          push_i64(out, v)
        } else {
          push_i64(out, 0L)
        }
      }
      w.buffer(Bytes::from_array(out))
    }
    Decimal(_, scale) => {
      let out : Array[Byte] = []
      for cell in cells {
        if cell is Decimal(value) {
          for byte in decimal_bytes(value, scale, column) {
            out.push(byte)
          }
        } else {
          for _ in 0..<16 {
            out.push((0).to_byte())
          }
        }
      }
      w.buffer(Bytes::from_array(out))
    }
    List(element) => {
      let offsets : Array[Byte] = []
      let values : Array[@types.Scalar] = []
      push_i32(offsets, 0)
      for cell in cells {
        if cell is List(v) {
          for item in v.cells() {
            values.push(item)
          }
        }
        push_i32(offsets, values.length())
      }
      w.buffer(Bytes::from_array(offsets))
      encode_column(w, element, values, column)
    }
    Struct(fields) =>
      for index, field in fields {
        encode_column(w, field.1, struct_cells(cells, index), column)
      }
  }
}

///|
/// One field of a schema: its name, the type's table, and its children.
fn write_field(
  fb : Fb,
  name : String,
  arrow : ArrowType,
) -> Int32 raise @types.DataError {
  check_utf16(name, "a column name")
  let child_types : Array[(String, ArrowType)] = match arrow {
    List(element) => [(LIST_ITEM, element)]
    Struct(fields) => fields
    _ => []
  }
  let child_marks : Array[Int32] = []
  for child in child_types {
    child_marks.push(write_field(fb, child.0, child.1))
  }
  let children = fb.vector(child_marks.length(), i => fb.offset(child_marks[i]))
  let (code, type_mark) = write_type(fb, arrow)
  let type_at = fb.refer(type_mark)
  let children_at = fb.refer(children)
  fb.u8(code)
  let code_at = fb.mark()
  fb.boolean(true)
  let nullable_at = fb.mark()
  let name_at = fb.refer(fb.string(name))
  fb.table([
    { id: 5, mark: children_at, width: 4, },
    { id: 3, mark: type_at, width: 4, },
    { id: 2, mark: code_at, width: 1, },
    { id: 1, mark: nullable_at, width: 1, },
    { id: 0, mark: name_at, width: 4, },
  ])
}

///|
/// A type's member of the type union — its code — and the type's own
/// table, empty for the types that have no parameters.
fn write_type(fb : Fb, arrow : ArrowType) -> (Int32, Int32) {
  match arrow {
    Int64 => {
      fb.boolean(true)
      let signed_at = fb.mark()
      fb.i32(64)
      let width_at = fb.mark()
      (
        TYPE_INT,
        fb.table([
          { id: 1, mark: signed_at, width: 1, },
          { id: 0, mark: width_at, width: 4, },
        ]),
      )
    }
    Float64 => {
      fb.i16(2)
      let precision_at = fb.mark()
      (TYPE_FLOAT, fb.table([{ id: 0, mark: precision_at, width: 2, }]))
    }
    Bool => (TYPE_BOOL, fb.table([]))
    Utf8 => (TYPE_UTF8, fb.table([]))
    Date => {
      fb.i16(UNIT_SECOND)
      let unit_at = fb.mark()
      (TYPE_DATE, fb.table([{ id: 0, mark: unit_at, width: 2, }]))
    }
    Timestamp => {
      fb.i16(UNIT_MICROSECOND)
      let unit_at = fb.mark()
      (TYPE_TIMESTAMP, fb.table([{ id: 0, mark: unit_at, width: 2, }]))
    }
    Duration => {
      fb.i16(UNIT_MICROSECOND)
      let unit_at = fb.mark()
      (TYPE_DURATION, fb.table([{ id: 0, mark: unit_at, width: 2, }]))
    }
    Decimal(precision, scale) => {
      fb.i32(128)
      let width_at = fb.mark()
      fb.i32(scale)
      let scale_at = fb.mark()
      fb.i32(precision)
      let precision_at = fb.mark()
      (
        TYPE_DECIMAL,
        fb.table([
          { id: 2, mark: width_at, width: 4, },
          { id: 1, mark: scale_at, width: 4, },
          { id: 0, mark: precision_at, width: 4, },
        ]),
      )
    }
    List(_) => (TYPE_LIST, fb.table([]))
    Struct(_) => (TYPE_STRUCT, fb.table([]))
  }
}

///|
/// A schema's table over the frame's columns.
fn write_schema(
  fb : Fb,
  types : Array[(String, ArrowType)],
) -> Int32 raise @types.DataError {
  let field_marks : Array[Int32] = []
  for column in types {
    field_marks.push(write_field(fb, column.0, column.1))
  }
  let fields = fb.vector(field_marks.length(), i => fb.offset(field_marks[i]))
  fb.table([{ id: 1, mark: fb.refer(fields), width: 4, }])
}

///|
/// Wrap a header in a message, and finish the metadata: padded to a
/// multiple of eight bytes.
fn write_message(
  fb : Fb,
  header_type : Int32,
  header : Int32,
  body : Int64,
) -> Bytes {
  let header_at = fb.refer(header)
  fb.u8(header_type)
  let type_at = fb.mark()
  fb.i64(body)
  let body_at = fb.mark()
  fb.i16(METADATA_VERSION)
  let version_at = fb.mark()
  let root = fb.table([
    { id: 3, mark: body_at, width: 8, },
    { id: 2, mark: header_at, width: 4, },
    { id: 1, mark: type_at, width: 1, },
    { id: 0, mark: version_at, width: 2, },
  ])
  fb.finish(root)
}

///|
/// The schema message of a frame's columns: its header carries no body.
fn schema_metadata(
  types : Array[(String, ArrowType)],
) -> Bytes raise @types.DataError {
  let fb = Fb::new()
  let schema = write_schema(fb, types)
  write_message(fb, HEADER_SCHEMA, schema, 0L)
}

///|
/// One record batch's metadata: the layout tree the body's writer
/// recorded, the codec its buffers were compressed with, and the body's
/// padded length — the length a reader steps over to reach what follows,
/// so it is the body as written, not as its last buffer ended.
fn batch_metadata(w : BodyWriter, rows : Int32, body : Bytes) -> Bytes {
  let fb = Fb::new()
  // The fields are written highest id first, so they sit in the table in
  // the order of their ids.
  let compression_at = match w.codec {
    None => -1
    Some(codec) => {
      fb.u8(if codec is Lz4Frame { 0 } else { 1 })
      let codec_at = fb.mark()
      let compression = fb.table([{ id: 0, mark: codec_at, width: 1, }])
      fb.refer(compression)
    }
  }
  let buffers = fb.structs(w.buffers.length(), i => {
    let reference = w.buffers[i]
    fb.i64(reference.length)
    fb.i64(reference.offset)
  })
  let nodes = fb.structs(w.nodes.length(), i => {
    let node = w.nodes[i]
    fb.i64(node.null_count)
    fb.i64(node.length)
  })
  let nodes_at = fb.refer(nodes)
  let buffers_at = fb.refer(buffers)
  fb.i64(rows.to_int64())
  let length_at = fb.mark()
  let fields : Array[FieldMark] = [
    { id: 2, mark: buffers_at, width: 4, },
    { id: 1, mark: nodes_at, width: 4, },
    { id: 0, mark: length_at, width: 8, },
  ]
  if compression_at >= 0 {
    fields.push({ id: 3, mark: compression_at, width: 4, })
  }
  let batch = fb.table(fields)
  write_message(fb, HEADER_BATCH, batch, body.length().to_int64())
}

///|
/// One record batch of a frame's columns.
fn write_batch(
  types : Array[(String, ArrowType)],
  columns : Array[Array[@types.Scalar]],
  height : Int32,
  codec : BodyCodec?,
) -> (Bytes, Bytes) raise @types.DataError {
  let w = BodyWriter::new(codec)
  let rows = if columns.is_empty() { height } else { columns[0].length() }
  for i, arrow in types {
    encode_column(w, arrow.1, columns[i], arrow.0)
  }
  // The body is padded first: the metadata names the padded length.
  let body = w.finish()
  (batch_metadata(w, rows, body), body)
}

///|
/// The file format's footer: the schema again, and a block per record
/// batch, saying where each message starts and how long its metadata and
/// its body are.
fn footer_bytes(
  types : Array[(String, ArrowType)],
  blocks : Array[Block],
) -> Bytes raise @types.DataError {
  let fb = Fb::new()
  let batches = fb.structs(blocks.length(), i => {
    let block = blocks[i]
    // A block is an Int64, an Int32, four bytes of padding, and an Int64.
    fb.i64(block.body)
    for _ in 0..<4 {
      fb.u8(0)
    }
    fb.i32(block.meta)
    fb.i64(block.offset)
  })
  let dictionaries = fb.structs(0, _ => ())
  let schema = write_schema(fb, types)
  let schema_at = fb.refer(schema)
  let dictionaries_at = fb.refer(dictionaries)
  let batches_at = fb.refer(batches)
  fb.i16(METADATA_VERSION)
  let version_at = fb.mark()
  let root = fb.table([
    { id: 3, mark: batches_at, width: 4, },
    { id: 2, mark: dictionaries_at, width: 4, },
    { id: 1, mark: schema_at, width: 4, },
    { id: 0, mark: version_at, width: 2, },
  ])
  fb.finish(root)
}

///|
/// Where one record batch's message starts in the payload, and the
/// lengths of its metadata — the framing and the metadata — and its body.
priv struct Block {
  offset : Int64
  meta : Int32
  body : Int64
}

///|
/// The writer a frame is pushed to, batch by batch: the schema is decided
/// by the first batch, every batch lands as its own message, and the
/// finished payload is the stream format or the file format. Nothing is
/// written until a batch arrives, or the sink is finished.
pub struct IpcSink {
  priv codec : BodyCodec?
  priv file : Bool
  priv mut started : Bool
  priv names : Array[String]
  priv dtypes : Array[@types.DataType]
  priv types : Array[(String, ArrowType)]
  priv out : Array[Byte]
  priv blocks : Array[Block]
}

///|
/// A sink writing every buffer of its batches uncompressed, or compressed
/// with the codec named; a file when `file` is set, a stream otherwise.
pub fn IpcSink::sink(codec : BodyCodec?, file~ : Bool) -> IpcSink {
  {
    codec,
    file,
    started: false,
    names: [],
    dtypes: [],
    types: [],
    out: [],
    blocks: [],
  }
}

///|
/// The payload's head — the file format's marker — and its schema
/// message, over the columns decided so far (none, when no batch has
/// arrived).
fn IpcSink::open(self : IpcSink) -> Unit raise @types.DataError {
  self.started = true
  if self.file {
    for byte in FILE_MAGIC.iter() {
      self.out.push(byte)
    }
    for _ in 0..<2 {
      self.out.push((0).to_byte())
    }
  }
  let meta = schema_metadata(self.types)
  ignore(self.message(meta, Bytes::from_array([])))
}

///|
/// One batch: the columns in the frame's order, and — for a batch with no
/// column, where no column can say it — its row count `height`. The first
/// batch decides
/// the schema — the names, the dtypes, and every decimal's window — and a
/// later batch must agree with it, name for name and dtype for dtype, the
/// way `vstack` demands, and its decimal cells must sit inside the windows
/// the first batch decided.
pub fn IpcSink::push(
  self : IpcSink,
  columns : Array[@series.Series],
  height~ : Int32 = 0,
) -> Unit raise @types.DataError {
  let cells = columns.map(column => column.to_scalars())
  if self.started {
    if columns.length() != self.names.length() {
      raise cannot_write(
        "a later batch carries \{columns.length()} columns where the first carried \{self.names.length()}",
      )
    }
    for i, column in columns {
      let dtype = column.dtype()
      if column.name() != self.names[i] {
        raise cannot_write(
          "a later batch names its column \{i + 1} \"\{column.name()}\" where the first batch named it \"\{self.names[i]}\"",
        )
      }
      if dtype != self.dtypes[i] {
        raise cannot_write(
          "a later batch carries column \"\{column.name()}\" as \{dtype} where the first batch carried it as \{self.dtypes[i]}",
        )
      }
    }
  } else {
    for column in columns {
      let name = column.name()
      check_utf16(name, "a column name")
      self.names.push(name)
      self.dtypes.push(column.dtype())
    }
    for i, _ in columns {
      self.types.push(
        (
          self.names[i],
          arrow_type_of(self.dtypes[i], cells[i], self.names[i], None),
        ),
      )
    }
    self.open()
  }
  // The cells are planned against the decided types: for the first batch
  // that is the plan just made, and for a later one the check that its
  // decimals sit inside the first batch's windows.
  for i, _ in columns {
    ignore(
      arrow_type_of(
        self.dtypes[i],
        cells[i],
        self.names[i],
        Some(self.types[i].1),
      ),
    )
  }
  let (meta, body) = write_batch(self.types, cells, height, self.codec)
  let offset = self.message(meta, body)
  self.blocks.push({
    offset,
    meta: 8 + meta.length(),
    body: body.length().to_int64(),
  })
}

///|
/// The finished payload: every batch's message, then the stream's end
/// marker, or the file's footer between its two markers. A sink nothing
/// was pushed to finishes a payload of an empty schema.
pub fn IpcSink::finish(self : IpcSink) -> Bytes raise @types.DataError {
  if !self.started {
    self.open()
  }
  if self.file {
    let footer = footer_bytes(self.types, self.blocks)
    for byte in footer.iter() {
      self.out.push(byte)
    }
    push_i32(self.out, footer.length())
    for byte in FILE_MAGIC.iter() {
      self.out.push(byte)
    }
  } else {
    push_i32(self.out, CONTINUATION)
    push_i32(self.out, 0)
  }
  Bytes::from_array(self.out)
}

///|
/// One encapsulated message appended to the payload — the continuation
/// marker, the metadata's padded length, the metadata, and the body —
/// answering where it started.
fn IpcSink::message(self : IpcSink, meta : Bytes, body : Bytes) -> Int64 {
  let offset = self.out.length().to_int64()
  push_i32(self.out, CONTINUATION)
  push_i32(self.out, meta.length())
  for byte in meta.iter() {
    self.out.push(byte)
  }
  for byte in body.iter() {
    self.out.push(byte)
  }
  offset
}

///|
/// A frame's columns as one payload of a single record batch of `height`
/// rows — the frame's own row count, which a frame with no column alone
/// carries.
pub fn write_ipc_bytes(
  columns : Array[@series.Series],
  codec : BodyCodec?,
  file~ : Bool,
  height~ : Int32 = 0,
) -> Bytes raise @types.DataError {
  let sink = IpcSink::sink(codec, file~)
  sink.push(columns.copy(), height~)
  sink.finish()
}
