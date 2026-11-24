// The Arrow schema as its message spells it, and what each of its fields
// maps to: the dtype a column reads as, or the refusal when the mapping
// does not carry the type, and the field's layout on the wire — how many
// buffers its node consumes, and which children follow it — so a reader
// can decode a field, or step over one it was not asked for. A type-level
// refusal is decided field by field here and raised only when that
// column is decoded: a file may carry a column this reader refuses beside
// columns it reads, and a projection that leaves the first out reads the
// rest.

///|
/// The type union's members, by the order the schema declares them.
const TYPE_NULL : Int32 = 1

///|
const TYPE_INT : Int32 = 2

///|
const TYPE_FLOAT : Int32 = 3

///|
const TYPE_BINARY : Int32 = 4

///|
const TYPE_UTF8 : Int32 = 5

///|
const TYPE_BOOL : Int32 = 6

///|
const TYPE_DECIMAL : Int32 = 7

///|
const TYPE_DATE : Int32 = 8

///|
const TYPE_TIME : Int32 = 9

///|
const TYPE_TIMESTAMP : Int32 = 10

///|
const TYPE_INTERVAL : Int32 = 11

///|
const TYPE_LIST : Int32 = 12

///|
const TYPE_STRUCT : Int32 = 13

///|
const TYPE_UNION : Int32 = 14

///|
const TYPE_FIXED_SIZE_BINARY : Int32 = 15

///|
const TYPE_FIXED_SIZE_LIST : Int32 = 16

///|
const TYPE_MAP : Int32 = 17

///|
const TYPE_DURATION : Int32 = 18

///|
const TYPE_LARGE_BINARY : Int32 = 19

///|
const TYPE_LARGE_UTF8 : Int32 = 20

///|
const TYPE_LARGE_LIST : Int32 = 21

///|
const TYPE_RUN_END : Int32 = 22

///|
const TYPE_BINARY_VIEW : Int32 = 23

///|
const TYPE_UTF8_VIEW : Int32 = 24

///|
const TYPE_LIST_VIEW : Int32 = 25

///|
const TYPE_LARGE_LIST_VIEW : Int32 = 26

///|
/// The time units a date, a time, a timestamp, or a duration is counted
/// in, by the order the schema declares them.
const UNIT_SECOND : Int32 = 0

///|
const UNIT_MILLISECOND : Int32 = 1

///|
const UNIT_MICROSECOND : Int32 = 2

///|
const UNIT_NANOSECOND : Int32 = 3

///|
/// How far a decimal's scale may sit from zero, either way: a decimal
/// column's precision is at most 38 digits, and its scale no wider.
const DECIMAL_SCALE_MAX : Int32 = 38

///|
/// How deep a schema may nest — a field, its children, and theirs down to
/// a leaf — the depth a FlatBuffers verifier allows. Deeper, a schema's
/// children can point back into themselves, and no reader can walk it.
const SCHEMA_DEPTH : Int32 = 64

///|
/// One field of an Arrow schema, as the schema message spells it. Every
/// parameter an absent field leaves at its schema's default already holds
/// that default here.
priv struct ArrowField {
  name : String
  code : Int32
  bit_width : Int32
  signed : Bool
  precision : Int32
  scale : Int32
  unit : Int32
  size : Int32
  dense : Bool
  dictionary_id : Int64?
  index_bit_width : Int32
  index_signed : Bool
  children : Array[ArrowField]
}

///|
/// A 32-bit parameter of a type's table — the table's own default when
/// the type has no table (an empty type) or leaves the field out.
fn type_i32(
  table : FbTable?,
  id : Int32,
  default : Int32,
) -> Int32 raise @types.DataError {
  match table {
    Some(t) =>
      match t.i32(id) {
        Some(v) => v
        None => default
      }
    None => default
  }
}

///|
/// The unit a time type's table leaves out: a timestamp's is the second,
/// and a date's, a time's, and a duration's the millisecond.
fn default_unit(code : Int32) -> Int32 {
  if code == TYPE_TIMESTAMP {
    UNIT_SECOND
  } else {
    UNIT_MILLISECOND
  }
}

