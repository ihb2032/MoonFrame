// The container — the file's magic, its metadata, the marker every block
// ends with, and the blocks a reader walks — under the two halves of the
// mapping to columns: a schema's types narrowed to what a column can hold
// on a read, and a frame's dtypes widened to the types the writer emits.

///|
/// The compression a written block carries (the reader takes every codec
/// it can decode; this names the writer's).
#derive(Eq, Debug)
pub(all) enum Codec {
  Null
  Deflate
  Snappy
  Zstd
}

///|
pub extend Codec with Eq::{equal, not_equal}

///|
pub extend Codec with Debug::{to_repr}

///|
/// A field's type narrowed to what a column can hold: every shape the
/// mapping refuses is refused before a value is read, so the decoder
/// meets only types it can build a cell from.
priv enum CellType {
  CNull
  CBoolean
  CIntPlain
  CIntDate
  CIntTimeMillis
  CLongPlain
  CLongTimeMicros
  CLongTimestampMillis
  CLongTimestampMicros
  CFloat
  CDouble
  CDecimalBytes(DecimalShape)
  CDecimalFixed(Int32, DecimalShape)
  CString
  CRecord(Array[CellField])
  CEnum(Array[String])
  CArray(CellType)
  COptional(Int32, CellType)
}

///|
/// One field of a record a column can hold.
priv struct CellField {
  name : String
  ty : CellType
}

///|
/// How many bytes a block may inflate to. A compressed block declares only
/// its compressed size, so this bound is what stands between a small file
/// and an unbounded allocation.
const MAX_BLOCK_BYTES : Int32 = 268435456

///|
/// How many metadata entries a file's header may carry.
const MAX_METADATA : Int64 = 1024L

///|
/// The records a written block holds.
const BLOCK_ROWS : Int32 = 10000

///|
/// The records past which a file is refused: the height a column's length
/// holds.
const MAX_RECORDS : Int64 = 2147483647L

///|
/// How deep the schema's JSON may nest.
const SCHEMA_JSON_DEPTH : Int32 = 128

///|
/// The file's header: the schema text, the codec its blocks are
/// compressed with, and the marker every block ends with.
priv struct Header {
  schema : String
  codec : Codec
  sync : Bytes
}

///|
/// The codec a file's metadata names, the default being none.
fn codec_named(name : String) -> Codec raise @types.DataError {
  match name {
    "null" => Null
    "deflate" => Deflate
    "snappy" => Snappy
    "zstandard" => Zstd
    other => raise cannot_carry("a block codec named \"\{other}\"")
  }
}

///|
/// The name a codec is written under.
fn Codec::name(self : Codec) -> String {
  match self {
    Null => "null"
    Deflate => "deflate"
    Snappy => "snappy"
    Zstd => "zstandard"
  }
}

///|
/// The header at the cursor: the magic, the metadata map, and the sync
/// marker. Of the metadata only the schema text and the codec are kept.
fn read_header(cur : Cursor) -> Header raise @types.DataError {
  if cur.remaining() < 4 {
    raise malformed("bytes that do not open with the Avro magic")
  }
  let magic = cur.take(4)
  if magic[0] != b'O' ||
    magic[1] != b'b' ||
    magic[2] != b'j' ||
    magic[3] != b'\x01' {
    raise malformed("bytes that do not open with the Avro magic")
  }
  let mut schema : String? = None
  let mut codec : String? = None
  let mut entries = 0L
  while true {
    let count = cur.block_count()
    if count == 0L {
      break
    }
    entries = entries + count
    if entries > MAX_METADATA {
      raise malformed("more than \{MAX_METADATA} metadata entries")
    }
    for _ in 0L..<count {
      let key = cur.string()
      let value = cur.string()
      match key {
        "avro.schema" => schema = Some(value)
        "avro.codec" => codec = Some(value)
        _ => ()
      }
    }
  }
  if cur.remaining() < 16 {
    raise malformed("a file that ends inside its sync marker")
  }
  let sync = cur.take(16)
  Header::{
    schema: schema.unwrap_or(""),
    codec: codec_named(codec.unwrap_or("null")),
    sync,
  }
}

