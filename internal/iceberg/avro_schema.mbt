// The schema a container's header names, read from its JSON: the primitive
// types, the records whose fields carry ids, and the lengths, maps and
// unions they sit in. A file is resolved by field id — a field the reader
// does not know is stepped over, a field it knows is read wherever the
// schema put it — so every type a schema may carry is one this reader can
// at least step over.

///|
/// How deep a schema may nest before it is refused.
const SCHEMA_MAX_DEPTH : Int32 = 64

///|
/// A type of the schema a container's header names. A union is always a
/// null and one type. A map's keys are whole numbers: the way the column
/// metrics are keyed. A decimal rides a fixed width of bytes, or a
/// length-prefixed run of bytes when the width is 0.
priv enum AvroType {
  ANull
  ABoolean
  AInt
  ALong
  AFloat
  ADouble
  ABytes
  AString
  ARecord(Array[AvroField])
  AArray(AvroType)
  AMap(AvroType, AvroType)
  AUnion(AvroType)
  AFixed(Int32)
  ADecimal(Int32, Int64)
  AEnum
}

///|
/// One field of a record, by the field id the schema gives it.
priv struct AvroField {
  id : Int64?
  ty : AvroType
}

///|
/// The type's name with its article, for the refusals.
fn describe(ty : AvroType) -> String {
  match ty {
    ANull => "a null"
    ABoolean => "a boolean"
    AInt => "an int"
    ALong => "a long"
    AFloat => "a float"
    ADouble => "a double"
    ABytes => "bytes"
    AString => "a string"
    ARecord(_) => "a record"
    AArray(_) => "an array"
    AMap(_, _) => "a map"
    AUnion(_) => "a union"
    AFixed(_) => "a fixed"
    ADecimal(_, _) => "a decimal"
    AEnum => "an enum"
  }
}

///|
/// The primitive a name stands for, or `None` when it names no primitive.
fn primitive(name : String) -> AvroType? {
  match name {
    "null" => Some(ANull)
    "boolean" => Some(ABoolean)
    "int" => Some(AInt)
    "long" => Some(ALong)
    "float" => Some(AFloat)
    "double" => Some(ADouble)
    "bytes" => Some(ABytes)
    "string" => Some(AString)
    _ => None
  }
}

///|
/// The reader of a schema: the named types defined so far, which a later
/// entry may refer to by name.
priv struct SchemaReader {
  names : Map[String, AvroType]
}

///|
/// The type a name stands for, when it is no primitive: a named type the
/// schema defined earlier.
fn SchemaReader::by_name(
  self : SchemaReader,
  name : String,
) -> AvroType raise @types.DataError {
  match self.names.get(name) {
    Some(ty) => ty
    None =>
      raise malformed(
        "a schema that refers to the type \"\{name}\", which it never defines",
      )
  }
}

///|
/// Keep a named type under its name and, when it has a namespace, under its
/// full name too.
fn SchemaReader::remember(
  self : SchemaReader,
  members : Map[String, Json],
  ty : AvroType,
) -> Unit raise @types.DataError {
  match json_optional(members, "name") {
    Some(name_json) => {
      let name = json_string(name_json, "a type definition's name")
      self.names[name] = ty
      match json_optional(members, "namespace") {
        Some(space) => {
          let space_name = json_string(space, "a type definition's namespace")
          self.names["\{space_name}.\{name}"] = ty
        }
        None => ()
      }
    }
    None => ()
  }
}

///|
/// A decimal's precision and scale, as a `decimal` logical type must
/// declare them. Raises `ParseError` when they are missing or outside a
/// precision of 1 to 38 and a scale of 0 to that precision.
fn decimal_scale(members : Map[String, Json]) -> Int64 raise @types.DataError {
  let precision = json_int(
    json_member(members, "precision", "a decimal"),
    "a decimal's precision",
  )
  let scale = match json_optional(members, "scale") {
    Some(number) => json_int(number, "a decimal's scale")
    None => 0L
  }
  if precision < 1 || precision > 38 || scale < 0 || scale > precision {
    raise malformed("a decimal with precision \{precision} and scale \{scale}")
  }
  scale
}

///|
/// A type definition under the `logicalType` it carries: applied where the
/// format defines it for that primitive, and ignored where it does not.
fn logical(
  ty : AvroType,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  match json_optional(members, "logicalType") {
    None => ty
    Some(String("decimal")) =>
      match ty {
        ABytes => ADecimal(0, decimal_scale(members))
        AFixed(size) => ADecimal(size, decimal_scale(members))
        _ => ty
      }
    Some(String("map")) =>
      // A map carried as an array of key-and-value records, the spelling
      // for keys that are not strings.
      match ty {
        AArray(ARecord(fields)) =>
          if fields.length() == 2 {
            AMap(fields[0].ty, fields[1].ty)
          } else {
            ty
          }
        _ => ty
      }
    Some(_) => ty
  }
}

