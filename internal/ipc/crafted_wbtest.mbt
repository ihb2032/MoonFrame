// Whitebox tests of the Arrow IPC codec over messages its own writer never
// produces. Each is built by hand with the package's own builder, so every
// refusal the reader states is one a test has met: the framings a payload
// cannot open with, the types and counts that have no reading, a
// dictionary batch that extends or replaces what was read, and a record
// batch whose nodes and buffers do not line up with its schema.

///|
/// Run a reader and answer the text of the error it raised; a read that
/// does not refuse fails the test.
fn refusal_text(run : () -> Unit raise @types.DataError) -> String raise {
  let outcome : Result[Unit, @types.DataError] = Ok(run()) catch { e => Err(e) }
  match outcome {
    Ok(_) => fail("the read was expected to refuse")
    Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(text))) =>
      text
    Err(@types.DataError::InvalidOperation(text)) => text
    Err(@types.DataError::Unsupported(text)) => text
    Err(_) => fail("the read refused with an error that carries no text")
  }
}

// ── bytes ─────────────────────────────────────────────────────────────

///|
/// `count` zero bytes.
fn zeros(count : Int32) -> Bytes {
  Bytes::makei(count, _ => b'\x00')
}

///|
/// Int32s as little-endian bytes, side by side.
fn int32s(values : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in values {
    push_i32(out, v)
  }
  Bytes::from_array(out)
}

///|
/// Bytes end to end.
fn joined(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for byte in part.iter() {
      out.push(byte)
    }
  }
  Bytes::from_array(out)
}

///|
/// One encapsulated message: the continuation, the metadata's length, the
/// metadata, and the body — unpadded, which the reader takes as it is.
fn crafted_message(meta : Bytes, body : Bytes) -> Bytes {
  let out : Array[Byte] = []
  push_i32(out, CONTINUATION)
  push_i32(out, meta.length())
  for byte in meta.iter() {
    out.push(byte)
  }
  for byte in body.iter() {
    out.push(byte)
  }
  Bytes::from_array(out)
}

///|
/// A stream of messages, closed by its end marker.
fn crafted_stream(messages : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for message in messages {
    for byte in message.iter() {
      out.push(byte)
    }
  }
  push_i32(out, CONTINUATION)
  push_i32(out, 0)
  Bytes::from_array(out)
}

// ── the tables a message carries ──────────────────────────────────────

///|
/// A record batch's table over `rows` — its row count, which the cells
/// need not add up to — `nodes` (each a cell count and a null count),
/// `buffers` (each an offset and a length into the body), and the codec
/// its buffers are compressed with, `None` for an uncompressed batch.
fn crafted_batch_table(
  fb : Fb,
  rows : Int64,
  nodes : Array[(Int64, Int64)],
  buffers : Array[(Int64, Int64)],
  codec : Int32?,
) -> Int32 {
  let compression_at = match codec {
    None => -1
    Some(code) => {
      fb.u8(code)
      let codec_at = fb.mark()
      let compression = fb.table([{ id: 0, mark: codec_at, width: 1, }])
      fb.refer(compression)
    }
  }
  let buffers_at = fb.refer(
    fb.structs(buffers.length(), i => {
      fb.i64(buffers[i].1)
      fb.i64(buffers[i].0)
    }),
  )
  let nodes_at = fb.refer(
    fb.structs(nodes.length(), i => {
      fb.i64(nodes[i].1)
      fb.i64(nodes[i].0)
    }),
  )
  fb.i64(rows)
  let rows_at = fb.mark()
  let fields : Array[FieldMark] = [
    { id: 2, mark: buffers_at, width: 4, },
    { id: 1, mark: nodes_at, width: 4, },
    { id: 0, mark: rows_at, width: 8, },
  ]
  if compression_at >= 0 {
    fields.push({ id: 3, mark: compression_at, width: 4, })
  }
  fb.table(fields)
}

///|
/// A record batch's message: as many rows as its first node holds cells,
/// uncompressed.
fn crafted_batch(
  nodes : Array[(Int64, Int64)],
  buffers : Array[(Int64, Int64)],
  body : Bytes,
) -> Bytes {
  let rows = if nodes.is_empty() { 0L } else { nodes[0].0 }
  let meta = crafted_batch_meta(
    rows,
    nodes,
    buffers,
    None,
    body.length().to_int64(),
  )
  crafted_message(meta, body)
}

