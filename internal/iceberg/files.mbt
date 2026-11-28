// A manifest: the entries a snapshot keeps for its files, one record an
// entry, read by the schema its header carries and by field id. The
// header's own metadata names the partition spec and the schema the files
// were written with, which type each file's partition tuple; the entry
// named by the manifest list supplies the sequence number an added entry
// inherits.

///|
/// The shape a partition value takes: by its transform, and — for the
/// transforms that keep the source value — by the source column's type.
priv enum Expected {
  EBool
  EInt
  EFloat
  EString
  EDate
  ETimestamp
  EDecimal(Int64)
  EAny
}

///|
/// One field of the manifest's partition spec, with the shape of its value.
priv struct PlanField {
  field : SpecField
  expected : Expected
}

///|
/// The shape a partition field's value takes. For the transforms that keep
/// the source value it is the source column's type, as the manifest's
/// schema spells it; the time transforms answer a whole number or a date,
/// and a void or an unknown transform anything primitive. Raises
/// `ParseError` when the schema holds no such column, and `Unsupported`
/// when its type is one this reader does not carry.
fn plan_field(
  field : SpecField,
  columns : Array[Column],
) -> PlanField raise @types.DataError {
  let name = "the partition field \"\{field.name}\""
  let expected = match field.transform {
    Bucket(_) | Year | Month | Hour => EInt
    Day => EDate
    Void | Unknown(_) => EAny
    Identity | Truncate(_) =>
      match type_of_column(columns, field.source_id) {
        None =>
          raise malformed(
            "\{name}: the manifest's schema holds no column with the id \{field.source_id}",
          )
        Some(text) => expected_of(text, name)
      }
  }
  { field, expected, }
}

///|
/// The shape a source column's type gives its partition values. Raises
/// `Unsupported` for a type this reader does not carry, and for a decimal
/// of more than 34 digits.
fn expected_of(text : String, name : String) -> Expected raise @types.DataError {
  match text {
    "boolean" => EBool
    "int" | "long" => EInt
    "float" | "double" => EFloat
    "string" => EString
    "date" => EDate
    "timestamp" | "timestamptz" => ETimestamp
    _ =>
      if text.has_prefix("decimal") {
        let (precision, places) = decimal_shape(text, name)
        if precision > 34 {
          raise refuse(
            "\{name}: the source column's decimal(\{precision}, \{places}) holds up to \{precision} digits, where a Decimal here holds 34",
          )
        }
        EDecimal(places)
      } else {
        raise refuse(
          "\{name}: the source column's type \{text}, which this reader does not carry",
        )
      }
  }
}

///|
/// One entry of a manifest as its record spells it.
priv struct Entry {
  mut status : Int64?
  mut sequence_number : Int64?
  mut content : Int64
  mut file_path : String?
  mut file_format : String?
  mut partition : Array[IcebergPartitionValue]?
  mut record_count : Int64?
  mut equality_ids : Array[Int64]
  field_ids : Array[Int64]
  mut encrypted : Bool
}

///|
/// An entry before its record is read.
fn new_entry() -> Entry {
  {
    status: None,
    sequence_number: None,
    content: 0L,
    file_path: None,
    file_format: None,
    partition: None,
    record_count: None,
    equality_ids: [],
    field_ids: [],
    encrypted: false,
  }
}

///|
/// The values of a file's partition tuple, in the order of the manifest's
/// partition spec. Raises `ParseError` when the partition is null or of
/// another field count than the spec names, or holds a datum of another
/// shape than its transform and column give it.
fn read_partition(
  cur : Cursor,
  ty : AvroType,
  plan : Array[PlanField],
) -> Array[IcebergPartitionValue] raise @types.DataError {
  let at = cur.at
  if !present(cur, ty) {
    if plan.is_empty() {
      return []
    }
    raise malformed(
      "byte \{at} of \{cur.origin}: a file whose partition is null where the manifest's spec names \{plan.length()} fields",
    )
  }
  match inner(ty) {
    ARecord(fields) => {
      if fields.length() != plan.length() {
        raise malformed(
          "byte \{at} of \{cur.origin}: a partition of \{fields.length()} fields where the manifest's spec names \{plan.length()}",
        )
      }
      let out : Array[IcebergPartitionValue] = []
      for i in 0..<fields.length() {
        let planned = plan[i]
        let datum = read_scalar(cur, fields[i].ty, planned.field.name)
        out.push({
          name: planned.field.name,
          source_id: planned.field.source_id,
          transform: planned.field.transform,
          value: scalar_of(planned.expected, datum, planned.field.name),
        })
      }
      out
    }
    other => raise wrong_type(cur, at, other, "a partition")
  }
}