///|
/// A record: its fields in order, each already resolved.
fn SchemaReader::record(
  self : SchemaReader,
  members : Map[String, Json],
  depth : Int32,
) -> AvroType raise @types.DataError {
  let items = json_array(
    json_member(members, "fields", "a record"),
    "a record's fields",
  )
  let fields : Array[AvroField] = []
  for item in items {
    let field = json_object(item, "a field of a record")
    let id = match json_optional(field, "field-id") {
      Some(number) => Some(json_int(number, "a field's field-id"))
      None => None
    }
    fields.push({
      id,
      ty: self.read(
        json_member(field, "type", "a field of a record"),
        depth + 1,
      ),
    })
  }
  let ty = ARecord(fields)
  self.remember(members, ty)
  ty
}

///|
/// An enumeration: its symbols, of which there must be one at least.
fn SchemaReader::enumeration(
  self : SchemaReader,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  let symbols = json_array(
    json_member(members, "symbols", "an enum"),
    "an enum's symbols",
  )
  if symbols.is_empty() {
    raise malformed("an enum with no symbol")
  }
  for symbol in symbols {
    ignore(json_string(symbol, "an enum's symbol"))
  }
  self.remember(members, AEnum)
  AEnum
}

///|
/// A fixed-length value, under its logical type when it carries one.
fn SchemaReader::fixed(
  self : SchemaReader,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  let size = json_int(
    json_member(members, "size", "a fixed type"),
    "a fixed type's size",
  )
  if size < 1 || size > 16777216L {
    raise malformed("a fixed type of size \{size}")
  }
  let ty = logical(AFixed(size.to_int()), members)
  self.remember(members, ty)
  ty
}

///|
/// One type definition: a named type spelled by its keyword, a primitive
/// carrying a logical type, or a nested definition the outer attributes
/// annotate.
fn SchemaReader::definition(
  self : SchemaReader,
  members : Map[String, Json],
  depth : Int32,
) -> AvroType raise @types.DataError {
  match json_member(members, "type", "a type definition") {
    String(keyword) =>
      match keyword {
        "record" => self.record(members, depth)
        "enum" => self.enumeration(members)
        "array" =>
          logical(
            AArray(
              self.read(json_member(members, "items", "an array"), depth + 1),
            ),
            members,
          )
        "map" =>
          AMap(
            ALong,
            self.read(json_member(members, "values", "a map"), depth + 1),
          )
        "fixed" => self.fixed(members)
        _ =>
          match primitive(keyword) {
            Some(plain) => logical(plain, members)
            None => self.by_name(keyword)
          }
      }
    declared => self.read(declared, depth + 1)
  }
}

///|
/// The type one schema entry names: a name, a union, or a type definition.
/// Raises `ParseError` for a union that is not a null and one type, for a
/// schema nested past `SCHEMA_MAX_DEPTH`, and for an entry of none of these
/// shapes.
fn SchemaReader::read(
  self : SchemaReader,
  json : Json,
  depth : Int32,
) -> AvroType raise @types.DataError {
  if depth > SCHEMA_MAX_DEPTH {
    raise malformed("a schema nested deeper than \{SCHEMA_MAX_DEPTH} types")
  }
  match json {
    String(name) =>
      match primitive(name) {
        Some(ty) => ty
        None => self.by_name(name)
      }
    Array(branches) =>
      if branches.length() == 2 && branches[0] is String("null") {
        let inner = self.read(branches[1], depth + 1)
        if inner is AUnion(_) || inner is ANull {
          raise malformed("a union that is not a null and one type")
        }
        AUnion(inner)
      } else {
        raise malformed("a union that is not a null and one type")
      }
    Object(members) => self.definition(members, depth)
    _ =>
      raise malformed(
        "a schema entry that is neither a name, a union, or a type definition",
      )
  }
}

///|
/// The fields of the record a container's top-level schema names, resolved.
/// Raises `ParseError` when the header's schema is not JSON, is not a
/// record, or holds what this reader cannot resolve.
fn Container::record_fields(
  self : Container,
  what : String,
) -> Array[AvroField] raise @types.DataError {
  let schema = json_text(
    self.header.text("avro.schema", what),
    "\{what}'s Avro schema",
  )
  let reader = SchemaReader::{ names: Map([]), }
  match reader.read(schema, 0) {
    ARecord(fields) => fields
    other =>
      raise malformed(
        "\{what}: a top-level Avro schema that is \{describe(other)}, not a record",
      )
  }
}

///|
/// That each of the `ids` is the id of one of the `fields`.
fn require_ids(
  fields : Array[AvroField],
  ids : Array[Int64],
  what : String,
) -> Unit raise @types.DataError {
  for id in ids {
    let mut found = false
    for field in fields {
      if field.id == Some(id) {
        found = true
      }
    }
    if !found {
      raise malformed("\{what}: a schema that names no field with the id \{id}")
    }
  }
}

///|
/// The fields of the record a field with the id `id` is. Raises
/// `ParseError` when the schema names no such field, or when it is no
/// record.
fn record_field(
  fields : Array[AvroField],
  id : Int64,
  what : String,
) -> Array[AvroField] raise @types.DataError {
  for field in fields {
    if field.id == Some(id) {
      match inner(field.ty) {
        ARecord(nested) => return nested
        other =>
          raise malformed(
            "\{what}: a field with the id \{id} that is \{describe(other)}, not a record",
          )
      }
    }
  }
  raise malformed("\{what}: a schema that names no field with the id \{id}")
}
