// The nested columns of the JSON readers: a JSON array or object in a
// record's field is a list or struct cell, not a string. A column whose
// probe window holds either is a nested column — decided here, ahead of
// the shared inference skeleton, whose four dtypes are all scalar — and
// built from whole cells rather than typed arrays. It is read by the
// readers' scalar rules, applied at every position: the cells of the
// column, the elements of a list, the fields of a struct. At each, the
// dtype is the narrowest that accepts every value the window holds there —
// `Int → Float → Bool → String` — with "every value is an array" a list of
// the dtype its elements name and "every value is an object" a struct of
// the fields the objects name; a `String` at any position takes any value
// as its text. A `dtypes` pin names a nested dtype instead of inferring
// one, and every cell is then read under it, elements and fields included:
// a `Date` element parses from the text the writer rendered, exactly as a
// top-level `Date` pin does.

///|
/// What kind of column a JSON field is: a scalar column under one of the
/// shared inference dtypes, or a nested column under a list or struct
/// dtype — the pin when the caller gave one, otherwise the dtype the
/// probe window's cells agree on.
priv enum JsonColumn {
  Flat(InferredDtype)
  Nested(@types.DataType)
}

///|
/// The column a `dtypes` pin asks for. A nested pin is taken here, ahead
/// of the shared decode — the JSON readers read nested cells, so the pin
/// has something to pin; every other pin goes through that decode.
fn json_column_from_pin(
  column : String,
  dt : @types.DataType,
) -> JsonColumn raise @types.DataError {
  if json_dtype_is_nested(dt) {
    Nested(dt)
  } else {
    Flat(inferred_from_override(column, dt))
  }
}

///|
/// Whether a JSON value is a composite — the shape that makes a column
/// nested.
fn json_is_composite(j : Json) -> Bool {
  j is Array(_) || j is Object(_)
}

///|
/// Whether a JSON value is an integer, a float, or a boolean by the scalar
/// readers' own probes — so a nested leaf and a scalar column agree on
/// what counts as each dtype.
fn json_is_int(j : Json) -> Bool {
  json_value_as_int(j) is Some(_)
}

///|
/// The float probe, under the non-finite gate the read was given.
fn json_is_float(j : Json, allow_nonfinite : Bool) -> Bool {
  json_value_as_float(j, allow_nonfinite~) is Some(_)
}

///|
/// The boolean probe.
fn json_is_bool(j : Json) -> Bool {
  json_value_as_bool(j) is Some(_)
}

///|
/// The dtype of one position — a column's cells, the elements of a list,
/// the fields of a struct — over the non-null values the probe window
/// holds there. It is the scalar inference rule with the two composite
/// kinds ahead of it: every value an array names a list of the dtype its
/// elements together name, and every value an object names a struct of the
/// fields the objects name between them, in first-seen order, each typed by
/// the values carried under that name — an object that leaves a field out
/// says nothing about it, and reads it as null. Otherwise the narrowest of
/// `Int → Float → Bool` that accepts every value, and `String` when none
/// does. A position with no value to ask — no elements, no fields, every
/// value null — also names no dtype and takes the all-null default,
/// `String`.
///
/// Raises what the schema constructor raises for a repeated field name,
/// which cannot happen here: a JSON object's keys are unique, so the
/// first-seen names of its objects are too.
fn json_position_dtype(
  values : Array[Json],
  allow_nonfinite~ : Bool,
) -> @types.DataType raise @types.DataError {
  if values.is_empty() {
    return @types.DataType::String
  }
  if json_is_composite(values[0]) {
    return json_composite_dtype(values, allow_nonfinite~)
  }
  if values.all(json_is_int) {
    return @types.DataType::Int
  }
  if values.all(j => json_is_float(j, allow_nonfinite)) {
    return @types.DataType::Float
  }
  if values.all(json_is_bool) {
    return @types.DataType::Bool
  }
  @types.DataType::String
}