///|
fn type_i16(
  table : FbTable?,
  id : Int32,
  default : Int32,
) -> Int32 raise @types.DataError {
  match table {
    Some(t) =>
      match t.i16(id) {
        Some(v) => v
        None => default
      }
    None => default
  }
}

///|
fn type_bool(table : FbTable?, id : Int32) -> Bool raise @types.DataError {
  match table {
    Some(t) =>
      match t.boolean(id) {
        Some(v) => v
        None => false
      }
    None => false
  }
}

///|
/// The field a schema's field table spells. The field's nullability and
/// its custom metadata are not read: a column's cells carry their own
/// nulls, and an extension type rides the storage type it was declared
/// over, which is the type read here.
fn read_field(
  table : FbTable,
  depth : Int32,
) -> ArrowField raise @types.DataError {
  if depth > SCHEMA_DEPTH {
    raise malformed("a field is nested deeper than \{SCHEMA_DEPTH} levels")
  }
  let name = match table.text(0) {
    Some(t) => t
    None => ""
  }
  let code = match table.u8(2) {
    Some(c) => c
    None => raise malformed("a field names no type")
  }
  let type_table = table.table(3)
  // Each type's parameters sit in the slots its own schema gives them:
  // an Int's width, a Time's width behind its unit, and a decimal's
  // width behind its precision and scale. The schema leaves an Int's
  // width at zero when it does not spell it; a 32-bit integer is what
  // such a field has always meant.
  let declared_width = if code == TYPE_INT {
    let width = type_i32(type_table, 0, 0)
    if width == 0 {
      32
    } else {
      width
    }
  } else if code == TYPE_TIME {
    type_i32(type_table, 1, 32)
  } else if code == TYPE_DECIMAL {
    type_i32(type_table, 2, 128)
  } else {
    0
  }
  // A writer leaves a parameter out when it holds the schema's default,
  // and the time types do not share one: a timestamp's unit is a second
  // by default, and a date's, a time's, and a duration's a millisecond.
  let unit = type_i16(type_table, 0, default_unit(code))
  let children : Array[ArrowField] = []
  let child_tables = table.tables(5)
  if child_tables is Some(tables) {
    for child in tables {
      children.push(read_field(child, depth + 1))
    }
  }
  let dictionary = table.table(4)
  let dictionary_id = match dictionary {
    Some(d) =>
      match d.i64(0) {
        Some(v) => Some(v)
        None => Some(0L)
      }
    None => None
  }
  let index_table = match dictionary {
    Some(d) => d.table(1)
    None => None
  }
  let index_width = type_i32(index_table, 0, 32)
  {
    name,
    code,
    bit_width: declared_width,
    signed: type_bool(type_table, 1),
    precision: if code == TYPE_DECIMAL {
      type_i32(type_table, 0, 0)
    } else {
      type_i16(type_table, 0, 0)
    },
    scale: type_i32(type_table, 1, 0),
    unit,
    size: type_i32(type_table, 0, 0),
    dense: type_i16(type_table, 0, 0) == 1,
    dictionary_id,
    index_bit_width: if index_width == 0 {
      32
    } else {
      index_width
    },
    index_signed: type_bool(index_table, 1),
    children,
  }
}

///|
/// The schema a schema message spells: its fields in order, and whether
/// the bodies of its batches are big-endian.
fn read_schema(
  table : FbTable,
) -> (Array[ArrowField], Bool) raise @types.DataError {
  let big = match table.i16(0) {
    Some(1) => true
    Some(0) | None => false
    Some(_) =>
      raise malformed("a schema is neither little-endian nor big-endian")
  }
  let fields : Array[ArrowField] = []
  let declared = table.tables(1)
  if declared is Some(tables) {
    for field in tables {
      fields.push(read_field(field, 1))
    }
  }
  (fields, big)
}

///|
/// What one field's node holds on the wire — the type union's members
/// narrowed to what tells a reader where the bytes are.
priv enum Wire {
  Null
  Int
  Float
  Utf8
  Binary
  Bool
  Decimal
  Date
  Time
  Timestamp
  Duration
  Interval
  List
  Struct
  Union
  Other
}