///|
/// A block's bytes as the writer encoded them, before its codec
/// compressed them — inflated under the bound `MAX_BLOCK_BYTES`, which is
/// the one thing standing between a small compressed block and an
/// unbounded allocation. A snappy block ends with a checksum over exactly
/// these bytes, so it is checked here, against them.
fn inflate(codec : Codec, payload : Bytes) -> Bytes raise @types.DataError {
  match codec {
    Null => payload
    // A raw DEFLATE stream. Its final block can be followed by bytes a
    // writer left behind, which the stream's own end makes harmless: they
    // are ignored, the way a reader that stops at the final block reads.
    Deflate =>
      @flate.inflate_all(payload, max_output=MAX_BLOCK_BYTES) catch {
        _ =>
          raise malformed(
            "a deflate block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
          )
      }
    Snappy => {
      // The snappy stream, then four bytes: the block's CRC-32.
      if payload.length() < 4 {
        raise malformed("a snappy block shorter than its checksum")
      }
      let stream = payload.exact_view(end=payload.length() - 4).to_owned()
      let out = @snappy.decompress_raw(stream, max_output=MAX_BLOCK_BYTES) catch {
        _ =>
          raise malformed(
            "a snappy block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
          )
      }
      if crc32(out) != be32(payload, payload.length() - 4) {
        raise malformed(
          "a snappy block whose checksum does not match its bytes",
        )
      }
      out
    }
    Zstd =>
      @zstd.decompress(payload, max_output=MAX_BLOCK_BYTES) catch {
        _ =>
          raise malformed(
            "a zstandard block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
          )
      }
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
/// A block's CRC-32: the checksum a snappy block carries over the bytes
/// it held before compression.
fn crc32(bytes : Bytes) -> UInt32 {
  @crc.crc32_update(0U, bytes)
}

///|
/// A block's encoded bytes under the codec — for snappy, the compressed
/// stream and the four bytes of its checksum after it.
fn compress(codec : Codec, body : Bytes) -> Bytes {
  match codec {
    Null => body
    Deflate => @flate.deflate_all(body)
    Snappy => with_checksum(@snappy.compress_raw(body), body)
    Zstd => @zstd.compress(body)
  }
}

///|
/// A snappy stream followed by its checksum over `body`.
fn with_checksum(stream : Bytes, body : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for b in stream {
    out.push(b)
  }
  push_be(out, crc32(body).to_uint64(), 4)
  Bytes::from_array(out)
}

///|
/// The type a column carries for a field, and the dtype it reads as.
/// Every shape the mapping does not carry is refused here, naming the
/// field's way from the record.
fn cell_type(
  ty : AvroType,
  path : String,
) -> (CellType, @types.DataType) raise @types.DataError {
  match ty {
    // A field typed null alone holds nothing but nulls: the column is
    // all-null, of the dtype an all-null column reads as.
    TNull => (CNull, @types.DataType::String)
    TBoolean => (CBoolean, @types.DataType::Bool)
    TInt(logical) =>
      match logical {
        Plain => (CIntPlain, @types.DataType::Int)
        Date => (CIntDate, @types.DataType::Date)
        TimeMillis => (CIntTimeMillis, @types.DataType::Timestamp)
      }
    TLong(logical) =>
      match logical {
        Plain => (CLongPlain, @types.DataType::Int)
        TimeMicros => (CLongTimeMicros, @types.DataType::Timestamp)
        TimestampMillis => (CLongTimestampMillis, @types.DataType::Timestamp)
        TimestampMicros => (CLongTimestampMicros, @types.DataType::Timestamp)
        Nanos =>
          raise cannot_carry(
            "a nanosecond timestamp field \"\{path}\": a timestamp here holds microseconds, and the nanoseconds would be rounded away",
          )
      }
    TFloat => (CFloat, @types.DataType::Float)
    TDouble => (CDouble, @types.DataType::Float)
    TBytes(Some(shape)) => (CDecimalBytes(shape), @types.DataType::Decimal)
    TBytes(None) =>
      raise cannot_carry(
        "a bytes field \"\{path}\": the mapping has no binary column",
      )
    TString => (CString, @types.DataType::String)
    TRecord(fields) => {
      if fields.is_empty() {
        raise cannot_carry("a record field \"\{path}\" with no field")
      }
      let cell_fields : Array[CellField] = []
      let fields_out : Array[@types.Field] = []
      for field in fields {
        let inner_path = "\{path}.\{field.name}"
        let (field_ty, field_dtype) = cell_type(field.ty, inner_path)
        cell_fields.push({ name: field.name, ty: field_ty, })
        fields_out.push(@types.Field::Field(field.name, field_dtype))
      }
      (
        CRecord(cell_fields),
        @types.DataType::Struct(@types.Schema::Schema(fields_out)),
      )
    }
    TEnum(symbols) => (CEnum(symbols), @types.DataType::String)
    TArray(items) => {
      let (item_ty, item_dtype) = cell_type(items, path)
      (CArray(item_ty), @types.DataType::List(item_dtype))
    }
    TMap(_) =>
      raise cannot_carry(
        "a map field \"\{path}\": the mapping has no map column",
      )
    TUnion(branches) =>
      if branches.length() == 1 {
        cell_type(branches[0], path)
      } else if branches.length() == 2 &&
        (branches[0] is TNull || branches[1] is TNull) {
        let null_at = if branches[0] is TNull { 0 } else { 1 }
        let (inner_ty, dtype) = cell_type(branches[1 - null_at], path)
        (COptional(null_at, inner_ty), dtype)
      } else {
        raise cannot_carry(
          "a union field \"\{path}\" of \{branches.length()} branches: a column carries a null and one type",
        )
      }
    TFixed(size, Decimal(shape)) =>
      (CDecimalFixed(size, shape), @types.DataType::Decimal)
    TFixed(_, Duration) =>
      raise cannot_carry(
        "a duration field \"\{path}\": the months, days and milliseconds it holds are no single span",
      )
    TFixed(_, Plain) =>
      raise cannot_carry(
        "a fixed field \"\{path}\": the mapping has no binary column",
      )
  }
}

///|
/// One field the read keeps: its name, the type it decodes under, the
/// dtype its column is built with, and the cells read so far.
priv struct ColumnPlan {
  name : String
  ty : CellType
  dtype : @types.DataType
  cells : Array[@types.Scalar]
}

///|
/// The columns of the Avro container in `bytes`, in the file's order, and
/// the count of records the file holds. `projection` keeps only the fields
/// it names — a name the file does not carry builds no column — and every
/// other field is stepped over without being materialised. Raises
/// `ParseError` for bytes that are not a container that holds together (a
/// truncated or malformed header, schema, block or datum, a block that
/// does not decompress, a sync marker that differs from the file's),
/// `Unsupported` for what the mapping does not carry (a block codec other
/// than null / deflate / snappy / zstandard, a top-level schema that is
/// not a record, a bytes or fixed field without a decimal logical type, a
/// map field, a union of more than a null and one type, a nanosecond
/// timestamp, a decimal cell past 34 significant digits).
pub fn read_avro_frame(
  bytes : Bytes,
  projection : Array[String]?,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let cur = Cursor::{ bytes, at: 0, }
  let header = read_header(cur)
  let schema_json = @json.parse(
    header.schema.clamped_view(),
    max_nesting_depth=SCHEMA_JSON_DEPTH,
  ) catch {
    _ => raise malformed("a schema that is not valid JSON")
  }
  let reader = SchemaReader::{ names: Map([]), defining: [], }
  let fields = match reader.read(schema_json, 0) {
    TRecord(fields) => fields
    _ => raise cannot_carry("a file whose top-level schema is not a record")
  }
  // A plan beside every field: the fields the read keeps, and a gap for
  // each it steps over.
  let plans : Array[ColumnPlan?] = []
  for field in fields {
    let wanted = match projection {
      Some(names) => names.contains(field.name)
      None => true
    }
    if wanted {
      let (ty, dtype) = cell_type(field.ty, field.name)
      plans.push(Some(ColumnPlan::{ name: field.name, ty, dtype, cells: [], }))
    } else {
      plans.push(None)
    }
  }
  let budget = Budget::{ items: 0L, }
  let mut records = 0L
  while cur.remaining() > 0 {
    let count = cur.long()
    // The subtraction form: a count near the Int64 ceiling could not wrap
    // the sum back under the bound.
    if count <= 0L || count > MAX_RECORDS - records {
      raise malformed("a block of \{count} records")
    }
    let size = cur.long()
    if size < 0L || size > (cur.remaining() - 16).to_int64() {
      raise malformed("a block of \{size} bytes, past what the file holds")
    }
    let payload = cur.take(size.to_int())
    let sync = cur.take(16)
    if !same_bytes(sync, header.sync) {
      raise malformed("a block whose sync marker differs from the file's")
    }
    let block = Cursor::{ bytes: inflate(header.codec, payload), at: 0, }
    for _ in 0L..<count {
      for i, field in fields {
        match plans[i] {
          Some(plan) =>
            plan.cells.push(decode_value(block, plan.ty, budget, plan.name))
          None => skip_value(block, field.ty, budget)
        }
      }
    }
    if block.remaining() != 0 {
      raise malformed("a block carrying bytes past its last record")
    }
    records = records + count
  }
  let out : Array[(String, @series.Series)] = []
  for plan in plans {
    if plan is Some(kept) {
      out.push(
        (
          kept.name,
          @series.Series::from_scalars(kept.name, kept.cells, dtype=kept.dtype),
        ),
      )
    }
  }
  (out, records.to_int())
}

///|
/// Whether two byte strings of one length say the same.
fn same_bytes(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    false
  } else {
    a.range_equal(start=0, b, other_start=0, len=a.length())
  }
}

///|
/// One Avro container holding `columns` under `names`, its blocks
/// compressed by `codec`. Every field is written as a nullable union, so a
/// null lands wherever a column holds one. Raises `InvalidOperation` when
/// `names` disagrees with the columns' own names, for a column whose name
/// is not a name the schema allows, and for a cell the mapping cannot
/// write (a decimal needing more than 38 digits); `LengthMismatch` for
/// columns of different lengths; `Unsupported` for a `Null` or `Duration`
/// column.
pub fn write_avro_bytes(
  columns : Array[@series.Series],
  names : Array[String],
  codec : Codec,
  height? : Int32,
) -> Bytes raise @types.DataError {
  let columns = columns.copy()
  let names = names.copy()
  if names.length() != columns.length() {
    raise @types.DataError::InvalidOperation(
      "the Avro writer was handed \{names.length()} names for \{columns.length()} columns",
    )
  }
  for i in 0..<columns.length() {
    if names[i] != columns[i].name() {
      raise @types.DataError::InvalidOperation(
        "the Avro writer's name \{i} (\{names[i]}) disagrees with its column's own (\{columns[i].name()})",
      )
    }
  }
  let nrows = match height {
    Some(h) => h
    None => if columns.is_empty() { 0 } else { columns[0].len() }
  }
  let cells : Array[Array[@types.Scalar]] = []
  let field_types : Array[CellType] = []
  let field_jsons : Array[Json] = []
  for i, column in columns {
    if column.len() != nrows {
      raise @types.DataError::LengthMismatch(nrows, column.len())
    }
    check_name(names[i], names[i])
    let scalars = column.to_scalars()
    let (ty, json) = write_type(column.dtype(), scalars, names[i])
    cells.push(scalars)
    field_types.push(COptional(0, ty))
    field_jsons.push(nullable_field(names[i], json))
  }
  let schema_text = schema_json(field_jsons).stringify()
  let sync = sync_marker(schema_text)
  let out : Array[Byte] = []
  for b in b"Obj\x01" {
    out.push(b)
  }
  push_long(out, 2L)
  push_string(out, "avro.schema")
  push_string(out, schema_text)
  push_string(out, "avro.codec")
  push_string(out, codec.name())
  push_long(out, 0L)
  for b in sync {
    out.push(b)
  }
  for start = 0; start < nrows; start = start + BLOCK_ROWS {
    let end = if start + BLOCK_ROWS < nrows {
      start + BLOCK_ROWS
    } else {
      nrows
    }
    let body : Array[Byte] = []
    for r in start..<end {
      for c in 0..<cells.length() {
        encode_value(body, cells[c][r], field_types[c], names[c])
      }
    }
    let payload = compress(codec, Bytes::from_array(body))
    push_long(out, (end - start).to_int64())
    push_long(out, payload.length().to_int64())
    for b in payload {
      out.push(b)
    }
    for b in sync {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// The record schema a write names: every column a field of one record.
fn schema_json(fields : Array[Json]) -> Json {
  let root : Map[String, Json] = Map([])
  root["type"] = Json::string("record")
  root["name"] = Json::string("topLevelRecord")
  root["fields"] = Json::array(fields)
  Json::object(root)
}

///|
/// A field written as a nullable union, under the name the record gives it.
fn nullable_field(name : String, ty : Json) -> Json {
  let field : Map[String, Json] = Map([])
  field["name"] = Json::string(name)
  field["type"] = Json::array([Json::string("null"), ty])
  Json::object(field)
}

///|
/// Whether `name` is a name the schema allows — letters, digits and `_`,
/// starting with a letter or `_` — the refusal naming `path`.
fn check_name(name : String, path : String) -> Unit raise @types.DataError {
  let mut allowed = name.length() > 0
  for i in 0..<name.length() {
    let c = name[i].to_int()
    let letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    let digit = c >= 48 && c <= 57
    if i == 0 {
      allowed = allowed && letter
    } else {
      allowed = allowed && (letter || digit)
    }
  }
  if !allowed {
    raise @types.DataError::InvalidOperation(
      "column \"\{path}\": the name \"\{name}\" is not one an Avro schema allows (letters, digits and _, starting with a letter or _)",
    )
  }
}

///|
/// The type a column is written as, with the schema entry that names it:
/// the dtype and its cells decide — a decimal's precision and scale are
/// the narrowest its cells fit.
fn write_type(
  dtype : @types.DataType,
  cells : Array[@types.Scalar],
  path : String,
) -> (CellType, Json) raise @types.DataError {
  match dtype {
    Int => (CLongPlain, Json::string("long"))
    Float => (CDouble, Json::string("double"))
    Bool => (CBoolean, Json::string("boolean"))
    String => (CString, Json::string("string"))
    Date => (CIntDate, logical_json("int", "date"))
    Timestamp =>
      (CLongTimestampMicros, logical_json("long", "timestamp-micros"))
    Decimal => {
      let shape = decimal_shape_of(cells, path)
      let decimal : Map[String, Json] = Map([])
      decimal["type"] = Json::string("bytes")
      decimal["logicalType"] = Json::string("decimal")
      decimal["precision"] = Json::number(shape.precision.to_double())
      decimal["scale"] = Json::number(shape.scale.to_double())
      (CDecimalBytes(shape), Json::object(decimal))
    }
    List(inner) => {
      let (item_ty, item_json) = write_type(inner, list_items(cells), path)
      let array : Map[String, Json] = Map([])
      array["type"] = Json::string("array")
      array["items"] = Json::array([Json::string("null"), item_json])
      (CArray(item_ty), Json::object(array))
    }
    Struct(schema) => {
      let field_types : Array[CellField] = []
      let field_jsons : Array[Json] = []
      for field in schema.fields() {
        let inner_path = "\{path}.\{field.name()}"
        check_name(field.name(), inner_path)
        let (field_ty, field_json) = write_type(
          field.dtype(),
          struct_cells(cells, field.name()),
          inner_path,
        )
        field_types.push({ name: field.name(), ty: field_ty, })
        field_jsons.push(nullable_field(field.name(), field_json))
      }
      (CRecord(field_types), record_json(path, field_jsons))
    }
    Null =>
      raise @types.DataError::Unsupported(
        "Avro: a column \"\{path}\" of dtype Null: a field names the type of its values, and a null column names none",
      )
    Duration =>
      raise @types.DataError::Unsupported(
        "Avro: a column \"\{path}\" of dtype Duration: the schema's logical types name no span",
      )
  }
}

///|
/// A primitive under a logical type.
fn logical_json(primitive : String, logical : String) -> Json {
  let entry : Map[String, Json] = Map([])
  entry["type"] = Json::string(primitive)
  entry["logicalType"] = Json::string(logical)
  Json::object(entry)
}

///|
/// A record under `path`, its name the path's last part and its namespace
/// the way there — so no two records of one schema share a name.
fn record_json(path : String, fields : Array[Json]) -> Json {
  let mut cut = -1
  for i in 0..<path.length() {
    if path[i] == '.' {
      cut = i
    }
  }
  let record : Map[String, Json] = Map([])
  record["type"] = Json::string("record")
  if cut < 0 {
    record["name"] = Json::string(path)
    record["namespace"] = Json::string("moonframe")
  } else {
    record["name"] = Json::string(path[cut + 1:].to_owned())
    record["namespace"] = Json::string("moonframe.\{path[:cut].to_owned()}")
  }
  record["fields"] = Json::array(fields)
  Json::object(record)
}

///|
/// Every element of every list cell, in order — the cells a list's item
/// type is decided from.
fn list_items(cells : Array[@types.Scalar]) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  for cell in cells {
    if cell is @types.Scalar::List(list) {
      for item in list.cells() {
        out.push(item)
      }
    }
  }
  out
}

///|
/// Every struct cell's field `name` — the cells a field's type is decided
/// from; a cell that is null gives a null.
fn struct_cells(
  cells : Array[@types.Scalar],
  name : String,
) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  for cell in cells {
    if cell is @types.Scalar::Struct(value) {
      out.push(value.get_named(name).unwrap_or(@types.Scalar::Null))
    } else {
      out.push(@types.Scalar::Null)
    }
  }
  out
}

///|
/// The narrowest decimal shape a column's cells fit: the most fraction
/// digits any cell carries, and that scale over the most integer digits
/// any cell carries. A cell needing more than 38 digits in all refuses.
fn decimal_shape_of(
  cells : Array[@types.Scalar],
  path : String,
) -> DecimalShape raise @types.DataError {
  let mut scale = 0
  let mut integer_digits = 1
  for cell in cells {
    if cell is @types.Scalar::Decimal(value) {
      if value.is_nan() || value.is_infinite() {
        raise @types.DataError::InvalidOperation(
          "column \"\{path}\" holds the decimal \{value}, which has no fixed-point spelling",
        )
      }
      let canon = value.abs().canonical()
      let digits = canon.coefficient_digits().unwrap_or([]).length()
      let exponent = canon.exponent().unwrap_or(0)
      if exponent < 0 && -exponent > scale {
        scale = -exponent
      }
      let whole = if exponent >= 0 {
        digits + exponent
      } else if digits > -exponent {
        digits + exponent
      } else {
        1
      }
      if whole > integer_digits {
        integer_digits = whole
      }
    }
  }
  let precision = integer_digits + scale
  if precision > 38 {
    raise @types.DataError::InvalidOperation(
      "column \"\{path}\" holds a decimal needing \{precision} digits, past the 38 an Avro decimal carries",
    )
  }
  { precision, scale, }
}

///|
/// The file's sync marker: sixteen bytes fixed by the schema text, so the
/// same frame writes the same file. It only has to differ from a block's
/// own bytes and from a corrupted copy of itself, which a hash of the
/// schema gives it.
fn sync_marker(schema_text : String) -> Bytes {
  let out : Array[Byte] = []
  push_be(out, fnv1a(schema_text, 0xcbf29ce484222325UL), 8)
  push_be(out, fnv1a(schema_text, 0x9e3779b97f4a7c15UL), 8)
  Bytes::from_array(out)
}

///|
/// The 64-bit FNV-1a hash of a text's code units, from a given basis.
fn fnv1a(text : String, basis : UInt64) -> UInt64 {
  let mut hash = basis
  for i in 0..<text.length() {
    hash = (hash ^ text[i].to_int().to_uint64()) * 0x100000001b3UL
  }
  hash
}