///|
/// A record batch's metadata alone, declaring a body of `body` bytes.
fn crafted_batch_meta(
  rows : Int64,
  nodes : Array[(Int64, Int64)],
  buffers : Array[(Int64, Int64)],
  codec : Int32?,
  body : Int64,
) -> Bytes {
  let fb = Fb::new()
  let batch = crafted_batch_table(fb, rows, nodes, buffers, codec)
  write_message(fb, HEADER_BATCH, batch, body)
}

///|
/// A dictionary batch's table: the schema's id for the dictionary, the
/// batch carrying its values (`-1` for a table that carries none), and
/// whether it extends the dictionary already read.
fn crafted_dictionary_table(
  fb : Fb,
  id : Int64,
  data : Int32,
  delta : Bool,
) -> Int32 {
  fb.boolean(delta)
  let delta_at = fb.mark()
  fb.i64(id)
  let id_at = fb.mark()
  let fields : Array[FieldMark] = [
    { id: 2, mark: delta_at, width: 1, },
    { id: 0, mark: id_at, width: 8, },
  ]
  if data >= 0 {
    fields.push({ id: 1, mark: fb.refer(data), width: 4, })
  }
  fb.table(fields)
}

///|
/// A dictionary batch of `nodes` and `buffers` over `body`, extending the
/// dictionary already read when `delta` is set.
fn crafted_dictionary(
  id : Int64,
  nodes : Array[(Int64, Int64)],
  buffers : Array[(Int64, Int64)],
  body : Bytes,
  delta : Bool,
) -> Bytes {
  let fb = Fb::new()
  let rows = if nodes.is_empty() { 0L } else { nodes[0].0 }
  let data = crafted_batch_table(fb, rows, nodes, buffers, None)
  let dictionary = crafted_dictionary_table(fb, id, data, delta)
  let meta = write_message(
    fb,
    HEADER_DICTIONARY,
    dictionary,
    body.length().to_int64(),
  )
  crafted_message(meta, body)
}

// ── the schema ────────────────────────────────────────────────────────

///|
/// A field of a hand-built schema: its name, the code of its type (`-1`
/// names no type), the fields of the type's own table, its children, the
/// dictionary it is encoded against (`-1` for none), and the bit width of
/// that dictionary's indices.
struct CraftedField {
  name : String
  code : Int32
  type_fields : (Fb) -> Array[FieldMark]
  children : Array[CraftedField]
  dictionary_id : Int64
  index_width : Int32
}

///|
/// A leaf of an empty type: no parameter, no child, no dictionary.
fn typed(name : String, code : Int32) -> CraftedField {
  {
    name,
    code,
    type_fields: fn(_ : Fb) -> Array[FieldMark] { [] },
    children: [],
    dictionary_id: -1L,
    index_width: 32,
  }
}

///|
/// A leaf whose type's own table carries `fields`.
fn with_type(
  name : String,
  code : Int32,
  fields : (Fb) -> Array[FieldMark],
) -> CraftedField {
  {
    name,
    code,
    type_fields: fields,
    children: [],
    dictionary_id: -1L,
    index_width: 32,
  }
}

///|
/// An `Int32` parameter of a type's table: an integer's bit width, a
/// time's, a decimal's.
fn i32_field(fb : Fb, id : Int32, value : Int32) -> Array[FieldMark] {
  fb.i32(value)
  [{ id, mark: fb.mark(), width: 4, }]
}

///|
/// An `Int16` parameter of a type's table: a time unit, a float's
/// precision.
fn i16_field(fb : Fb, id : Int32, value : Int32) -> Array[FieldMark] {
  fb.i16(value)
  [{ id, mark: fb.mark(), width: 2, }]
}

