// The reader a payload is opened into. Opening maps the schema once and
// locates every message — walking the length prefixes alone, decoding
// nothing — so a batch's row count is known before any batch is read, and
// a batch outside a row window is skipped without touching its body. The
// batches then decode in stream order: a dictionary batch read on the way
// is what the batches after it index into.

///|
/// A dictionary batch's message: the id its schema gave the dictionary,
/// the header of the batch carrying its values, whether it extends the
/// dictionary already read, and where its body lies.
priv struct DictionaryEvent {
  id : Int64
  header : BatchHeader
  delta : Bool
  body_at : Int32
  next : Int32
}

///|
/// A record batch's message: its header, and where its body lies.
priv struct BatchEvent {
  header : BatchHeader
  body_at : Int32
  next : Int32
}

///|
priv enum Event {
  Dictionary(DictionaryEvent)
  Batch(BatchEvent)
}

///|
/// An Arrow IPC payload opened for reading: the stream format or the file
/// format, each read as the stream of messages it is. The columns are the
/// ones the projection names, in the file's own order; a name the file
/// does not carry builds no column, and `None` reads every column.
pub struct IpcReader {
  priv data : Bytes
  priv fields : Array[FieldPlan]
  priv chosen : Array[FieldPlan]
  priv picked : Array[Bool]
  priv events : Array[Event]
  priv rows : Array[Int64]
  priv big : Bool
  priv mut at : Int32
  priv dictionaries : Dictionaries
}

///|
/// Open a payload. A record batch is never decoded here: a column whose
/// type the mapping refuses raises when it is read, so a projection that
/// leaves it out reads the rest of the file. The columns the projection
/// does name must be ones the mapping carries and must not share a name —
/// both are decided at the schema, before any batch is read.
pub fn open_ipc(
  bytes : Bytes,
  projection : Array[String]?,
) -> IpcReader raise @types.DataError {
  let (start, end) = message_region(bytes)
  let first = match frame_message(bytes, start, end) {
    Message(m) => m
    End => raise malformed("a payload carries no schema message")
  }
  let table = match first.header {
    Schema(t) => t
    _ => raise malformed("a payload does not open with a schema message")
  }
  let (declared, big) = read_schema(table)
  let fields : Array[FieldPlan] = []
  for field in declared {
    fields.push(plan_of(field))
  }
  let chosen : Array[FieldPlan] = []
  let picked : Array[Bool] = []
  let columns : Array[@types.Field] = []
  for plan in fields {
    let wanted = match projection {
      Some(names) => names.contains(plan.name)
      None => true
    }
    picked.push(wanted)
    if wanted {
      // The dtype is not asked for yet: a column whose type the mapping
      // refuses raises when it is read, never at the schema.
      columns.push(@types.Field::Field(plan.name, @types.DataType::Int))
      chosen.push(plan)
    }
  }
  // The frame's own rule, met at the schema: two columns of one name.
  let schema = @types.Schema::Schema(columns)
  ignore(schema)
  let events : Array[Event] = []
  let rows : Array[Int64] = []
  let mut pos = first.next
  let mut done = false
  while !done {
    match frame_message(bytes, pos, end) {
      End => done = true
      // A message's metadata is at least eight bytes, so its end always
      // lies past its start.
      Message(m) => {
        match m.header {
          Schema(_) =>
            raise malformed("a payload carries a second schema message")
          Dictionary(id, header, delta) =>
            events.push(
              Dictionary({
                id,
                header,
                delta,
                body_at: m.body_at,
                next: m.next,
              }),
            )
          Batch(header) => {
            events.push(Batch({ header, body_at: m.body_at, next: m.next, }))
            rows.push(header.length)
          }
        }
        pos = m.next
      }
    }
  }
  {
    data: bytes,
    fields,
    chosen,
    picked,
    events,
    rows,
    big,
    at: 0,
    dictionaries: { ids: [], values: [], },
  }
}

///|
/// How many record batches the payload carries.
pub fn IpcReader::batch_count(self : IpcReader) -> Int32 {
  self.rows.length()
}

///|
/// The row count of record batch `index`, or zero for an index past the
/// last batch.
pub fn IpcReader::batch_rows(self : IpcReader, index : Int32) -> Int32 {
  match self.rows.get(index) {
    Some(n) => n.to_int()
    None => 0
  }
}

///|
/// The rows of every record batch, added.
pub fn IpcReader::total_rows(self : IpcReader) -> Int64 {
  let mut total = 0L
  for n in self.rows {
    total += n
  }
  total
}

///|
/// A zero-row column of every chosen column's dtype: what a window that
/// selects no rows reads.
pub fn IpcReader::empty_columns(
  self : IpcReader,
) -> Array[@series.Series] raise @types.DataError {
  let columns : Array[@series.Series] = []
  for plan in self.chosen {
    columns.push(
      @series.Series::from_scalars(plan.name, [], dtype=carried_dtype(plan)),
    )
  }
  columns
}

