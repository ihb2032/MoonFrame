// The table schema as the metadata JSON spells it: a struct whose fields
// carry an id, a name, a type and a required flag, nested without limit.
// The current schema's top-level fields become the library's fields; the
// schema a manifest's header carries is read for the type of the column a
// partition field names by id. Columns are selected by id in Iceberg, so a
// column keeps its id through a rename, and a file written before a column
// was added lacks it.

///|
/// One column of a table schema, wherever it sits in a nested struct.
priv struct Column {
  id : Int64
  type_text : String
}

///|
/// The spelling of a type: a primitive's own name, or the keyword of a
/// nested type's definition.
fn type_text(ty : Json, path : String) -> String raise @types.DataError {
  match ty {
    String(text) => text
    Object(members) =>
      json_string(
        json_member(members, "type", "the type of column \"\{path}\""),
        "the type of column \"\{path}\"",
      )
    _ =>
      raise malformed(
        "the type of column \"\{path}\" is neither a name nor a definition",
      )
  }
}

///|
/// Every field of one struct into `columns`, nested ones included;
/// `ids` receives the ids of the outermost struct's fields alone.
fn struct_columns(
  fields : Array[Json],
  prefix : String,
  columns : Array[Column],
  ids : Array[Int64],
) -> Unit raise @types.DataError {
  let what = if prefix.is_empty() {
    "a field of the schema"
  } else {
    "a field of the struct \"\{prefix}\""
  }
  for field in fields {
    let members = json_object(field, what)
    let name = json_string(json_member(members, "name", what), "\{what}'s name")
    let id = json_int(json_member(members, "id", what), "\{what}'s id")
    let ty = json_member(members, "type", what)
    let path = if prefix.is_empty() { name } else { "\{prefix}.\{name}" }
    columns.push({ id, type_text: type_text(ty, path), })
    if prefix.is_empty() {
      ids.push(id)
    }
    if ty is Object(nested) {
      match nested.get("type") {
        Some(String("struct")) =>
          struct_columns(
            json_array(
              json_member(nested, "fields", "the struct \"\{path}\""),
              "the fields of the struct \"\{path}\"",
            ),
            path,
            columns,
            ids,
          )
        _ => ()
      }
    }
  }
}

///|
/// The fields of a schema with their ids and types — nested ones included
/// — and the ids of the schema's own fields alone.
fn schema_columns(
  schema : Json,
) -> (Array[Column], Array[Int64]) raise @types.DataError {
  let members = json_object(schema, "the schema")
  let keyword = json_string(
    json_member(members, "type", "the schema"),
    "the schema's type",
  )
  if keyword != "struct" {
    raise malformed("a schema whose type is \{keyword}, not struct")
  }
  let columns : Array[Column] = []
  let ids : Array[Int64] = []
  struct_columns(
    json_array(
      json_member(members, "fields", "the schema"),
      "the schema's fields",
    ),
    "",
    columns,
    ids,
  )
  (columns, ids)
}

///|
/// The type of the column with the field id, as the schema spells it.
fn type_of_column(columns : Array[Column], id : Int64) -> String? {
  for column in columns {
    if column.id == id {
      return Some(column.type_text)
    }
  }
  None
}

///|
/// The precision and scale a `decimal(P, S)` spelling names; blanks are
/// allowed after the comma. Raises `ParseError` for any other shape.
fn decimal_shape(
  text : String,
  path : String,
) -> (Int64, Int64) raise @types.DataError {
  // Past `decimal(`.
  let (precision, opened) = unsigned_at(text, 8)
  let mut at = opened
  let mut scale : Int64? = None
  if unit_at(text, at) == 44 {
    at += 1
    while unit_at(text, at) == 32 {
      at += 1
    }
    let (found, after) = unsigned_at(text, at)
    scale = found
    at = after
  }
  let closed = at == text.length() - 1 && unit_at(text, at) == 41
  match (precision, scale, closed) {
    (Some(p), Some(s), true) => (p, s)
    _ =>
      raise malformed(
        "\{text}, the type of column \"\{path}\", spells no precision and scale",
      )
  }
}