///|
fn crafted_field(fb : Fb, spec : CraftedField) -> Int32 {
  let child_marks : Array[Int32] = []
  for child in spec.children {
    child_marks.push(crafted_field(fb, child))
  }
  let children_at = fb.refer(
    fb.vector(child_marks.length(), i => fb.offset(child_marks[i])),
  )
  let type_at = fb.refer(fb.table((spec.type_fields)(fb)))
  let dictionary_at = if spec.dictionary_id >= 0L {
    // A DictionaryEncoding over signed indices of the field's width.
    fb.boolean(true)
    let signed_at = fb.mark()
    fb.i32(spec.index_width)
    let width_at = fb.mark()
    let index_at = fb.refer(
      fb.table([
        { id: 1, mark: signed_at, width: 1, },
        { id: 0, mark: width_at, width: 4, },
      ]),
    )
    fb.i64(spec.dictionary_id)
    let id_at = fb.mark()
    fb.refer(
      fb.table([
        { id: 1, mark: index_at, width: 4, },
        { id: 0, mark: id_at, width: 8, },
      ]),
    )
  } else {
    -1
  }
  let code_at = if spec.code >= 0 {
    fb.u8(spec.code)
    fb.mark()
  } else {
    -1
  }
  fb.boolean(true)
  let nullable_at = fb.mark()
  let name_at = fb.refer(fb.string(spec.name))
  let fields : Array[FieldMark] = [
    { id: 5, mark: children_at, width: 4, },
    { id: 3, mark: type_at, width: 4, },
  ]
  if code_at >= 0 {
    fields.push({ id: 2, mark: code_at, width: 1, })
  }
  fields.push({ id: 1, mark: nullable_at, width: 1, })
  fields.push({ id: 0, mark: name_at, width: 4, })
  if dictionary_at >= 0 {
    fields.push({ id: 4, mark: dictionary_at, width: 4, })
  }
  fb.table(fields)
}

///|
/// A schema message over hand-built fields, its bodies of `endianness` —
/// `0` little-endian, `1` big-endian.
fn crafted_schema_as(fields : Array[CraftedField], endianness : Int32) -> Bytes {
  let fb = Fb::new()
  let marks : Array[Int32] = []
  for field in fields {
    marks.push(crafted_field(fb, field))
  }
  let fields_at = fb.refer(fb.vector(marks.length(), i => fb.offset(marks[i])))
  fb.i16(endianness)
  let order_at = fb.mark()
  let schema = fb.table([
    { id: 1, mark: fields_at, width: 4, },
    { id: 0, mark: order_at, width: 2, },
  ])
  crafted_message(write_message(fb, HEADER_SCHEMA, schema, 0L), zeros(0))
}

///|
/// A little-endian schema message over hand-built fields.
fn crafted_schema(fields : Array[CraftedField]) -> Bytes {
  crafted_schema_as(fields, 0)
}

///|
/// A message's metadata alone: of the union member `header_type` (`-1`
/// names none), whose header is an empty table when `has_header` is set,
/// declaring `body` bytes, and under the metadata `version`.
fn crafted_message_as(
  header_type : Int32,
  has_header : Bool,
  body : Int64,
  version~ : Int32 = METADATA_VERSION,
) -> Bytes {
  let fb = Fb::new()
  let fields : Array[FieldMark] = []
  if has_header {
    let empty = fb.table([])
    fields.push({ id: 2, mark: fb.refer(empty), width: 4, })
  }
  if header_type >= 0 {
    fb.u8(header_type)
    fields.push({ id: 1, mark: fb.mark(), width: 1, })
  }
  fb.i64(body)
  fields.push({ id: 3, mark: fb.mark(), width: 8, })
  fb.i16(version)
  fields.push({ id: 0, mark: fb.mark(), width: 2, })
  let root = fb.table(fields)
  fb.finish(root)
}

///|
/// A payload of one field, with one record batch of `nodes` and `buffers`
/// over `body`.
fn crafted_payload(
  field : CraftedField,
  nodes : Array[(Int64, Int64)],
  buffers : Array[(Int64, Int64)],
  body : Bytes,
) -> Bytes {
  crafted_stream([crafted_schema([field]), crafted_batch(nodes, buffers, body)])
}

///|
/// Read the one column a payload of `field` carries — one record batch of
/// no cell — and answer the text of its refusal.
fn field_refusal(field : CraftedField) -> String raise {
  let payload = crafted_payload(field, [(0L, 0L)], [], zeros(0))
  refusal_text(fn() -> Unit raise @types.DataError {
    let reader = open_ipc(payload, Some([field.name]))
    ignore(reader.take_batch())
  })
}

///|
/// The text of the refusal a second message raises: a schema of one
/// integer column, then the metadata `message` framed with no body.
fn after_schema(message : Bytes) -> String raise {
  let schema = crafted_schema([typed("i", TYPE_INT)])
  refusal_text(fn() -> Unit raise @types.DataError {
    ignore(
      open_ipc(
        crafted_stream([schema, crafted_message(message, zeros(0))]),
        None,
      ),
    )
  })
}

// ── what a payload opens with ─────────────────────────────────────────

