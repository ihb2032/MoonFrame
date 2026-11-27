// The Avro schema: what a record's fields are typed as, read from the
// JSON text a file's `avro.schema` names and written back as the same. The
// model keeps what the mapping to columns needs — the primitive kinds, the
// logical types date, time and decimal ride, the named types and the
// nullable union a column is carried in — and drops what it does not:
// documentation, aliases and field defaults.
//
// Every refusal the codec raises takes one of two forms: a file that does
// not hold together is malformed, and a shape the format allows but the
// mapping to columns does not carry cannot be carried.

///|
/// Every refusal of bytes that are not an Avro container, or not one that
/// holds together.
fn malformed(what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("malformed Avro: \{what}"),
  )
}

///|
/// A shape the format allows and the mapping to columns does not carry.
fn cannot_carry(what : String) -> @types.DataError {
  @types.DataError::Unsupported("Avro: \{what}")
}

///|
/// One field's type, its named references resolved.
priv enum AvroType {
  TNull
  TBoolean
  TInt(IntLogical)
  TLong(LongLogical)
  TFloat
  TDouble
  TBytes(DecimalShape?)
  TString
  TRecord(Array[AvroField])
  TEnum(Array[String])
  TArray(AvroType)
  TMap(AvroType)
  TUnion(Array[AvroType])
  TFixed(Int32, FixedLogical)
}

///|
/// What an `int` field's count is: plain, days since the epoch, or
/// milliseconds past midnight.
priv enum IntLogical {
  Plain
  Date
  TimeMillis
}

///|
/// What a `long` field's count is: plain, microseconds past midnight,
/// milliseconds / microseconds since the epoch (a local timestamp reads
/// as the same count, the library's timestamp carrying no zone), or
/// nanoseconds since the epoch — a precision no timestamp here holds.
priv enum LongLogical {
  Plain
  TimeMicros
  TimestampMillis
  TimestampMicros
  Nanos
}

///|
/// What a fixed-length value holds: plain bytes, a decimal, or a
/// duration of months, days and milliseconds.
priv enum FixedLogical {
  Plain
  Decimal(DecimalShape)
  Duration
}

///|
/// A decimal's declared shape: its precision, and how many of its digits
/// are fraction digits.
priv struct DecimalShape {
  precision : Int32
  scale : Int32
}

///|
/// One record field: its name and its type.
priv struct AvroField {
  name : String
  ty : AvroType
}

///|
/// How deep a schema may nest before it is refused.
const SCHEMA_MAX_DEPTH : Int32 = 64

///|
/// The parser's place while a schema is read: the named types defined so
/// far, and the ones whose own definition is still being read — a
/// reference to one of those is a type that contains itself.
priv struct SchemaReader {
  names : Map[String, AvroType]
  defining : Array[String]
}

///|
/// The type one schema entry names: a name, a union, or a type
/// definition.
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
    Array(branches) => {
      let types : Array[AvroType] = []
      for branch in branches {
        types.push(self.read(branch, depth + 1))
      }
      TUnion(types)
    }
    Object(members) => self.definition(members, depth)
    _ =>
      raise malformed(
        "a schema entry that is neither a name, a union, or a type definition",
      )
  }
}

///|
/// The type a definition's `key` names — the items of an array, the
/// values of a map — which the definition has to carry.
fn SchemaReader::nested(
  self : SchemaReader,
  members : Map[String, Json],
  key : String,
  of : String,
) -> AvroType raise @types.DataError {
  match members.get(key) {
    Some(t) => self.read(t, 1)
    None => raise malformed("\{of} with no \"\{key}\"")
  }
}