///|
/// Read the file one entry describes: its path, format, partition, record
/// count, content, the columns an equality-delete file deletes by, and the
/// field ids its column metrics name. The metrics' values, and every other
/// field of the file, are stepped over.
fn read_data_file(
  cur : Cursor,
  ty : AvroType,
  fields : Array[AvroField],
  plan : Array[PlanField],
  entry : Entry,
) -> Unit raise @types.DataError {
  if !present(cur, ty) {
    return
  }
  for field in fields {
    match field.id {
      Some(100) =>
        entry.file_path = read_string(cur, field.ty, "the path of a file")
      Some(101) =>
        entry.file_format = read_string(cur, field.ty, "the format of a file")
      Some(102) => entry.partition = Some(read_partition(cur, field.ty, plan))
      Some(103) =>
        entry.record_count = read_long(
          cur,
          field.ty,
          "the record count of a file",
        )
      Some(108) | Some(109) | Some(110) | Some(125) | Some(128) | Some(137) =>
        read_map_ids(
          cur,
          field.ty,
          "the column metrics of a file",
          entry.field_ids,
        )
      Some(131) =>
        if present(cur, field.ty) {
          entry.encrypted = true
          skip(cur, inner(field.ty))
        }
      Some(134) =>
        entry.content = read_long(cur, field.ty, "the content of a file").unwrap_or(
          0L,
        )
      Some(135) =>
        entry.equality_ids = read_ids(
          cur,
          field.ty,
          "the equality ids of a file",
        )
      _ => skip(cur, field.ty)
    }
  }
}

///|
/// Read one entry's record by the field ids the schema gives its fields.
fn read_entry(
  cur : Cursor,
  fields : Array[AvroField],
  data_fields : Array[AvroField],
  plan : Array[PlanField],
  entry : Entry,
) -> Unit raise @types.DataError {
  for field in fields {
    match field.id {
      Some(0) =>
        entry.status = read_long(
          cur,
          field.ty,
          "the status of a manifest entry",
        )
      Some(2) => read_data_file(cur, field.ty, data_fields, plan, entry)
      Some(3) =>
        entry.sequence_number = read_long(
          cur,
          field.ty,
          "the sequence number of a manifest entry",
        )
      _ => skip(cur, field.ty)
    }
  }
}

///|
/// Whether a format is spelled Parquet, whatever the case of its letters:
/// the engines write the name in either case.
fn named_parquet(format : String) -> Bool {
  let wanted = "parquet".code_units()
  if format.length() != wanted.length() {
    return false
  }
  for i in 0..<wanted.length() {
    let code = format[i].to_int()
    let folded = if code >= 65 && code <= 90 { code + 32 } else { code }
    if folded != wanted[i].to_int() {
      return false
    }
  }
  true
}

///|
/// Keep a field id once, in ascending order.
fn push_id(ids : Array[Int64], id : Int64) -> Unit {
  for existing in ids {
    if existing == id {
      return
    }
  }
  let mut at = 0
  while at < ids.length() && ids[at] < id {
    at += 1
  }
  ids.insert(at, id)
}