///|
test "a payload that does not open with a schema message refuses" {
  let empty = zeros(0)
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(empty, None))
    }),
    "malformed Arrow IPC: a payload carries no schema message",
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(
        open_ipc(crafted_stream([crafted_batch([(0L, 0L)], [], empty)]), None),
      )
    }),
    "malformed Arrow IPC: a payload does not open with a schema message",
  )
  let schema = crafted_schema([typed("i", TYPE_INT)])
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(crafted_stream([schema, schema]), None))
    }),
    "malformed Arrow IPC: a payload carries a second schema message",
  )
}

///|
test "a message whose header is missing or is not a tabular one refuses" {
  let empty = zeros(0)
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(
        open_ipc(
          crafted_stream([
            crafted_message(crafted_message_as(HEADER_SCHEMA, false, 0L), empty),
          ]),
          None,
        ),
      )
    }),
    "malformed Arrow IPC: a schema message carries no schema",
  )
  assert_eq(
    after_schema(crafted_message_as(HEADER_DICTIONARY, false, 0L)),
    "malformed Arrow IPC: a dictionary message carries no batch",
  )
  assert_eq(
    after_schema(crafted_message_as(HEADER_BATCH, false, 0L)),
    "malformed Arrow IPC: a record batch message carries no batch",
  )
  assert_eq(
    after_schema(crafted_message_as(8, true, 0L)),
    "Arrow IPC: a tensor or sparse tensor message, which is not a tabular payload",
  )
  assert_eq(
    after_schema(crafted_message_as(-1, false, 0L)),
    "malformed Arrow IPC: a message names no header",
  )
  // A dictionary batch whose table carries no batch of values.
  let fb = Fb::new()
  let dictionary = crafted_dictionary_table(fb, 0L, -1, false)
  let shell = write_message(fb, HEADER_DICTIONARY, dictionary, 0L)
  assert_eq(
    after_schema(shell),
    "malformed Arrow IPC: a dictionary message carries no batch",
  )
  // The version and the body's length are read before the header is.
  assert_eq(
    after_schema(crafted_message_as(HEADER_BATCH, false, 0L, version=5)),
    "Arrow IPC: a metadata version past V5 (this one is 6)",
  )
  assert_eq(
    after_schema(crafted_message_as(HEADER_BATCH, true, -1L)),
    "malformed Arrow IPC: a message's body length leaves the Int32 range",
  )
  assert_eq(
    after_schema(crafted_message_as(HEADER_BATCH, true, 2147483648L)),
    "malformed Arrow IPC: a message's body length leaves the Int32 range",
  )
  // The end marker's eight bytes are a body eight long; more is truncated.
  assert_eq(
    after_schema(crafted_message_as(HEADER_BATCH, true, 16L)),
    "malformed Arrow IPC: a message's body is truncated",
  )
}

///|
test "a record batch's header refuses a row count and a codec it cannot carry" {
  let one_cell = [(0L, 0L), (0L, 0L)]
  assert_eq(
    after_schema(crafted_batch_meta(-1L, [(0L, 0L)], one_cell, None, 0L)),
    "malformed Arrow IPC: a record batch's row count leaves the Int32 range",
  )
  assert_eq(
    after_schema(
      crafted_batch_meta(2147483648L, [(0L, 0L)], one_cell, None, 0L),
    ),
    "malformed Arrow IPC: a record batch's row count leaves the Int32 range",
  )
  assert_eq(
    after_schema(crafted_batch_meta(0L, [(0L, 0L)], one_cell, Some(2), 0L)),
    "malformed Arrow IPC: a record batch names a compression codec it does not carry",
  )
}

///|
test "a compression table that leaves its codec out names LZ4 frames" {
  assert_true(read_body_codec(None) is None)
  let fb = Fb::new()
  let table = fb.table([])
  let meta = fb.finish(table)
  assert_true(read_body_codec(Some(fb_root(meta))) is Some(Lz4Frame))
}

///|
test "a file whose footer leaves the file refuses" {
  let marker = b"ARROW1\x00\x00"
  // Too short for a footer and the tail's marker and length.
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(joined([marker, b"abc"]), None))
    }),
    "malformed Arrow IPC: an Arrow file is too short to hold a footer",
  )
  // A footer length that reaches before the head marker.
  let long = joined([marker, zeros(8), int32s([1000]), b"ARROW1"])
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(long, None))
    }),
    "malformed Arrow IPC: an Arrow file's footer length leaves the file",
  )
  // A footer that sits inside the file, with no marker after its length.
  let unmarked = joined([marker, zeros(8), int32s([8]), b"ARROWX"])
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(unmarked, None))
    }),
    "malformed Arrow IPC: an Arrow file's footer length leaves the file",
  )
}