///|
/// The type a name stands for: a type still being defined contains
/// itself, and one never defined is a dangling reference.
fn SchemaReader::by_name(
  self : SchemaReader,
  name : String,
) -> AvroType raise @types.DataError {
  let mut open = false
  for defined in self.defining {
    if defined == name || defined.has_suffix(".\{name}") {
      open = true
    }
  }
  if open {
    raise cannot_carry("a schema whose type \"\{name}\" contains itself")
  }
  match self.names.get(name) {
    Some(ty) => ty
    None =>
      raise malformed(
        "a schema refers to the type \"\{name}\", which it never defines",
      )
  }
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
  let declared = match members.get("type") {
    Some(t) => t
    None => raise malformed("a type definition with no \"type\"")
  }
  match declared {
    String(keyword) =>
      match keyword {
        "record" | "error" => self.record(members, depth)
        "enum" => self.enumeration(members)
        "array" => TArray(self.nested(members, "items", "an array"))
        "map" => TMap(self.nested(members, "values", "a map"))
        "fixed" => self.fixed(members)
        _ =>
          match primitive(keyword) {
            Some(ty) => annotated(ty, members)
            None => self.by_name(keyword)
          }
      }
    _ => annotated(self.read(declared, depth + 1), members)
  }
}

///|
/// The primitive a name stands for, or `None` when it names no primitive.
fn primitive(name : String) -> AvroType? {
  match name {
    "null" => Some(TNull)
    "boolean" => Some(TBoolean)
    "int" => Some(TInt(Plain))
    "long" => Some(TLong(Plain))
    "float" => Some(TFloat)
    "double" => Some(TDouble)
    "bytes" => Some(TBytes(None))
    "string" => Some(TString)
    _ => None
  }
}

///|
/// A type under the `logicalType` a definition carries: applied where the
/// format defines it for that primitive, refused where the mapping cannot
/// hold what it names, and ignored where the format does not define it.
fn annotated(
  ty : AvroType,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  match members.get("logicalType") {
    None => ty
    Some(String(logical)) => logical_type(ty, logical, members)
    Some(_) => raise malformed("a logicalType that is not a name")
  }
}

///|
/// `ty` under the logical type `logical`, as `annotated` applies it.
fn logical_type(
  ty : AvroType,
  logical : String,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  match ty {
    TInt(_) =>
      match logical {
        "date" => TInt(Date)
        "time-millis" => TInt(TimeMillis)
        _ => ty
      }
    TLong(_) =>
      match logical {
        "time-micros" => TLong(TimeMicros)
        "timestamp-millis" | "local-timestamp-millis" => TLong(TimestampMillis)
        "timestamp-micros" | "local-timestamp-micros" => TLong(TimestampMicros)
        "timestamp-nanos" | "local-timestamp-nanos" | "time-nanos" =>
          TLong(Nanos)
        _ => ty
      }
    TBytes(_) =>
      if logical == "decimal" {
        TBytes(Some(decimal_shape(members)))
      } else {
        ty
      }
    TFixed(size, _) =>
      match logical {
        "decimal" => TFixed(size, Decimal(decimal_shape(members)))
        "duration" => TFixed(size, Duration)
        _ => ty
      }
    _ => ty
  }
}

///|
/// A decimal's precision and scale, as a `decimal` logical type must
/// declare them: a precision from 1 to 38, and a scale no larger than it.
fn decimal_shape(
  members : Map[String, Json],
) -> DecimalShape raise @types.DataError {
  let precision = match members.get("precision") {
    Some(number) => whole_number(number, "a decimal's precision")
    None => raise malformed("a decimal with no precision")
  }
  let scale = match members.get("scale") {
    Some(number) => whole_number(number, "a decimal's scale")
    None => 0
  }
  if precision < 1 || precision > 38 {
    raise malformed("a decimal with precision \{precision}, outside 1 to 38")
  }
  if scale < 0 || scale > precision {
    raise malformed("a decimal with scale \{scale}, outside 0 to its precision")
  }
  { precision, scale, }
}

///|
/// The 32-bit whole number a schema attribute names.
fn whole_number(json : Json, what : String) -> Int32 raise @types.DataError {
  match json {
    Number(n, ..) =>
      if n == n.trunc() && n >= -2147483648.0 && n <= 2147483647.0 {
        n.to_int()
      } else {
        raise malformed("\{what} that is not a 32-bit whole number")
      }
    _ => raise malformed("\{what} that is not a number")
  }
}