///|
/// The dtype of a position whose first value is a composite: the nested
/// dtype when every value is the same kind of composite, and `String` when
/// the kinds are mixed — a list and a struct, or either and a scalar, have
/// no dtype in common, so the position keeps each value as its text.
fn json_composite_dtype(
  values : Array[Json],
  allow_nonfinite~ : Bool,
) -> @types.DataType raise @types.DataError {
  if values[0] is Array(_) {
    if values.all(j => j is Array(_)) {
      let elements : Array[Json] = []
      for j in values {
        if j is Array(items) {
          for item in items {
            if !(item is Null) {
              elements.push(item)
            }
          }
        }
      }
      return @types.DataType::List(
        json_position_dtype(elements, allow_nonfinite~),
      )
    }
    return @types.DataType::String
  }
  if values.all(j => j is Object(_)) {
    // The field names in first-seen order, and under each the values the
    // objects carry — an object without the field contributes none.
    let names : Array[String] = []
    let index : Map[String, Int32] = Map([])
    let per_field : Array[Array[Json]] = []
    for j in values {
      if j is Object(fields) {
        for key, value in fields {
          let at = match index.get(key) {
            Some(i) => i
            None => {
              index[key] = names.length()
              names.push(key)
              per_field.push([])
              names.length() - 1
            }
          }
          if !(value is Null) {
            per_field[at].push(value)
          }
        }
      }
    }
    if names.is_empty() {
      return @types.DataType::String
    }
    let declared : Array[@types.Field] = []
    for i, name in names {
      declared.push(
        @types.Field::Field(
          name,
          json_position_dtype(per_field[i], allow_nonfinite~),
        ),
      )
    }
    return @types.DataType::Struct(@types.Schema::Schema(declared))
  }
  @types.DataType::String
}

///|
/// Infer a JSON field's column kind over its first `limit` records (`limit
/// <= 0` scans every record, the windowed-inference rule). A window that
/// holds no composite is a scalar column and goes through the shared
/// inference core. One that holds a composite is read by the position rule
/// over its cells: a list or struct dtype makes a nested column, and a
/// `String` keeps every cell as its text — the fallback a scalar column
/// takes when its cells agree on no dtype.
fn infer_json_column(
  objs : Array[Map[String, Json]],
  name : String,
  limit : Int32,
  allow_nonfinite~ : Bool,
) -> JsonColumn raise @types.DataError {
  let n = objs.length()
  let scan = if limit <= 0 || limit > n { n } else { limit }
  let values : Array[Json] = []
  for i in 0..<scan {
    let j = lookup_field(objs[i], name)
    if !(j is Null) {
      values.push(j)
    }
  }
  if values.any(json_is_composite) {
    let dtype = json_position_dtype(values, allow_nonfinite~)
    if json_dtype_is_nested(dtype) {
      Nested(dtype)
    } else {
      Flat(InferString)
    }
  } else {
    Flat(infer_json_column_dtype(objs, name, limit, allow_nonfinite~))
  }
}

///|
/// Whether a dtype is a nested one — the two dtypes a JSON column is built
/// from whole cells under.
fn json_dtype_is_nested(dtype : @types.DataType) -> Bool {
  dtype is @types.DataType::List(_) || dtype is @types.DataType::Struct(_)
}

