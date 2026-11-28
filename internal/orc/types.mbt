// The mapping of the Footer's type tree to what a column decodes and to
// the dtype its column is built with: one cell kind and one dtype a type
// node, nested nodes mapped through their children. The mapping is read
// off the type tree alone, so a column of no row or of nothing but nulls
// still has its dtype, and a type this reader does not carry is refused
// by name, with the column's way from the top-level field.

///|
/// What a column's present values decode as: the stream they ride and
/// the way they are read. A list names its element's type and a struct
/// its fields' types, in the tree's numbering.
priv enum Cell {
  CBool
  CByte
  CInt
  CFloat
  CDouble
  CString
  CTimestamp
  CDate
  CDecimalLong
  CDecimal
  CList(Int32)
  CStruct(Array[Int32], Array[String])
}

///|
/// The cells the type `id` decodes to and the dtype its column is built
/// with. `path` is the column's way from its top-level field — the
/// field's name, a struct field's after a dot, a list element's under
/// `[]` — the words a refusal names it by. Raises `Unsupported` for a
/// BINARY, MAP or UNION column, for a kind the format does not name, and
/// for a struct whose two fields share a name, which spells no schema.
fn plan(
  layout : Layout,
  id : Int32,
  path : String,
) -> (Cell, @types.DataType) raise @types.DataError {
  let t = layout.types[id]
  match t.kind {
    0 => (CBool, @types.DataType::Bool)
    1 => (CByte, @types.DataType::Int)
    2 | 3 | 4 => (CInt, @types.DataType::Int)
    5 => (CFloat, @types.DataType::Float)
    6 => (CDouble, @types.DataType::Float)
    7 | 16 | 17 => (CString, @types.DataType::String)
    9 | 18 => (CTimestamp, @types.DataType::Timestamp)
    15 => (CDate, @types.DataType::Date)
    14 =>
      // Under the UNSTABLE-PRE-2.0 spelling a decimal of precision up to
      // 18 is an integer run length stream at the type's own scale;
      // every other decimal is unbounded varints at a scale a stream
      // carries for each value.
      if layout.decimal_as_long && t.precision > 0L && t.precision <= 18L {
        (CDecimalLong, @types.DataType::Decimal)
      } else {
        (CDecimal, @types.DataType::Decimal)
      }
    10 => {
      let (_, dtype) = plan(layout, t.subtypes[0], "\{path}[]")
      (CList(t.subtypes[0]), @types.DataType::List(dtype))
    }
    12 => {
      let fields : Array[@types.Field] = []
      let cells : Array[Int32] = []
      for i, sub in t.subtypes {
        let name = t.names[i]
        if named_before(t.names, i) {
          let error = refuse(
            "column \"\{path}\" holds a STRUCT whose field name \"\{name}\" repeats, which spells no schema",
          )
          raise error
        }
        cells.push(sub)
        let (_, dtype) = plan(layout, sub, "\{path}.\{name}")
        fields.push(@types.Field::Field(name, dtype))
      }
      let schema = @types.Schema::Schema(fields)
      (CStruct(cells, t.names), @types.DataType::Struct(schema))
    }
    8 => raise refuse("column \"\{path}\" is BINARY, which has no dtype here")
    11 => raise refuse("column \"\{path}\" is a MAP, which has no dtype here")
    13 => raise refuse("column \"\{path}\" is a UNION, which has no dtype here")
    kind =>
      raise refuse(
        "column \"\{path}\" is of \{kind_name(kind)}, which this reader does not carry",
      )
  }
}

///|
/// Whether the name at `index` is also the name of an earlier field.
fn named_before(names : Array[String], index : Int32) -> Bool {
  let name = names[index]
  let mut earlier = false
  for i in 0..<index {
    if names[i] == name {
      earlier = true
    }
  }
  earlier
}