///|
/// The file a live entry describes — `None` for an entry that deletes its
/// file, which is no file of the snapshot. The entry's path is answered
/// relative to the table's `base` location when the reading was told it.
/// Its sequence number is the entry's own; an entry that carries none takes
/// the manifest's, which only an added entry or a manifest of sequence
/// number 0 may give. Raises `ParseError` for a status, a content or a
/// record count outside the format's values, and for a missing path, format
/// or record count; `Unsupported` for a file in a format other than
/// Parquet, one that carries key metadata, and one that lies outside the
/// table's location.
fn entry_file(
  entry : Entry,
  listed : IcebergManifest?,
  base : String?,
  plan : Array[PlanField],
  index : Int32,
) -> IcebergFile? raise @types.DataError {
  let what = "entry \{index} of the manifest"
  let status = match entry.status {
    Some(found) => found
    None => raise malformed("\{what} names no status")
  }
  if status < 0L || status > 2L {
    raise malformed("\{what}: the status \{status}, not 0, 1 or 2")
  }
  if status == 2L {
    return None
  }
  let path = match entry.file_path {
    Some(found) => found
    None => raise malformed("\{what} names no path")
  }
  let format = match entry.file_format {
    Some(found) => found
    None => raise malformed("\{what} names no format")
  }
  let record_count = match entry.record_count {
    Some(found) => found
    None => raise malformed("\{what} names no record count")
  }
  if record_count < 0L {
    raise malformed("\{what}: the record count \{record_count}")
  }
  let kind = match entry.content {
    0L => Data
    1L => PositionDeletes
    2L => EqualityDeletes
    other => raise malformed("\{what}: the content \{other}, not 0, 1 or 2")
  }
  if entry.encrypted {
    raise refuse(
      "the file \{path}: it carries key metadata, which marks it as encrypted, and this reader decrypts nothing",
    )
  }
  if !named_parquet(format) {
    raise refuse(
      "the file \{path}: the format \{format}, where this reader reads parquet files only",
    )
  }
  if kind is EqualityDeletes && entry.equality_ids.is_empty() {
    raise malformed("the equality-delete file \{path} names no column")
  }
  let sequence_number = match entry.sequence_number {
    Some(found) => {
      if found < 0L {
        raise malformed("\{what}: the sequence number \{found}")
      }
      found
    }
    None =>
      match listed {
        Some(manifest) =>
          if manifest.sequence_number == 0L || status == 1L {
            manifest.sequence_number
          } else {
            0L
          }
        None => 0L
      }
  }
  let partition = match entry.partition {
    Some(found) => found
    None =>
      if plan.is_empty() {
        []
      } else {
        raise malformed(
          "\{what}: the manifest's schema names no partition where its spec names \{plan.length()} fields",
        )
      }
  }
  Some({
    kind,
    path: table_path(path, base, "the file"),
    record_count,
    field_ids: entry.field_ids,
    partition,
    sequence_number,
    equality_ids: entry.equality_ids,
  })
}

///|
/// `content` as the list spells it, for the refusals.
fn content_name(content : ManifestContent) -> String {
  match content {
    ContentData => "data"
    ContentDeletes => "deletes"
  }
}

///|
/// The manifest's format version as its header names it — 1 for a header
/// that names none, as the first writers' headers did. Raises `ParseError`
/// for a spelling that is no whole number, and `Unsupported` for a later
/// format version.
fn header_version(header : Header) -> Int64 raise @types.DataError {
  let text = match header.metadata.get("format-version") {
    None => return 1L
    Some(found) => found
  }
  let version = match int64_of_text(text) {
    Some(found) => found
    None =>
      raise malformed(
        "the manifest's header names the format version \"\{text}\", which spells no whole number",
      )
  }
  if version < 1L || version > 3L {
    raise refuse(
      "the manifest's format version \{version}, where this reader reads 1 to 3",
    )
  }
  version
}

///|
/// The fields of the partition spec the manifest's header carries. Format
/// versions 2 and 3 let a header leave the spec to the table's own
/// partition specs, named by the header's id — and this reader is given the
/// manifest's bytes alone, so it refuses such a manifest by name. A header
/// of version 1 must carry the spec: one that names none is malformed.
fn header_spec(
  header : Header,
  version : Int64,
) -> Array[SpecField] raise @types.DataError {
  let text = match header.metadata.get("partition-spec") {
    Some(found) => found
    None => {
      if version >= 2L {
        raise refuse(
          "the manifest's header names no partition spec, which format versions 2 and 3 allow a reader to take from the table's own specs; given the manifest's bytes alone, this reader has none",
        )
      }
      raise malformed("the manifest: the header names no \"partition-spec\"")
    }
  }
  spec_fields(json_text(text, "the manifest's partition spec"))
}