///|
/// The library dtype a primitive type reads as. Raises `Unsupported`,
/// naming the column, for a type this reader does not carry.
fn primitive_dtype(
  text : String,
  path : String,
) -> @types.DataType raise @types.DataError {
  match text {
    "boolean" => @types.DataType::Bool
    "int" | "long" => @types.DataType::Int
    "float" | "double" => @types.DataType::Float
    "string" => @types.DataType::String
    "date" => @types.DataType::Date
    "timestamp" | "timestamptz" => @types.DataType::Timestamp
    _ =>
      if text.has_prefix("decimal") {
        let (precision, scale) = decimal_shape(text, path)
        if precision < 1 || precision > 38 || scale < 0 || scale > precision {
          raise malformed(
            "\{text}, the type of column \"\{path}\", is not a decimal's precision and scale",
          )
        }
        if precision > 34 {
          raise refuse(
            "column \"\{path}\": decimal(\{precision}, \{scale}) holds up to \{precision} digits, where a Decimal here holds 34",
          )
        }
        @types.DataType::Decimal
      } else {
        raise refuse(
          "column \"\{path}\": the type \{text}, which this reader does not carry",
        )
      }
  }
}

///|
/// The library dtype a type reads as. A list reads as a list of its
/// element's dtype and a struct as a struct of its fields'.
fn dtype_of(ty : Json, path : String) -> @types.DataType raise @types.DataError {
  match ty {
    String(text) => primitive_dtype(text, path)
    Object(members) =>
      match json_member(members, "type", "the type of column \"\{path}\"") {
        String("list") =>
          @types.DataType::List(
            dtype_of(
              json_member(members, "element", "the list \"\{path}\""),
              "\{path}[]",
            ),
          )
        String("struct") =>
          @types.DataType::Struct(
            @types.Schema::Schema(
              library_fields(
                json_array(
                  json_member(members, "fields", "the struct \"\{path}\""),
                  "the fields of the struct \"\{path}\"",
                ),
                path,
              ),
            ),
          )
        String(other) =>
          raise refuse(
            "column \"\{path}\": the type \{other}, which this reader does not carry",
          )
        _ =>
          raise malformed(
            "the type of column \"\{path}\" is neither a name nor a definition",
          )
      }
    _ =>
      raise malformed(
        "the type of column \"\{path}\" is neither a name nor a definition",
      )
  }
}

///|
/// The fields of one struct of the table's current schema as the library
/// spells them: by name and dtype, every one nullable. Raises `Unsupported`
/// for a field with an initial default other than null — the files written
/// before the field was added do not hold it and this reader does not
/// materialise one — and for two fields of one struct that share a name.
fn library_fields(
  fields : Array[Json],
  prefix : String,
) -> Array[@types.Field] raise @types.DataError {
  let owner = if prefix.is_empty() {
    "the schema"
  } else {
    "the struct \"\{prefix}\""
  }
  let out : Array[@types.Field] = []
  for field in fields {
    let members = json_object(field, "a field of \{owner}")
    let name = json_string(
      json_member(members, "name", "a field of \{owner}"),
      "the name of a field of \{owner}",
    )
    for earlier in out {
      if earlier.name() == name {
        raise refuse("\{owner} holds two fields named \"\{name}\"")
      }
    }
    let path = if prefix.is_empty() { name } else { "\{prefix}.\{name}" }
    // A null default counts as none, which it is: the rows written before
    // the column was added read null either way.
    match json_optional(members, "initial-default") {
      Some(default) =>
        raise refuse(
          "column \"\{path}\": the initial default \{default.stringify()}, which the files written before the column was added do not hold and this reader does not materialise",
        )
      None => ()
    }
    out.push(
      @types.Field::Field(
        name,
        dtype_of(json_member(members, "type", "a field of \{owner}"), path),
      ),
    )
  }
  out
}

///|
/// The current schema's own fields as the library spells them.
fn current_fields(schema : Json) -> @types.Schema raise @types.DataError {
  let members = json_object(schema, "the schema")
  @types.Schema::Schema(
    library_fields(
      json_array(
        json_member(members, "fields", "the schema"),
        "the schema's fields",
      ),
      "",
    ),
  )
}