///|
/// The string a definition's `key` names, as a name has to be given.
fn named_text(
  members : Map[String, Json],
  key : String,
) -> String raise @types.DataError {
  match members.get(key) {
    Some(String(text)) => text
    Some(_) =>
      raise malformed("a type definition whose \"\{key}\" is not a string")
    None => raise malformed("a type definition with no \"\{key}\"")
  }
}

///|
/// A type's full name: its own name, under its namespace when it has one
/// and the name carries none.
fn full_name(members : Map[String, Json]) -> String raise @types.DataError {
  let name = named_text(members, "name")
  if name.contains(".") {
    name
  } else {
    match members.get("namespace") {
      Some(String(ns)) => "\{ns}.\{name}"
      Some(_) =>
        raise malformed("a type definition whose namespace is not a string")
      None => name
    }
  }
}

///|
/// A record: its fields in order, each already resolved, and no two of
/// one name. The record's own name is being defined while its fields are
/// read, so a field of that name is the recursion `by_name` refuses.
fn SchemaReader::record(
  self : SchemaReader,
  members : Map[String, Json],
  depth : Int32,
) -> AvroType raise @types.DataError {
  let name = full_name(members)
  let fields_json = match members.get("fields") {
    Some(Array(items)) => items
    Some(_) =>
      raise malformed("the record \"\{name}\" whose fields are not an array")
    None => raise malformed("the record \"\{name}\" with no fields")
  }
  self.defining.push(name)
  let fields : Array[AvroField] = []
  for item in fields_json {
    match item {
      Object(field) => {
        let field_name = named_text(field, "name")
        let field_type = match field.get("type") {
          Some(t) => self.read(t, depth + 1)
          None =>
            raise malformed(
              "the field \"\{field_name}\" of \"\{name}\" with no type",
            )
        }
        for earlier in fields {
          if earlier.name == field_name {
            raise malformed(
              "the record \"\{name}\" with two fields named \"\{field_name}\"",
            )
          }
        }
        fields.push({ name: field_name, ty: field_type, })
      }
      _ => raise malformed("a field of \"\{name}\" that is not an object")
    }
  }
  ignore(self.defining.pop())
  self.remember(name, named_text(members, "name"), TRecord(fields))
  TRecord(fields)
}

///|
/// An enumeration: the symbols a value's index names.
fn SchemaReader::enumeration(
  self : SchemaReader,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  let name = full_name(members)
  let symbols_json = match members.get("symbols") {
    Some(Array(items)) => items
    Some(_) =>
      raise malformed("the enum \"\{name}\" whose symbols are not an array")
    None => raise malformed("the enum \"\{name}\" with no symbols")
  }
  let symbols : Array[String] = []
  for item in symbols_json {
    match item {
      String(symbol) =>
        if symbols.contains(symbol) {
          raise malformed(
            "the enum \"\{name}\" with the symbol \"\{symbol}\" twice",
          )
        } else {
          symbols.push(symbol)
        }
      _ => raise malformed("a symbol of \"\{name}\" that is not a string")
    }
  }
  if symbols.is_empty() {
    raise malformed("the enum \"\{name}\" with no symbol")
  }
  self.remember(name, named_text(members, "name"), TEnum(symbols))
  TEnum(symbols)
}

///|
/// A fixed-length value of `size` bytes.
fn SchemaReader::fixed(
  self : SchemaReader,
  members : Map[String, Json],
) -> AvroType raise @types.DataError {
  let name = full_name(members)
  let size = match members.get("size") {
    Some(number) => whole_number(number, "the size of a fixed type")
    None => raise malformed("the fixed type \"\{name}\" with no size")
  }
  if size < 1 {
    raise malformed("the fixed type \"\{name}\" with size \{size}")
  }
  let ty = annotated(TFixed(size, Plain), members)
  self.remember(name, named_text(members, "name"), ty)
  ty
}

///|
/// Keep a named type under its full name and, when that is still free,
/// under its own name — the two spellings a reference may use.
fn SchemaReader::remember(
  self : SchemaReader,
  full : String,
  name : String,
  ty : AvroType,
) -> Unit {
  self.names[full] = ty
  if !self.names.contains(name) {
    self.names[name] = ty
  }
}
