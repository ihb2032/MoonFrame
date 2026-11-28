// The manifest list of a snapshot: one Avro record a manifest — where it
// lies, how long it is, the partition spec its files were written with,
// whether it holds data files or delete files, and the sequence number its
// added entries inherit. The list is read by the schema its own header
// carries, by field id: a v1 list names neither the content nor the
// sequence numbers, which then take the format's defaults.

///|
/// One entry of a manifest list as its record spells it.
priv struct Listed {
  mut path : String?
  mut length : Int64?
  mut spec_id : Int64?
  mut added_snapshot_id : Int64?
  mut sequence_number : Int64
  mut content : Int64
  mut encrypted : Bool
}

///|
/// An entry before its record is read.
fn new_listed() -> Listed {
  {
    path: None,
    length: None,
    spec_id: None,
    added_snapshot_id: None,
    sequence_number: 0L,
    content: 0L,
    encrypted: false,
  }
}

///|
/// Read one entry's record by the field ids the schema gives its fields.
fn read_listed(
  cur : Cursor,
  fields : Array[AvroField],
  listed : Listed,
) -> Unit raise @types.DataError {
  for field in fields {
    match field.id {
      Some(500) =>
        listed.path = read_string(cur, field.ty, "the path of a manifest")
      Some(501) =>
        listed.length = read_long(cur, field.ty, "the length of a manifest")
      Some(502) =>
        listed.spec_id = read_long(
          cur,
          field.ty,
          "the partition spec id of a manifest",
        )
      Some(503) =>
        listed.added_snapshot_id = read_long(
          cur,
          field.ty,
          "the added snapshot id of a manifest",
        )
      Some(515) =>
        listed.sequence_number = read_long(
          cur,
          field.ty,
          "the sequence number of a manifest",
        ).unwrap_or(0L)
      Some(517) =>
        listed.content = read_long(cur, field.ty, "the content of a manifest").unwrap_or(
          0L,
        )
      Some(519) => if present(cur, field.ty) { listed.encrypted = true }
      _ => skip(cur, field.ty)
    }
  }
}

///|
/// The manifest an entry of the list names, its path relative to the
/// table's `base` location when the reading was told it. Raises
/// `ParseError` for a missing path, length, spec id or snapshot id, for a
/// negative length or sequence number, and for a content outside 0 and 1;
/// `Unsupported` when the manifest carries key metadata.
fn listed_manifest(
  listed : Listed,
  base : String?,
  entry : Int32,
) -> IcebergManifest raise @types.DataError {
  let what = "manifest entry \{entry} of the list"
  let path = match listed.path {
    Some(found) => found
    None => raise malformed("\{what} names no path")
  }
  let length = match listed.length {
    Some(found) => found
    None => raise malformed("\{what} names no length")
  }
  if length < 0L {
    raise malformed("\{what}: the manifest length \{length}")
  }
  let spec_id = match listed.spec_id {
    Some(found) => found
    None => raise malformed("\{what} names no partition spec id")
  }
  match listed.added_snapshot_id {
    Some(_) => ()
    None => raise malformed("\{what} names no added snapshot id")
  }
  if listed.sequence_number < 0L {
    raise malformed("\{what}: the sequence number \{listed.sequence_number}")
  }
  let content = match listed.content {
    0L => ContentData
    1L => ContentDeletes
    other =>
      raise malformed(
        "\{what}: the content \{other}, not 0 for data or 1 for deletes",
      )
  }
  let relative = table_path(path, base, "the manifest")
  if listed.encrypted {
    raise refuse(
      "the manifest \{relative}: it carries key metadata, which marks it as encrypted, and this reader decrypts nothing",
    )
  }
  {
    path: relative,
    length,
    partition_spec_id: spec_id,
    content,
    sequence_number: listed.sequence_number,
    location: base,
  }
}

///|
/// The manifests the manifest list names — `bytes` are the list's — in the
/// list's order: each manifest's path, and what the reading of that
/// manifest needs from the list's entry, which is all the entry tells that
/// the manifest itself does not: the sequence number its added entries
/// inherit, the partition spec and the content its header must agree with,
/// its length, and the table's location.
///
/// `location`, when given, is the table's base location as the metadata
/// spells it: each manifest's path is then answered relative to it, and a
/// manifest that lies outside it refuses the list by name. Without it the
/// paths are answered as the list spells them.
///
/// The list is read by the schema its header carries. Format versions 1 to
/// 3 are read. Raises `ParseError` for bytes that are not an Avro
/// container, a header naming a codec this reader does not inflate or a
/// schema this reader cannot resolve, a block past what the bytes hold, a
/// record of the wrong shape, and a content outside its two values;
/// `Unsupported` for a manifest that carries key metadata or lies outside
/// the table's location.
pub fn iceberg_manifests(
  bytes : Bytes,
  location~ : String = "",
) -> Array[IcebergManifest] raise @types.DataError {
  let base : String? = if location.is_empty() { None } else { Some(location) }
  let container = open_container(bytes, "the manifest list")
  let fields = container.record_fields("the manifest list")
  require_ids(fields, [500L, 501L, 502L, 503L], "the manifest list")
  let out : Array[IcebergManifest] = []
  let mut entry = 0
  while true {
    match container.blocks.next() {
      None => break
      Some((cur, count)) => {
        for _ in 0L..<count {
          let listed = new_listed()
          read_listed(cur, fields, listed)
          out.push(listed_manifest(listed, base, entry))
          entry += 1
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