///|
/// That the manifest's header agrees with the entry the list keeps for it:
/// the content and the partition spec id. Raises `ParseError` for a content
/// outside its two values, a spec id that spells no whole number, and a
/// disagreement with the list.
fn check_header(
  header : Header,
  listed : IcebergManifest?,
) -> Unit raise @types.DataError {
  let content = match header.metadata.get("content") {
    None => ContentData
    Some("data") => ContentData
    Some("deletes") => ContentDeletes
    Some(other) =>
      raise malformed(
        "the manifest's header names the content \"\{other}\", not data or deletes",
      )
  }
  let spec_id = match header.metadata.get("partition-spec-id") {
    Some(text) =>
      match int64_of_text(text) {
        Some(found) => Some(found)
        None =>
          raise malformed(
            "the manifest's header names the partition spec id \"\{text}\", which spells no whole number",
          )
      }
    None => None
  }
  match listed {
    None => ()
    Some(manifest) => {
      match (content, manifest.content) {
        (ContentData, ContentData) | (ContentDeletes, ContentDeletes) => ()
        (header_content, listed_content) =>
          raise malformed(
            "the manifest \{manifest.path}: its header names the content \{content_name(header_content)}, the list \{content_name(listed_content)}",
          )
      }
      match spec_id {
        Some(found) =>
          if found != manifest.partition_spec_id {
            raise malformed(
              "the manifest \{manifest.path}: its header names the partition spec \{found}, the list \{manifest.partition_spec_id}",
            )
          }
        None => ()
      }
    }
  }
}

///|
/// The files one manifest names — `bytes` are the manifest's — each with
/// its kind (a data file, a position-delete file, an equality-delete
/// file), its path, its record count, the field ids the entry's column
/// metrics name, its partition values, its data sequence number and the
/// field ids an equality-delete file deletes by. Only entries that do not
/// delete their file are answered, in the manifest's order.
///
/// `manifest`, when given, is the manifest list's entry for this manifest:
/// the file's length is then checked against it, the header's content and
/// partition spec against the list's, and an added entry takes the
/// manifest's sequence number. It also carries the table's location, which
/// makes every path relative to the table and refuses a file outside it.
/// Without it paths are answered as the manifest spells them.
///
/// The manifest is read by the schema its header carries, and its partition
/// values typed by the partition spec and the schema its header names.
/// Format versions 1 to 3 are read. Raises `ParseError` for bytes that are
/// not an Avro container, a header naming no schema or — at version 1 — no
/// partition spec, a codec this reader does not inflate or a schema this
/// reader cannot resolve, a block past what the bytes hold, a length other
/// than the list's, a header disagreeing with the list, a status, a content
/// or a record count outside the format's values, a partition of another
/// shape than its spec, and an equality-delete file that names no column;
/// `Unsupported` for a later format version, a header of version 2 or 3
/// that names no partition spec, a file in a format other than Parquet, a
/// file or a manifest that carries key metadata, a partition value whose
/// column is of a type this reader does not carry, and a file outside the
/// table's location.
pub fn iceberg_files(
  bytes : Bytes,
  manifest? : IcebergManifest,
) -> Array[IcebergFile] raise @types.DataError {
  let listed : IcebergManifest? = manifest
  let base = match listed {
    Some(manifest) => {
      let size = bytes.length().to_int64()
      if manifest.length != size {
        raise malformed(
          "the manifest \{manifest.path}: the list names \{manifest.length} bytes, the file holds \{size}",
        )
      }
      manifest.location
    }
    None => None
  }
  let container = open_container(bytes, "the manifest")
  let version = header_version(container.header)
  check_header(container.header, listed)
  let fields = container.record_fields("the manifest")
  // The data file's presence, and its being a record, are `record_field`'s
  // to check.
  require_ids(fields, [0L], "the manifest")
  let data_fields = record_field(fields, 2L, "the manifest")
  require_ids(data_fields, [100L, 101L, 103L], "the manifest's data file")
  let columns = schema_columns(
      json_text(
        container.header.text("schema", "the manifest"),
        "the manifest's schema",
      ),
    ).0
  let plan : Array[PlanField] = []
  for field in header_spec(container.header, version) {
    plan.push(plan_field(field, columns))
  }
  let out : Array[IcebergFile] = []
  let mut index = 0
  while true {
    match container.blocks.next() {
      None => break
      Some((cur, count)) => {
        for _ in 0L..<count {
          let entry = new_entry()
          read_entry(cur, fields, data_fields, plan, entry)
          match entry_file(entry, listed, base, plan, index) {
            Some(file) => out.push(file)
            None => ()
          }
          index += 1
        }
        if cur.remaining() != 0 {
          raise malformed(
            "\{cur.origin}: \{cur.remaining()} bytes past the last record",
          )
        }
      }
    }
  }
  out
}