///|
/// The next record batch's columns. The batches answer in the order the
/// payload carries them, one per call; a call past the last raises
/// `InvalidOperation` — the caller counts them off `batch_count`.
pub fn IpcReader::take_batch(
  self : IpcReader,
) -> Array[@series.Series] raise @types.DataError {
  match self.step() {
    None =>
      raise @types.DataError::InvalidOperation(
        "Arrow IPC: no record batch is left to read",
      )
    Some(batches) => {
      let columns : Array[@series.Series] = []
      for c, cells in batches {
        let plan = self.chosen[c]
        columns.push(
          @series.Series::from_scalars(
            plan.name,
            cells,
            dtype=carried_dtype(plan),
          ),
        )
      }
      columns
    }
  }
}

///|
/// Step over the next record batch without decoding a byte of its body —
/// reading whatever dictionary batches stand before it, as a decode would.
/// A reader that skips a batch and then reads one answers the batches
/// after it exactly as if it had read the skipped one and dropped it.
pub fn IpcReader::skip_batch(self : IpcReader) -> Unit raise @types.DataError {
  match self.step() {
    None => ()
    Some(_) => ()
  }
}

///|
/// The next record batch's cells, reading whatever dictionaries stand
/// before it, or `None` once every batch is read.
fn IpcReader::step(
  self : IpcReader,
) -> Array[Array[@types.Scalar]]? raise @types.DataError {
  while self.at < self.events.length() {
    let event = self.events[self.at]
    self.at += 1
    match event {
      Dictionary(message) => self.read_dictionary(message)
      Batch(message) => return Some(self.decode_batch(message))
    }
  }
  None
}

///|
/// The decoder over one message's body.
fn IpcReader::decoder(
  self : IpcReader,
  header : BatchHeader,
  body_at : Int32,
  next : Int32,
  column : String,
) -> Decode {
  {
    data: self.data,
    body_at,
    body_len: next - body_at,
    nodes: header.nodes,
    buffers: header.buffers,
    node: 0,
    buffer: 0,
    codec: header.codec,
    big: self.big,
    dictionaries: self.dictionaries,
    column,
  }
}

///|
/// One record batch's chosen columns, each field's cells in the file's
/// order; a field the projection leaves out is stepped over unread.
fn IpcReader::decode_batch(
  self : IpcReader,
  message : BatchEvent,
) -> Array[Array[@types.Scalar]] raise @types.DataError {
  let d = self.decoder(message.header, message.body_at, message.next, "")
  let out : Array[Array[@types.Scalar]] = []
  for i, plan in self.fields {
    if self.picked[i] {
      d.column = plan.name
      out.push(decode_field(d, plan))
    } else {
      d.skip(plan)
    }
  }
  d.settled()
  out
}

///|
/// One dictionary batch: its values decoded by the layout of the field it
/// belongs to — the field without its encoding — and kept under its id.
fn IpcReader::read_dictionary(
  self : IpcReader,
  message : DictionaryEvent,
) -> Unit raise @types.DataError {
  let plan = match find_dictionary(self.fields, message.id) {
    Some(p) => p
    None =>
      raise malformed("a dictionary batch names an id the schema does not")
  }
  let d = self.decoder(
    message.header,
    message.body_at,
    message.next,
    "dictionary \{message.id}",
  )
  let node = d.take_node()
  let length = node_length(node)
  let cells = decode_values(d, plan, node, length)
  d.settled()
  d.dictionaries.set(message.id, cells, message.delta)
}

///|
/// The first field encoded against dictionary `id`.
fn find_dictionary(fields : Array[FieldPlan], id : Int64) -> FieldPlan? {
  for plan in fields {
    if plan.encoded && plan.dictionary_id == id {
      return Some(plan)
    }
    match find_dictionary(plan.children, id) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  None
}

///|
/// The whole payload as one frame's columns, each column's cells joined
/// over its batches, and the payload's row count — the whole-file entry
/// the io layer rides. The projection is `open_ipc`'s: a lenient one
/// that matches no column answers zero columns and still reports the
/// rows.
pub fn read_ipc_frame(
  bytes : Bytes,
  projection : Array[String]?,
) -> (Array[(String, @series.Series)], Int64) raise @types.DataError {
  let reader = open_ipc(bytes, projection)
  // The cells a column will hold are known from the batch headers before
  // any batch decodes, so the budget refuses before the cells are built.
  if !reader.chosen.is_empty() && reader.total_rows() > CELL_BUDGET {
    raise @types.DataError::InvalidOperation(
      "Arrow IPC: the payload's record batches carry \{reader.total_rows()} rows over its \{reader.chosen.length()} columns, past the \{CELL_BUDGET}-cell budget a column is read within",
    )
  }
  let joined : Array[Array[@types.Scalar]] = []
  for _ in reader.chosen {
    joined.push([])
  }
  // The rows are counted off each batch's header, not off a column: a
  // projection that matches no column still reads the payload's rows.
  let mut rows = 0L
  let mut at = 0
  let mut done = false
  while !done {
    match reader.step() {
      None => done = true
      Some(batches) => {
        for c, cells in batches {
          joined[c].append(cells)
        }
        rows += reader.batch_rows(at).to_int64()
        at += 1
      }
    }
  }
  let columns : Array[(String, @series.Series)] = []
  for c, plan in reader.chosen {
    columns.push(
      (
        plan.name,
        @series.Series::from_scalars(
          plan.name,
          joined[c],
          dtype=carried_dtype(plan),
        ),
      ),
    )
  }
  (columns, rows)
}
