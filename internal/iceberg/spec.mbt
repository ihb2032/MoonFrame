// A partition spec: the fields that turn table columns into partition
// values — each with its source column, its transform and its name. The
// metadata keeps every spec the table was written with and names its
// default; a manifest's header carries the one spec its files were written
// with, as the fields alone.

///|
/// One partition field as the metadata or a manifest's header spells it.
priv struct SpecField {
  source_id : Int64
  name : String
  transform : IcebergTransform
}

///|
/// The transform a metadata spelling names. `bucket[N]` and `truncate[W]`
/// carry their parameter, which must be a positive whole number; a name
/// this reader does not know is answered as `Unknown`, by its spelling.
/// Raises `ParseError` for a `bucket` or `truncate` whose parameter is not
/// a positive whole number.
fn parse_transform(text : String) -> IcebergTransform raise @types.DataError {
  let bucket = text.has_prefix("bucket[")
  let truncate = text.has_prefix("truncate[")
  if !(bucket || truncate) {
    let plain = match text {
      "identity" => Identity
      "year" => Year
      "month" => Month
      "day" => Day
      "hour" => Hour
      "void" => Void
      _ => Unknown(text)
    }
    return plain
  }
  // Past `bucket[` or `truncate[`.
  let (width, end) = unsigned_at(text, if bucket { 7 } else { 9 })
  let closed = end == text.length() - 1 && unit_at(text, end) == 93
  match (width, closed) {
    (Some(n), true) if n > 0 => if bucket { Bucket(n) } else { Truncate(n) }
    _ =>
      raise malformed(
        "\{text}, which spells no positive whole number in brackets",
      )
  }
}

///|
/// The partition fields of one spec — `fields` is the spec's fields as the
/// metadata spells them — in the spec's order. Raises `ParseError` for a
/// field that names no source column, and `Unsupported` for one that draws
/// on more than one source column, which this reader does not carry.
fn spec_fields(fields : Json) -> Array[SpecField] raise @types.DataError {
  let items = json_array(fields, "a partition spec's fields")
  let out : Array[SpecField] = []
  for field in items {
    let members = json_object(field, "a partition field")
    let source = match json_optional(members, "source-id") {
      Some(id) => json_int(id, "a partition field's source-id")
      None =>
        match json_optional(members, "source-ids") {
          Some(ids) =>
            match json_array(ids, "a partition field's source-ids") {
              [id] => json_int(id, "a partition field's source-ids")
              [_, ..] =>
                raise refuse(
                  "a partition field drawing on several source columns, which this reader does not carry",
                )
              [] => raise malformed("a partition field names no source column")
            }
          None => raise malformed("a partition field names no source column")
        }
    }
    out.push({
      source_id: source,
      name: json_string(
        json_member(members, "name", "a partition field"),
        "a partition field's name",
      ),
      transform: parse_transform(
        json_string(
          json_member(members, "transform", "a partition field"),
          "a partition field's transform",
        ),
      ),
    })
  }
  out
}

///|
/// The table's default partition spec, checked: its fields read under the
/// rules a partition field is read by, and the default spec found among
/// the table's. A metadata that keeps no specs under `partition-specs`
/// holds its one spec's fields under the older `partition-spec` spelling,
/// as spec 0. Raises `ParseError` when `default-spec-id` names none of the
/// specs the metadata holds. The fields are not kept: a caller that fills
/// a file's missing columns reads each file's own partition tuple.
fn check_partition_spec(
  root : Map[String, Json],
) -> Unit raise @types.DataError {
  let default = match json_optional(root, "default-spec-id") {
    Some(id) => json_int(id, "default-spec-id")
    None => 0L
  }
  let specs = match json_optional(root, "partition-specs") {
    Some(list) => json_array(list, "partition-specs")
    None => []
  }
  let fields : Array[SpecField] = []
  let spec_ids : Array[Int64] = []
  if specs.is_empty() {
    match json_optional(root, "partition-spec") {
      Some(list) => {
        spec_ids.push(0L)
        fields.append(spec_fields(list))
      }
      None => ()
    }
  } else {
    for spec in specs {
      let members = json_object(spec, "a partition spec")
      let spec_id = match json_optional(members, "spec-id") {
        Some(id) => json_int(id, "a partition spec's spec-id")
        None => 0L
      }
      spec_ids.push(spec_id)
      if spec_id == default {
        fields.append(
          spec_fields(json_member(members, "fields", "a partition spec")),
        )
      }
    }
  }
  if !(spec_ids.is_empty() || spec_ids.contains(default)) {
    raise malformed(
      "default-spec-id \{default} names none of the table's \{spec_ids.length()} partition specs",
    )
  }
  ignore(fields)
}