// ── the schema ────────────────────────────────────────────────────────

///|
test "a schema nested deeper than the limit refuses" {
  // The limit counts every node of a field's subtree: a chain of 63
  // structs over an integer is 64 deep and reads, and one struct more is
  // past it.
  let mut deep : ArrowType = Int64
  for _ in 0..<63 {
    deep = Struct([("f", deep)])
  }
  let shallow = open_ipc(
    crafted_stream([crafted_message(schema_metadata([("s", deep)]), zeros(0))]),
    None,
  )
  assert_eq(shallow.batch_count(), 0)
  let deeper = ArrowType::Struct([("f", deep)])
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(
        open_ipc(
          crafted_stream([
            crafted_message(schema_metadata([("s", deeper)]), zeros(0)),
          ]),
          None,
        ),
      )
    }),
    "malformed Arrow IPC: a field is nested deeper than 64 levels",
  )
}

///|
test "a field whose type the schema cannot spell refuses" {
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(crafted_schema([typed("f", -1)]), None))
    }),
    "malformed Arrow IPC: a field names no type",
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(crafted_schema_as([typed("i", TYPE_INT)], 2), None))
    }),
    "malformed Arrow IPC: a schema is neither little-endian nor big-endian",
  )
  // A date is counted in days or in milliseconds, and a time in one of
  // four units.
  let date = with_type("d", TYPE_DATE, fn(fb) { i16_field(fb, 0, 5) })
  assert_eq(
    field_refusal(date),
    "malformed Arrow IPC: a date is counted in a unit the schema does not have",
  )
  let stamp = with_type("t", TYPE_TIMESTAMP, fn(fb) { i16_field(fb, 0, 5) })
  assert_eq(
    field_refusal(stamp),
    "malformed Arrow IPC: a time is counted in a unit the schema does not have",
  )
  let span = with_type("s", TYPE_DURATION, fn(fb) { i16_field(fb, 0, -1) })
  assert_eq(
    field_refusal(span),
    "malformed Arrow IPC: a time is counted in a unit the schema does not have",
  )
}

///|
test "a schema whose bodies are big-endian is read in that byte order" {
  let big = crafted_stream([
    crafted_schema_as([typed("i", TYPE_INT)], 1),
    crafted_batch([(1L, 0L)], [(0L, 0L), (0L, 4L)], b"\x00\x00\x00\x05"),
  ])
  let reader = open_ipc(big, None)
  assert_eq(reader.take_batch()[0].to_scalars().copy(), [@types.Scalar::Int(5)])
}

///|
test "a type with no dtype to read as refuses by its name" {
  let cases : Array[(CraftedField, String)] = [
    (typed("a", TYPE_RUN_END), "carries a run-end-encoded column"),
    (typed("b", TYPE_BINARY_VIEW), "carries a BinaryView column"),
    (typed("c", TYPE_UTF8_VIEW), "carries a Utf8View column"),
    (typed("d", TYPE_LIST_VIEW), "carries a ListView column"),
    (typed("e", TYPE_LARGE_LIST_VIEW), "carries a LargeListView column"),
    (
      typed("f", 99),
      "carries a type this reader does not know (union member 99) column",
    ),
    (typed("g", TYPE_UNION), "carries a union column"),
    (typed("h", TYPE_INTERVAL), "carries an interval column"),
    (typed("i", TYPE_TIME), "carries a time32 column, a time of day"),
  ]
  for item in cases {
    let text = field_refusal(item.0)
    assert_true(text.contains(item.1), msg=text)
  }
  // A 16-bit float, an integer of a width no integer type has, a decimal
  // wider than 128 bits, and one at a scale no decimal holds.
  let half = with_type("j", TYPE_FLOAT, fn(fb) { i16_field(fb, 0, 0) })
  let half_text = field_refusal(half)
  assert_true(half_text.contains("carries a Float16 column"), msg=half_text)
  let wide = with_type("k", TYPE_INT, fn(fb) { i32_field(fb, 0, 48) })
  let wide_text = field_refusal(wide)
  assert_true(
    wide_text.contains("carries an integer of 48 bits"),
    msg=wide_text,
  )
  let decimal256 = with_type("l", TYPE_DECIMAL, fn(fb) { i32_field(fb, 2, 256) })
  let decimal_text = field_refusal(decimal256)
  assert_true(
    decimal_text.contains("carries a Decimal256 column"),
    msg=decimal_text,
  )
  let scaled = with_type("m", TYPE_DECIMAL, fn(fb) { i32_field(fb, 1, -39) })
  let scaled_text = field_refusal(scaled)
  assert_true(
    scaled_text.contains(
      "a decimal whose scale leaves the range a decimal holds",
    ),
    msg=scaled_text,
  )
  // A list of two children, and a struct with no field.
  let two_children = CraftedField::{
    ..typed("n", TYPE_LIST),
    children: [typed("p", TYPE_INT), typed("q", TYPE_INT)],
  }
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(crafted_schema([two_children]), None))
    }),
    "malformed Arrow IPC: a list field does not carry exactly one child",
  )
  let bare_text = field_refusal(typed("o", TYPE_STRUCT))
  assert_true(
    bare_text.contains("carries a struct with no field"),
    msg=bare_text,
  )
}