///|
fn wire_of(code : Int32) -> Wire {
  if code == TYPE_NULL {
    Null
  } else if code == TYPE_INT {
    Int
  } else if code == TYPE_FLOAT {
    Float
  } else if code == TYPE_UTF8 || code == TYPE_LARGE_UTF8 {
    Utf8
  } else if code == TYPE_BINARY ||
    code == TYPE_LARGE_BINARY ||
    code == TYPE_FIXED_SIZE_BINARY {
    Binary
  } else if code == TYPE_BOOL {
    Bool
  } else if code == TYPE_DECIMAL {
    Decimal
  } else if code == TYPE_DATE {
    Date
  } else if code == TYPE_TIME {
    Time
  } else if code == TYPE_TIMESTAMP {
    Timestamp
  } else if code == TYPE_DURATION {
    Duration
  } else if code == TYPE_INTERVAL {
    Interval
  } else if code == TYPE_LIST ||
    code == TYPE_LARGE_LIST ||
    code == TYPE_FIXED_SIZE_LIST ||
    code == TYPE_MAP {
    List
  } else if code == TYPE_STRUCT {
    Struct
  } else if code == TYPE_UNION {
    Union
  } else {
    Other
  }
}

///|
/// A type's own name, for the refusals that cite one: the types outside
/// what this reader maps, and the time types, whose name carries their
/// width.
fn type_name(code : Int32, bit_width : Int32) -> String {
  if code == TYPE_RUN_END {
    "run-end-encoded"
  } else if code == TYPE_BINARY_VIEW {
    "BinaryView"
  } else if code == TYPE_UTF8_VIEW {
    "Utf8View"
  } else if code == TYPE_LIST_VIEW {
    "ListView"
  } else if code == TYPE_LARGE_LIST_VIEW {
    "LargeListView"
  } else if code == TYPE_TIME {
    if bit_width == 64 {
      "time64"
    } else {
      "time32"
    }
  } else {
    "type this reader does not know (union member \{code})"
  }
}

///|
/// A leaf field's values, narrowed to what a decoder reads: every
/// parameter the cells depend on, with the types this reader refuses
/// already left out. A validity buffer opens every one of them.
priv enum Leaf {
  /// An integer: its bit width, and whether it is signed.
  Ints(Int32, Bool)
  /// A float: `true` for the 32-bit format, `false` for the 64-bit one.
  Floats(Bool)
  Bools
  /// A string or a binary column: an offsets buffer over a data buffer,
  /// the offsets `Int64` when the flag is set (the large types).
  Text(Bool)
  /// A fixed-size binary column: so many bytes a cell, no offsets.
  Bytes(Int32)
  /// An unscaled integer under a scale of fraction digits.
  Decimal128s(Int32)
  DateDays
  DateMillis
  /// A count of the time unit: second, millisecond, microsecond, or
  /// nanosecond.
  Timestamps(Int32)
  Durations(Int32)
}

///|
/// What a field's node holds once its type is mapped: the layout a
/// decoder walks — a null column, a leaf's values, a list's offsets and
/// child, a struct's children — or nothing, when the mapping refuses the
/// type.
priv enum Shape {
  Refused
  /// A null column: no buffers, every cell null.
  Nulls
  Leaf(Leaf)
  /// A list, a large list, a map, or a fixed-size list, over one child:
  /// the fixed size (zero for the variable-size kinds), and whether the
  /// offsets are `Int64`.
  List(Int32, Bool)
  Struct
}

///|
/// The plan for one field: how its node is laid out on the wire, and what
/// the field maps to — a dtype, or the reason the mapping refuses it. A
/// refusal is raised when the column is decoded, never at the schema: a
/// projection can leave the column out and read the rest of the file.
priv struct FieldPlan {
  name : String
  shape : Shape
  encoded : Bool
  dictionary_id : Int64
  index_bit_width : Int32
  index_signed : Bool
  children : Array[FieldPlan]
  dtype : @types.DataType?
  refusal : String
  buffers : Int32
}