///|
/// One JSON value read under the dtype its position carries, or `None`
/// when it does not fit — the rule an inferred dtype and a pin both read a
/// cell through, the scalar readers' own at every leaf. A null fits every
/// dtype. A list dtype takes an array and reads each element under the
/// element dtype; a struct dtype takes an object and reads each of its
/// fields under that field's dtype, by name in the dtype's order — a field
/// the object leaves out reads as null, and one it carries beyond the
/// dtype's is not part of the dtype and is left behind. A `String` takes
/// any value as its text, as a `String` column does. A rider dtype
/// (`Date` / `Timestamp` / `Decimal`) parses a JSON string, the one carrier
/// the riders have; an `Int` takes an integer-valued number and a `Float`
/// any number, the non-finite gate included; a `Bool` takes `true` or
/// `false`. `Duration` has no text parser and fits nothing.
fn json_scalar_under(
  j : Json,
  dtype : @types.DataType,
  allow_nonfinite~ : Bool,
) -> @types.Scalar? {
  if j is Null {
    return Some(@types.Scalar::Null)
  }
  if dtype is @types.DataType::List(element) {
    if j is Array(items) {
      let cells : Array[@types.Scalar] = []
      for item in items {
        match json_scalar_under(item, element, allow_nonfinite~) {
          Some(cell) => cells.push(cell)
          None => return None
        }
      }
      return Some(@types.Scalar::List(@types.ListValue::ListValue(cells)))
    }
    return None
  }
  if dtype is @types.DataType::Struct(fields) {
    if j is Object(given) {
      let values : Array[@types.FieldValue] = []
      for field in fields.fields() {
        let value = match given.get(field.name()) {
          Some(v) => v
          None => Json::null()
        }
        match json_scalar_under(value, field.dtype(), allow_nonfinite~) {
          Some(cell) =>
            values.push(@types.FieldValue::FieldValue(field.name(), cell))
          None => return None
        }
      }
      return Some(
        @types.Scalar::Struct(@types.StructValue::StructValue(values)),
      )
    }
    return None
  }
  if dtype is @types.DataType::String {
    return Some(@types.Scalar::String(json_value_to_string_fallback(j)))
  }
  // A rider parses a JSON string through its own parser, the one a
  // top-level pin reads through; any other JSON value does not fit it,
  // and falls through the scalar probes below, which name other dtypes.
  if dtype is @types.DataType::Date && j is String(text) {
    return @types.parse_date_days_opt(text).map(v => @types.Scalar::Date(v))
  }
  if dtype is @types.DataType::Timestamp && j is String(text) {
    return @types.parse_timestamp_micros_opt(text).map(v => {
      @types.Scalar::Timestamp(v)
    })
  }
  if dtype is @types.DataType::Decimal && j is String(text) {
    return @types.Dec128::parse_opt(text).map(v => @types.Scalar::Decimal(v))
  }
  if dtype is @types.DataType::Int {
    return json_value_as_int(j).map(v => @types.Scalar::Int(v))
  }
  if dtype is @types.DataType::Float {
    return json_value_as_float(j, allow_nonfinite~).map(v => {
      @types.Scalar::Float(v)
    })
  }
  if dtype is @types.DataType::Bool {
    return json_value_as_bool(j).map(v => @types.Scalar::Bool(v))
  }
  None
}

///|
/// Build the nested column `dtype` names over the records `from` selects.
/// Every cell is read under the dtype; a cell that does not fit it is
/// handled per `on_parse_error` exactly as a scalar reader's would be —
/// `Raise` surfaces a located `ParseError` naming the column, the dtype,
/// and the offending value, `Null` reads the cell as null.
fn build_json_nested_column(
  name : String,
  dtype : @types.DataType,
  from : Array[Map[String, Json]],
  on_parse_error : OnParseError,
  source_lines : Array[Int32]?,
  allow_nonfinite~ : Bool,
) -> @series.Series raise @types.DataError {
  let n = from.length()
  let cells : Array[@types.Scalar] = Array::makei(n, i => {
    let c = lookup_field(from[i], name)
    match json_scalar_under(c, dtype, allow_nonfinite~) {
      Some(value) => value
      None =>
        match on_parse_error {
          Raise => {
            let (location, position) = json_cell_parse_location(source_lines, i)
            raise @types.DataError::ParseError(
              @types.ParseErrorDetail::Cell(
                location,
                name,
                position,
                dtype,
                json_value_to_string_fallback(c),
              ),
            )
          }
          Null => @types.Scalar::Null
        }
    }
  })
  @series.Series::from_scalars(name, cells, dtype~)
}