///|
test "the empty columns of a payload name a refused column's refusal too" {
  // A window that selects no rows reads a zero-row column of every chosen
  // column's dtype, and a column whose type has no dtype refuses there as
  // it does when its cells are read.
  let reader = open_ipc(
    crafted_schema([typed("i", TYPE_INT), typed("t", TYPE_TIME)]),
    None,
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(reader.empty_columns())
    }),
    "Arrow IPC: column \"t\" carries a time32 column, a time of day, which has no dtype to read as",
  )
}

///|
test "a list or a struct over a child that has no dtype refuses for that child" {
  let times = typed("t", TYPE_TIME)
  let list_of_times = CraftedField::{
    ..typed("l", TYPE_LIST),
    children: [times],
  }
  let list_text = field_refusal(list_of_times)
  assert_true(
    list_text.contains("carries a list of a time32 column, a time of day"),
    msg=list_text,
  )
  let holding = CraftedField::{
    ..typed("s", TYPE_STRUCT),
    children: [typed("u", TYPE_UNION)],
  }
  let holding_text = field_refusal(holding)
  assert_true(
    holding_text.contains("carries a struct holding a union column"),
    msg=holding_text,
  )
  let twice = CraftedField::{
    ..typed("s", TYPE_STRUCT),
    children: [typed("a", TYPE_INT), typed("a", TYPE_INT)],
  }
  let twice_text = field_refusal(twice)
  assert_true(
    twice_text.contains("carries a struct whose field names repeat"),
    msg=twice_text,
  )
}

// ── the dictionaries ──────────────────────────────────────────────────

///|
/// A dictionary-encoded string field, against dictionary 0 over signed
/// 8-bit indices.
fn encoded_text() -> CraftedField {
  CraftedField::{ ..typed("d", TYPE_UTF8), dictionary_id: 0L, index_width: 8, }
}

///|
/// A dictionary batch's body: the one-byte cells of `cells`, each a cell.
fn one_byte_cells(cells : String) -> (Array[(Int64, Int64)], Bytes) {
  let bytes = @utf8.encode(cells)
  let offsets : Array[Int32] = []
  for i in 0..<=bytes.length() {
    offsets.push(i)
  }
  let width = (offsets.length() * 4).to_int64()
  let count = bytes.length().to_int64()
  ([(0L, 0L), (0L, width), (width, count)], joined([int32s(offsets), bytes]))
}

///|
test "a dictionary batch extends the dictionary it follows when it is a delta" {
  let schema = crafted_schema([encoded_text()])
  let (first_buffers, first_body) = one_byte_cells("ab")
  let first = crafted_dictionary(
    0L,
    [(2L, 0L)],
    first_buffers,
    first_body,
    false,
  )
  let (more_buffers, more_body) = one_byte_cells("c")
  let more = crafted_dictionary(0L, [(1L, 0L)], more_buffers, more_body, true)
  // The indices 0, 2, 1 read `a`, `c`, `b` over the extended dictionary.
  let batch = crafted_batch(
    [(3L, 0L)],
    [(0L, 0L), (0L, 3L)],
    Bytes::from_array([b'\x00', b'\x02', b'\x01']),
  )
  let reader = open_ipc(crafted_stream([schema, first, more, batch]), None)
  assert_eq(reader.take_batch()[0].to_scalars().copy(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("c"),
    @types.Scalar::String("b"),
  ])
  // A delta that no batch precedes is a dictionary on its own.
  let one = crafted_batch(
    [(1L, 0L)],
    [(0L, 0L), (0L, 1L)],
    Bytes::from_array([b'\x00']),
  )
  let lone = open_ipc(crafted_stream([schema, more, one]), None)
  assert_eq(lone.take_batch()[0].to_scalars().copy(), [
    @types.Scalar::String("c"),
  ])
  // A dictionary batch that is no delta replaces what was read.
  let replaced = crafted_dictionary(
    0L,
    [(1L, 0L)],
    more_buffers,
    more_body,
    false,
  )
  let replacing = open_ipc(
    crafted_stream([schema, first, replaced, batch]),
    None,
  )
  let text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(replacing.take_batch())
  })
  assert_true(
    text.contains("dictionary index (2) past its dictionary's 1 values"),
    msg=text,
  )
}