///|
/// How many buffers the node's own layout consumes, before its children's
/// — the count every Arrow writer lays a field out by: a validity buffer
/// where a field can be null, then the buffers its values need. A null
/// column takes none, a string an offsets buffer and a data buffer, a
/// list an offsets buffer, a struct or a fixed-size list only the
/// validity, and a union its type ids (and, when dense, its offsets). A
/// dictionary-encoded field carries a validity buffer and its indices.
/// `-1` is a layout this reader cannot count from the schema alone — the
/// views' variadic buffers — which nothing after it can be located past.
fn own_buffers(field : ArrowField) -> Int32 {
  if field.dictionary_id is Some(_) {
    2
  } else if field.code == TYPE_NULL {
    0
  } else if field.code == TYPE_UTF8 ||
    field.code == TYPE_LARGE_UTF8 ||
    field.code == TYPE_BINARY ||
    field.code == TYPE_LARGE_BINARY {
    3
  } else if field.code == TYPE_LIST ||
    field.code == TYPE_LARGE_LIST ||
    field.code == TYPE_MAP {
    2
  } else if field.code == TYPE_FIXED_SIZE_LIST || field.code == TYPE_STRUCT {
    1
  } else if field.code == TYPE_UNION {
    if field.dense {
      2
    } else {
      1
    }
  } else if wire_of(field.code) is Other {
    -1
  } else {
    2
  }
}

///|
/// The plan for a field and, recursively, its children.
fn plan_of(field : ArrowField) -> FieldPlan raise @types.DataError {
  let children : Array[FieldPlan] = []
  for child in field.children {
    children.push(plan_of(child))
  }
  let (shape, dtype, refusal) = map_shape(field, children)
  {
    name: field.name,
    shape,
    encoded: field.dictionary_id is Some(_),
    dictionary_id: match field.dictionary_id {
      Some(id) => id
      None => 0L
    },
    index_bit_width: field.index_bit_width,
    index_signed: field.index_signed,
    children,
    dtype,
    refusal,
    buffers: own_buffers(field),
  }
}

