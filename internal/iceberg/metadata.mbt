// The metadata JSON: the format version, the schemas with their field ids,
// the partition specs, the snapshots and their references, and the
// properties. Fields the plan does not need are read past; a field whose
// meaning would change what the files hold and that this reader does not
// honour refuses the table by name.

///|
/// The schema `current-schema-id` names among the metadata's `schemas`. A
/// metadata that keeps none there holds its one schema under the older
/// `schema` spelling. Raises `ParseError` when the id names none of them.
fn current_schema(root : Map[String, Json]) -> Json raise @types.DataError {
  let current = match json_optional(root, "current-schema-id") {
    Some(id) => json_int(id, "current-schema-id")
    None => 0L
  }
  let schemas = match json_optional(root, "schemas") {
    Some(list) => json_array(list, "schemas")
    None => []
  }
  if !schemas.is_empty() {
    for schema in schemas {
      let members = json_object(schema, "a schema")
      let id = match json_optional(members, "schema-id") {
        Some(number) => json_int(number, "a schema's schema-id")
        None => 0L
      }
      if id == current {
        return schema
      }
    }
    raise malformed(
      "current-schema-id \{current} names none of the table's \{schemas.length()} schemas",
    )
  }
  match json_optional(root, "schema") {
    Some(schema) => schema
    None => raise malformed("the metadata names no schema")
  }
}

///|
/// The snapshots the metadata lists, each with its members.
fn snapshot_entries(
  root : Map[String, Json],
) -> Array[(Int64, Map[String, Json])] raise @types.DataError {
  let snapshots = match json_optional(root, "snapshots") {
    Some(list) => json_array(list, "snapshots")
    None => []
  }
  let out : Array[(Int64, Map[String, Json])] = []
  for snapshot in snapshots {
    let members = json_object(snapshot, "a snapshot")
    let id = json_int(
      json_member(members, "snapshot-id", "a snapshot"),
      "a snapshot's snapshot-id",
    )
    out.push((id, members))
  }
  out
}

///|
/// The snapshot the plan answers: the one the `main` reference names, or
/// the one `current-snapshot-id` names when there is no such reference;
/// `None` for a table with no snapshot. `-1` is read as no snapshot. The
/// two must name the same snapshot: raises `ParseError` when they do not,
/// and when the snapshot named is not among the metadata's snapshots.
fn current_snapshot(
  root : Map[String, Json],
  entries : Array[(Int64, Map[String, Json])],
) -> (Int64, Map[String, Json])? raise @types.DataError {
  let main = match json_optional(root, "refs") {
    Some(refs) =>
      match json_optional(json_object(refs, "refs"), "main") {
        Some(reference) =>
          Some(
            json_int(
              json_member(
                json_object(reference, "the main reference"),
                "snapshot-id",
                "the main reference",
              ),
              "the snapshot-id of the main reference",
            ),
          )
        None => None
      }
    None => None
  }
  let current = match json_optional(root, "current-snapshot-id") {
    Some(id) => {
      let number = json_int(id, "current-snapshot-id")
      if number == -1L {
        None
      } else {
        Some(number)
      }
    }
    None => None
  }
  let chosen = match (main, current) {
    (Some(from_ref), Some(from_current)) =>
      if from_ref != from_current {
        raise malformed(
          "refs names the snapshot \{from_ref} for main, current-snapshot-id the snapshot \{from_current}",
        )
      } else {
        Some(from_ref)
      }
    (Some(from_ref), None) =>
      raise malformed(
        "refs names the snapshot \{from_ref} for main, current-snapshot-id none",
      )
    (None, from_current) => from_current
  }
  match chosen {
    None => None
    Some(id) => {
      for entry in entries {
        if entry.0 == id {
          return Some(entry)
        }
      }
      raise malformed(
        "the snapshot \{id} is named as current, but the metadata's snapshots do not hold it",
      )
    }
  }
}

///|
/// The table properties the plan depends on: a name mapping for data files
/// that carry no field ids would say which column of such a file is which,
/// and this reader does not apply one. Raises `Unsupported` when the
/// metadata holds that mapping, or encryption keys.
fn check_properties(root : Map[String, Json]) -> Unit raise @types.DataError {
  match json_optional(root, "properties") {
    Some(properties) =>
      match
        json_object(properties, "properties").get("schema.name-mapping.default") {
        Some(String(mapping)) =>
          if !mapping.is_empty() {
            raise refuse(
              "the property schema.name-mapping.default maps field ids to the columns of data files that carry none, and this reader does not apply it",
            )
          }
        _ => ()
      }
    None => ()
  }
  match json_optional(root, "encryption-keys") {
    Some(keys) =>
      if !json_array(keys, "encryption-keys").is_empty() {
        raise refuse(
          "the table holds encryption keys, and this reader decrypts nothing",
        )
      }
    None => ()
  }
}

///|
/// The table as its metadata file spells it — `bytes` are that file's.
/// Answers the current schema's fields under their names and dtypes with
/// their field ids, the fields of the default partition spec, the table's
/// location, and where the current snapshot's manifest list lies (none, for
/// a table with no snapshot).
///
/// Format versions 1, 2 and 3 are read. Raises `ParseError` when the bytes
/// are not one JSON document, when a field the plan needs is missing or of
/// the wrong shape, when the current schema id, the default spec id or the
/// current snapshot names nothing the metadata holds, when `refs` and
/// `current-snapshot-id` name different snapshots, and when the manifest
/// list is not a path under the table's location; `Unsupported` for a
/// later format version, a column whose type this reader does not carry, a
/// decimal of more than 34 digits, a column with an initial default other
/// than null, a name mapping for files without field ids, and a snapshot or
/// a table that names encryption keys.
pub fn iceberg_metadata(bytes : Bytes) -> IcebergTable raise @types.DataError {
  let root = json_object(json_document(bytes, "the metadata"), "the metadata")
  let version = json_int(
    json_member(root, "format-version", "the metadata"),
    "format-version",
  )
  if version < 1 || version > 3 {
    raise refuse("format version \{version}, where this reader reads 1 to 3")
  }
  let location = json_string(
    json_member(root, "location", "the metadata"),
    "location",
  )
  if location.is_empty() {
    raise malformed("location is empty")
  }
  let schema = current_schema(root)
  let (_, field_ids) = schema_columns(schema)
  let fields = current_fields(schema)
  check_partition_spec(root)
  check_properties(root)
  let entries = snapshot_entries(root)
  let manifest_list = match current_snapshot(root, entries) {
    None => None
    Some((id, members)) => {
      let what = "the snapshot \{id}"
      let list = json_string(
        json_member(members, "manifest-list", what),
        "\{what}'s manifest-list",
      )
      let sequence = match json_optional(members, "sequence-number") {
        Some(number) => json_int(number, "\{what}'s sequence-number")
        None => 0L
      }
      if sequence < 0L {
        raise malformed("\{what} carries the sequence number \{sequence}")
      }
      match json_optional(members, "key-id") {
        Some(_) =>
          raise refuse(
            "\{what} names an encryption key, and this reader decrypts nothing",
          )
        None => ()
      }
      if list.is_empty() {
        raise malformed("\{what}'s manifest-list is an empty path")
      }
      Some(relative_to(list, location, "the manifest list of \{what}"))
    }
  }
  IcebergTable::{ location, schema: fields, field_ids, manifest_list, }
}