///|
test "a dictionary read refuses what does not line up" {
  let schema = crafted_schema([encoded_text()])
  let batch = crafted_batch(
    [(1L, 0L)],
    [(0L, 0L), (0L, 1L)],
    Bytes::from_array([b'\x00']),
  )
  // A record batch that reads the dictionary before a batch carries it.
  let early = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(open_ipc(crafted_stream([schema, batch]), None).take_batch())
  })
  assert_true(
    early.contains("reads dictionary 0 before a batch carries it"),
    msg=early,
  )
  // A dictionary batch for an id the schema does not name.
  let (buffers, body) = one_byte_cells("z")
  let stray = crafted_dictionary(7L, [(1L, 0L)], buffers, body, false)
  let stray_text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(open_ipc(crafted_stream([schema, stray]), None).take_batch())
  })
  assert_true(
    stray_text.contains("a dictionary batch names an id the schema does not"),
    msg=stray_text,
  )
  // An index past the dictionary's values.
  let (two_buffers, two_body) = one_byte_cells("yz")
  let values = crafted_dictionary(0L, [(2L, 0L)], two_buffers, two_body, false)
  let over = crafted_batch(
    [(1L, 0L)],
    [(0L, 0L), (0L, 1L)],
    Bytes::from_array([b'\x05']),
  )
  let over_text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(open_ipc(crafted_stream([schema, values, over]), None).take_batch())
  })
  assert_true(
    over_text.contains("dictionary index (5) past its dictionary's 2 values"),
    msg=over_text,
  )
  // Indices of a width no integer type has.
  let odd = CraftedField::{ ..encoded_text(), index_width: 24, }
  let odd_text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(
      open_ipc(crafted_stream([crafted_schema([odd]), batch]), None).take_batch(),
    )
  })
  assert_true(odd_text.contains("dictionary indices of 24 bits"), msg=odd_text)
  // A dictionary of values that have no dtype to read as.
  let times = CraftedField::{
    ..typed("t", TYPE_TIME),
    dictionary_id: 1L,
    index_width: 16,
  }
  let time_text = field_refusal(times)
  assert_true(time_text.contains("carries a time32 column"), msg=time_text)
}

// ── the record batches ────────────────────────────────────────────────

///|
test "a null column is bounded by the cell budget" {
  let over = crafted_payload(
    typed("n", TYPE_NULL),
    [(CELL_BUDGET + 1L, 0L)],
    [],
    zeros(0),
  )
  let text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(open_ipc(over, None).take_batch())
  })
  assert_eq(
    text, "Arrow IPC: column \"n\" is a null column of 134217729 cells, past the 134217728-cell budget",
  )
  // The whole-payload read counts the rows off the headers first, and
  // refuses before any cell is built.
  let whole = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(read_ipc_frame(over, None))
  })
  assert_eq(
    whole, "Arrow IPC: the payload's record batches carry 134217729 rows over its 1 columns, past the 134217728-cell budget a column is read within",
  )
}