///|
/// The shape a field decodes by and the dtype it reads as — or the reason
/// none does, in which case the shape is `Refused`.
fn map_shape(
  field : ArrowField,
  children : Array[FieldPlan],
) -> (Shape, @types.DataType?, String) raise @types.DataError {
  let refused = fn(reason : String) -> (Shape, @types.DataType?, String) {
    (Refused, None, reason)
  }
  match wire_of(field.code) {
    // MoonFrame builds no column of dtype Null: a null column reads as the
    // all-null String column a reader gives a column with nothing to type
    // it from.
    Null => (Nulls, Some(@types.DataType::String), "")
    Int =>
      if field.bit_width == 8 ||
        field.bit_width == 16 ||
        field.bit_width == 32 ||
        field.bit_width == 64 {
        (
          Leaf(Ints(field.bit_width, field.signed)),
          Some(@types.DataType::Int),
          "",
        )
      } else {
        refused("an integer of \{field.bit_width} bits")
      }
    Float =>
      if field.precision == 1 || field.precision == 2 {
        (Leaf(Floats(field.precision == 1)), Some(@types.DataType::Float), "")
      } else {
        refused("a Float16 column, whose 11-bit significand narrows")
      }
    Utf8 =>
      (
        Leaf(Text(field.code == TYPE_LARGE_UTF8)),
        Some(@types.DataType::String),
        "",
      )
    Binary =>
      if field.code == TYPE_FIXED_SIZE_BINARY {
        (Leaf(Bytes(field.size)), Some(@types.DataType::String), "")
      } else {
        (
          Leaf(Text(field.code == TYPE_LARGE_BINARY)),
          Some(@types.DataType::String),
          "",
        )
      }
    Bool => (Leaf(Bools), Some(@types.DataType::Bool), "")
    Decimal =>
      if field.bit_width != 128 {
        refused("a Decimal256 column")
      } else if field.scale < -DECIMAL_SCALE_MAX ||
        field.scale > DECIMAL_SCALE_MAX {
        refused("a decimal whose scale leaves the range a decimal holds")
      } else {
        (Leaf(Decimal128s(field.scale)), Some(@types.DataType::Decimal), "")
      }
    // A millisecond date can carry a time of day; it reads as the instant
    // it is, exactly, rather than as the day it may not fall on.
    Date =>
      if field.unit == UNIT_SECOND {
        (Leaf(DateDays), Some(@types.DataType::Date), "")
      } else if field.unit == UNIT_MILLISECOND {
        (Leaf(DateMillis), Some(@types.DataType::Timestamp), "")
      } else {
        raise malformed("a date is counted in a unit the schema does not have")
      }
    Time =>
      refused(
        "a \{type_name(field.code, field.bit_width)} column, a time of day",
      )
    Timestamp => {
      check_time_unit(field)
      (Leaf(Timestamps(field.unit)), Some(@types.DataType::Timestamp), "")
    }
    Duration => {
      check_time_unit(field)
      (Leaf(Durations(field.unit)), Some(@types.DataType::Duration), "")
    }
    Interval => refused("an interval column")
    List => {
      if children.length() != 1 {
        raise malformed("a list field does not carry exactly one child")
      }
      let fixed = if field.code == TYPE_FIXED_SIZE_LIST {
        field.size
      } else {
        0
      }
      match children[0].dtype {
        Some(element) =>
          (
            List(fixed, field.code == TYPE_LARGE_LIST),
            Some(@types.DataType::List(element)),
            "",
          )
        None => refused("a list of \{children[0].refusal}")
      }
    }
    Struct =>
      if children.is_empty() {
        refused("a struct with no field")
      } else {
        let fields : Array[@types.Field] = []
        let mut reason = ""
        for child in children {
          match child.dtype {
            Some(dtype) => fields.push(@types.Field::Field(child.name, dtype))
            None => reason = "a struct holding \{child.refusal}"
          }
        }
        if reason != "" {
          refused(reason)
        } else {
          match struct_schema_of(fields) {
            Some(schema) => (Struct, Some(@types.DataType::Struct(schema)), "")
            None => refused("a struct whose field names repeat")
          }
        }
      }
    Union => refused("a union column")
    Other => refused("a \{type_name(field.code, field.bit_width)} column")
  }
}

///|
/// A timestamp's or a duration's unit, one of the four the schema has.
fn check_time_unit(field : ArrowField) -> Unit raise @types.DataError {
  if field.unit < UNIT_SECOND || field.unit > UNIT_NANOSECOND {
    raise malformed("a time is counted in a unit the schema does not have")
  }
}

///|
/// A struct's schema from its fields, or `None` when two of them share a
/// name — the schema constructor's own check, answered as an option so a
/// repeated name is its column's refusal and not a failed read of the
/// file.
fn struct_schema_of(
  fields : Array[@types.Field],
) -> @types.Schema? raise @types.DataError {
  let names : Array[String] = []
  for field in fields {
    if names.contains(field.name()) {
      return None
    }
    names.push(field.name())
  }
  // The walk above is the constructor's own check, answered as an
  // option: a repeated name is its column's refusal, not a failed read.
  Some(@types.Schema::Schema(fields))
}

///|
/// The nodes a field's subtree spans: itself, and — unless the node
/// carries dictionary indices, whose values live in a dictionary batch —
/// its children's subtrees.
fn FieldPlan::node_count(self : FieldPlan) -> Int32 {
  if self.encoded {
    1
  } else {
    let mut n = 1
    for child in self.children {
      n += child.node_count()
    }
    n
  }
}

///|
/// The buffers a field's subtree consumes: the node's own, then its
/// children's. `-1` when any node in the subtree has a layout this reader
/// cannot count.
fn FieldPlan::buffer_count(self : FieldPlan) -> Int32 {
  if self.buffers < 0 {
    -1
  } else if self.encoded {
    self.buffers
  } else {
    let mut n = self.buffers
    for child in self.children {
      let below = child.buffer_count()
      if below < 0 {
        return -1
      }
      n += below
    }
    n
  }
}