///|
test "a record batch must account for its nodes and buffers" {
  let ints = typed("i", TYPE_INT)
  // A buffer the schema does not name.
  let extra = crafted_payload(
    ints,
    [(0L, 0L)],
    [(0L, 0L), (0L, 0L), (0L, 0L)],
    zeros(0),
  )
  let extra_text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(open_ipc(extra, None).take_batch())
  })
  assert_eq(
    extra_text, "malformed Arrow IPC: a record batch carries nodes or buffers its schema does not account for",
  )
  // A buffer the schema names and the batch lacks.
  let short = crafted_payload(ints, [(0L, 0L)], [], zeros(0))
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(short, None).take_batch())
    }),
    "malformed Arrow IPC: a record batch's fields ask for more buffers than it carries",
  )
  // A node the schema names and the batch lacks.
  let nodeless = crafted_payload(ints, [], [(0L, 0L), (0L, 0L)], zeros(0))
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(nodeless, None).take_batch())
    }),
    "malformed Arrow IPC: a record batch's fields ask for more nodes than it carries",
  )
  // A buffer that does not sit inside the body.
  let outside = crafted_payload(
    ints,
    [(1L, 0L)],
    [(0L, 0L), (0L, 8L)],
    zeros(4),
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(outside, None).take_batch())
    }),
    "malformed Arrow IPC: a buffer leaves its record batch's body",
  )
  // A column the projection leaves out is stepped over by its counts,
  // which the batch may not have.
  let two = crafted_stream([
    crafted_schema([ints, typed("j", TYPE_INT)]),
    crafted_batch([(0L, 0L)], [(0L, 0L), (0L, 0L)], zeros(0)),
  ])
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(two, Some(["i"])).take_batch())
    }),
    "malformed Arrow IPC: a record batch's fields ask for more than it carries",
  )
  // A column left out whose layout cannot be counted from the schema.
  let views = crafted_stream([
    crafted_schema([ints, typed("v", TYPE_BINARY_VIEW)]),
    crafted_batch(
      [(0L, 0L), (0L, 0L)],
      [(0L, 0L), (0L, 0L), (0L, 0L)],
      zeros(0),
    ),
  ])
  let views_text = refusal_text(fn() -> Unit raise @types.DataError {
    ignore(open_ipc(views, Some(["i"])).take_batch())
  })
  assert_eq(
    views_text, "Arrow IPC: column \"v\" carries a BinaryView column, whose layout this reader cannot step over",
  )
}

///|
test "a nested column's children must line up with its layout" {
  // A struct of two cells whose child holds one.
  let record = CraftedField::{
    ..typed("s", TYPE_STRUCT),
    children: [typed("a", TYPE_INT)],
  }
  let short_child = crafted_payload(
    record,
    [(2L, 0L), (1L, 0L)],
    [(0L, 0L), (0L, 0L), (0L, 8L)],
    zeros(8),
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(short_child, None).take_batch())
    }),
    "malformed Arrow IPC: a struct's child holds a different number of cells than the struct",
  )
  // A list of two cells whose offsets span two values, over a child of
  // one.
  let list = CraftedField::{
    ..typed("l", TYPE_LIST),
    children: [typed("item", TYPE_INT)],
  }
  let short_values = crafted_payload(
    list,
    [(2L, 0L), (1L, 0L)],
    [(0L, 0L), (0L, 12L), (12L, 0L), (12L, 8L)],
    joined([int32s([0, 1, 2]), zeros(8)]),
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(short_values, None).take_batch())
    }),
    "malformed Arrow IPC: a list's child holds a different number of values than its offsets span",
  )
  // Offsets that stay put make an empty cell, and ones that go back
  // refuse.
  let flat = crafted_payload(
    list,
    [(2L, 0L), (1L, 0L)],
    [(0L, 0L), (0L, 12L), (12L, 0L), (12L, 8L)],
    joined([int32s([0, 1, 1]), zeros(8)]),
  )
  let read = open_ipc(flat, None).take_batch()
  assert_eq(read[0].to_scalars().copy(), [
    @types.Scalar::List(@types.ListValue::ListValue([@types.Scalar::Int(0)])),
    @types.Scalar::List(@types.ListValue::ListValue([])),
  ])
  let decreasing = crafted_payload(
    list,
    [(2L, 0L), (1L, 0L)],
    [(0L, 0L), (0L, 12L), (12L, 0L), (12L, 8L)],
    joined([int32s([0, 1, 0]), zeros(8)]),
  )
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(open_ipc(decreasing, None).take_batch())
    }),
    "malformed Arrow IPC: a list's offsets do not increase",
  )
}

///|
test "a reader skips past its last batch without complaint" {
  // A skip past the last batch reads nothing; the next take still refuses.
  let payload = crafted_payload(typed("i", TYPE_NULL), [(0L, 0L)], [], zeros(0))
  let reader = open_ipc(payload, None)
  reader.skip_batch()
  reader.skip_batch()
  assert_eq(
    refusal_text(fn() -> Unit raise @types.DataError {
      ignore(reader.take_batch())
    }),
    "Arrow IPC: no record batch is left to read",
  )
}
