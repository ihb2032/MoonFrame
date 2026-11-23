// Whitebox pins for the nested values: the two payloads a `Scalar::List`
// / `Scalar::Struct` carry, their immutability, the dtype a nested value
// names, the text it renders, and the one shape rule (`fits_value`) every
// nested build reads.

///|
fn lv(cells : Array[Scalar]) -> Scalar {
  Scalar::List(ListValue::ListValue(cells))
}

///|
fn fv(name : String, value : Scalar) -> FieldValue {
  FieldValue::FieldValue(name, value)
}

///|
fn sv(a : Scalar, b : Scalar) -> Scalar {
  Scalar::Struct(StructValue::StructValue([fv("a", a), fv("b", b)]))
}

///|
fn fields2() -> Schema raise DataError {
  Schema::Schema([
    Field::Field("a", DataType::Int),
    Field::Field("b", DataType::Int),
  ])
}

///|
fn int_list(cells : Array[Int64]) -> Scalar {
  lv(cells.map(i => Scalar::Int(i)))
}

///|
test "a list value owns its cells and hands out copies" {
  let source : Array[Scalar] = [Scalar::Int(1), Scalar::Int(2)]
  let value = ListValue::ListValue(source)
  // A later mutation of the caller's array cannot reach the value.
  source[0] = Scalar::Int(9)
  assert_eq(value.len(), 2)
  assert_eq(value.get(0), Scalar::Int(1))
  assert_eq(value.get(1), Scalar::Int(2))
  assert_false(value.is_empty())
  // The accessor answers a copy: writing into it leaves the value alone.
  let out = value.cells()
  out[1] = Scalar::Int(7)
  assert_eq(value.get(1), Scalar::Int(2))
  // An index outside the list raises.
  let over = Ok(ignore(value.get(2))) catch { e => Err(e) }
  assert_true(over is Err(DataError::IndexOutOfBounds(2)))
  let under = Ok(ignore(value.get(-1))) catch { e => Err(e) }
  assert_true(under is Err(DataError::IndexOutOfBounds(-1)))
  // The empty list.
  assert_true(ListValue::ListValue([]).is_empty())
}

///|
test "a field value names its field and carries its cell" {
  let field = FieldValue::FieldValue("a", Scalar::Int(3))
  assert_eq(field.name(), "a")
  assert_eq(field.value(), Scalar::Int(3))
}

///|
test "a struct value owns its fields and finds them by name" {
  let source : Array[FieldValue] = [fv("a", Scalar::Int(1))]
  let value = StructValue::StructValue(source)
  source[0] = fv("z", Scalar::Int(9))
  assert_eq(value.len(), 1)
  assert_eq(value.get(0).name(), "a")
  assert_eq(value.get(0).value(), Scalar::Int(1))
  let out = value.fields()
  out[0] = fv("q", Scalar::Int(9))
  assert_eq(value.get(0).name(), "a")
  let over = Ok(ignore(value.get(1))) catch { e => Err(e) }
  assert_true(over is Err(DataError::IndexOutOfBounds(1)))
  // By name: the first match answers; an absent name answers `None`.
  let two = StructValue::StructValue([fv("a", Scalar::Int(1)), fv("b", Null)])
  assert_eq(two.get_named("b"), Some(Scalar::Null))
  assert_eq(two.get_named("a"), Some(Scalar::Int(1)))
  assert_eq(two.get_named("c"), None)
  // A value built by hand may repeat a name; the first one answers.
  let repeated = StructValue::StructValue([
    fv("a", Scalar::Int(1)),
    fv("a", Scalar::Int(2)),
  ])
  assert_eq(repeated.get_named("a"), Some(Scalar::Int(1)))
  // A struct value with no field.
  let bare = StructValue::StructValue([])
  assert_eq(bare.len(), 0)
  assert_eq(bare.get_named("a"), None)
}

///|
test "a nested value names its dtype, and names Null where nothing else" {
  // A list's element dtype is its first present element's.
  assert_eq(int_list([1, 2]).dtype(), DataType::List(DataType::Int))
  assert_eq(
    lv([Null, Scalar::String("x"), Scalar::Float(1.0)]).dtype(),
    DataType::List(DataType::String),
  )
  // An empty or all-null list names Null.
  assert_eq(lv([]).dtype(), DataType::List(DataType::Null))
  assert_eq(lv([Null, Null]).dtype(), DataType::List(DataType::Null))
  // A list of lists.
  assert_eq(
    lv([int_list([1])]).dtype(),
    DataType::List(DataType::List(DataType::Int)),
  )
  // A struct's dtype is the schema its cells spell.
  let struct_d = sv(Scalar::Int(1), Scalar::String("x")).dtype()
  assert_eq(
    struct_d,
    DataType::Struct(
      Schema::Schema([
        Field::Field("a", DataType::Int),
        Field::Field("b", DataType::String),
      ]),
    ),
  )
  // A null field names Null in the schema.
  let with_null = sv(Null, Scalar::Int(2)).dtype()
  assert_eq(
    with_null,
    DataType::Struct(
      Schema::Schema([
        Field::Field("a", DataType::Null),
        Field::Field("b", DataType::Int),
      ]),
    ),
  )
  // A struct whose names repeat spells no schema: the value's dtype is
  // the one a missing value has.
  let repeated = Scalar::Struct(
    StructValue::StructValue([fv("a", Scalar::Int(1)), fv("a", Scalar::Int(2))]),
  )
  assert_eq(repeated.dtype(), DataType::Null)
}

///|
test "a struct value's schema spells its fields, or refuses a repeat" {
  let value = StructValue::StructValue([
    fv("a", Scalar::Int(1)),
    fv("b", Scalar::Float(2.0)),
  ])
  let schema = value.schema()
  assert_eq(schema.field_names(), ["a", "b"])
  assert_eq(schema.field("a").dtype(), DataType::Int)
  assert_eq(schema.field("b").dtype(), DataType::Float)
  let bare = StructValue::StructValue([]).schema()
  assert_eq(bare.len(), 0)
  // A repeated name refuses by that name.
  let repeated = StructValue::StructValue([
    fv("a", Scalar::Int(1)),
    fv("b", Null),
    fv("b", Scalar::Int(2)),
  ])
  assert_true(value.schema_opt() is Some(_))
  assert_true(repeated.schema_opt() is None)
  let refused = Ok(ignore(repeated.schema())) catch { e => Err(e) }
  assert_true(refused is Err(DataError::DuplicateColumn("b")))
}

///|
test "a nested value renders as JSON-shaped text" {
  // Elements comma-separated in brackets; a string quoted; a null `null`.
  assert_eq(int_list([1, 2]).to_string(), "[1, 2]")
  assert_eq(lv([]).to_string(), "[]")
  assert_eq(
    lv([Scalar::String("a"), Null, Scalar::Bool(true), Scalar::Float(1.5)]).to_string(),
    "[\"a\", null, true, 1.5]",
  )
  // A quote inside a string is escaped.
  assert_eq(lv([Scalar::String("s\"q")]).to_string(), "[\"s\\\"q\"]")
  // A nested value recurses.
  assert_eq(lv([int_list([1]), lv([])]).to_string(), "[[1], []]")
  // A struct: quoted names, a colon, the field's value; braces.
  assert_eq(
    sv(Scalar::Int(1), Scalar::String("x")).to_string(),
    "{\"a\": 1, \"b\": \"x\"}",
  )
  assert_eq(
    sv(Null, int_list([2, 3])).to_string(),
    "{\"a\": null, \"b\": [2, 3]}",
  )
  assert_eq(Scalar::Struct(StructValue::StructValue([])).to_string(), "{}")
  // The other scalars render in their own value form inside a list.
  assert_eq(
    lv([
      Scalar::Date(0),
      Scalar::Timestamp(0),
      Scalar::Decimal(Dec128::of_int64_scale(150, scale=2)),
      Scalar::Duration(86_400_000_000L),
    ]).to_string(),
    "[1970-01-01, 1970-01-01T00:00:00.000000, 1.50, P1DT0.000000S]",
  )
}

///|
test "a nested value's variant form carries the same text" {
  inspect(int_list([1, 2]), content="List([1, 2])")
  inspect(lv([]), content="List([])")
  inspect(sv(Scalar::Int(1), Null), content="Struct({\"a\": 1, \"b\": null})")
}

///|
test "fits_value judges a value against a dtype's whole shape" {
  let ints = DataType::List(DataType::Int)
  // A list of the element dtype fits; so does an empty list and a list
  // of nulls; a list of another dtype does not.
  assert_true(ints.fits_value(int_list([1, 2])))
  assert_true(ints.fits_value(lv([])))
  assert_true(ints.fits_value(lv([Null, Scalar::Int(3)])))
  assert_false(ints.fits_value(lv([Scalar::String("x")])))
  assert_false(ints.fits_value(lv([int_list([1])])))
  // A null fits every dtype — it is the missing value.
  assert_true(ints.fits_value(Scalar::Null))
  assert_true(DataType::Int.fits_value(Scalar::Null))
  // A scalar dtype takes its own scalar and no other shape.
  assert_true(DataType::Int.fits_value(Scalar::Int(1)))
  assert_false(DataType::Int.fits_value(int_list([1])))
  assert_false(DataType::String.fits_value(Scalar::Int(1)))
  // A list dtype takes no struct, a struct dtype no list.
  assert_false(ints.fits_value(sv(Scalar::Int(1), Scalar::Int(2))))
  let struct_d = DataType::Struct(fields2())
  assert_false(struct_d.fits_value(int_list([1])))
  // A struct fits when its names spell the dtype's in order and every
  // present value fits its field.
  assert_true(struct_d.fits_value(sv(Scalar::Int(1), Scalar::Int(2))))
  assert_true(struct_d.fits_value(sv(Null, Scalar::Int(2))))
  assert_false(struct_d.fits_value(sv(Scalar::String("x"), Scalar::Int(2))))
  // Another name in a position, or another width.
  let renamed = Scalar::Struct(
    StructValue::StructValue([fv("a", Scalar::Int(1)), fv("z", Scalar::Int(2))]),
  )
  assert_false(struct_d.fits_value(renamed))
  let narrow = Scalar::Struct(
    StructValue::StructValue([fv("a", Scalar::Int(1))]),
  )
  assert_false(struct_d.fits_value(narrow))
  let wide = Scalar::Struct(
    StructValue::StructValue([
      fv("a", Scalar::Int(1)),
      fv("b", Scalar::Int(2)),
      fv("c", Scalar::Int(3)),
    ]),
  )
  assert_false(struct_d.fits_value(wide))
  // The shape recurses: a struct field that is itself a list.
  let of_list = DataType::Struct(
    Schema::Schema([
      Field::Field("a", ints),
      Field::Field("b", DataType::String),
    ]),
  )
  assert_true(of_list.fits_value(sv(int_list([7]), Scalar::String("x"))))
  assert_true(of_list.fits_value(sv(lv([]), Scalar::String("x"))))
  assert_false(
    of_list.fits_value(sv(lv([Scalar::String("no")]), Scalar::String("x"))),
  )
}

///|
test "names_types tells a named nested dtype from a placeholder" {
  // Every scalar dtype but Null names types.
  for
    d in [
      DataType::Int,
      DataType::Float,
      DataType::Bool,
      DataType::String,
      DataType::Date,
      DataType::Timestamp,
      DataType::Decimal,
      DataType::Duration,
    ] {
    assert_true(d.names_types())
  }
  assert_false(DataType::Null.names_types())
  // A placeholder: nothing inside it names a real dtype.
  assert_false(DataType::List(DataType::Null).names_types())
  assert_false(DataType::List(DataType::List(DataType::Null)).names_types())
  assert_false(
    DataType::Struct(Schema::Schema([Field::Field("a", DataType::Null)])).names_types(),
  )
  assert_false(DataType::Struct(Schema::Schema([])).names_types())
  // Named: a real element dtype, or one real field among nulls.
  assert_true(DataType::List(DataType::Int).names_types())
  assert_true(
    DataType::Struct(
      Schema::Schema([
        Field::Field("a", DataType::Null),
        Field::Field("b", DataType::Int),
      ]),
    ).names_types(),
  )
}

///|
test "a list inside a list and a struct inside a list render at depth" {
  // The nested-cell spelling recurses through both shapes.
  assert_eq(
    lv([
      sv(Scalar::Int(1), Scalar::String("x")),
      int_list([2]),
      lv([]),
      lv([Null]),
    ]).to_string(),
    "[{\"a\": 1, \"b\": \"x\"}, [2], [], [null]]",
  )
  // A struct whose field is itself a struct.
  let inner = sv(Scalar::Int(1), Scalar::Int(2))
  let outer = Scalar::Struct(
    StructValue::StructValue([fv("a", inner), fv("b", Scalar::Bool(true))]),
  )
  assert_eq(outer.to_string(), "{\"a\": {\"a\": 1, \"b\": 2}, \"b\": true}")
}

///|
test "a nested value names a dtype, or leaves a position unnamed" {
  // Scalars name their own dtype; a null names nothing.
  assert_eq(Scalar::Int(1).named_dtype(), Some(DataType::Int))
  assert_eq(Scalar::Null.named_dtype(), None)
  // A list names the dtype its first naming element names — an empty
  // list or a null ahead of it is passed over.
  let ints_d = DataType::List(DataType::Int)
  assert_eq(int_list([1]).named_dtype(), Some(ints_d))
  assert_eq(lv([Null, Scalar::Int(1)]).named_dtype(), Some(ints_d))
  assert_eq(
    lv([lv([]), int_list([2])]).named_dtype(),
    Some(DataType::List(ints_d)),
  )
  // Nothing naming: empty, nulls, and nested values that name nothing.
  assert_eq(lv([]).named_dtype(), None)
  assert_eq(lv([Null]).named_dtype(), None)
  assert_eq(lv([lv([])]).named_dtype(), None)
  // The element dtype follows the same rule: the first naming element.
  assert_eq(lv([lv([]), int_list([2])]).dtype(), DataType::List(ints_d))
  assert_eq(
    lv([Null, Scalar::String("x")]).dtype(),
    DataType::List(DataType::String),
  )
  assert_eq(lv([]).dtype(), DataType::List(DataType::Null))
  // A struct names its dtype only when every field names one.
  assert_eq(
    sv(Scalar::Int(1), Scalar::String("x")).named_dtype(),
    Some(
      DataType::Struct(
        Schema::Schema([
          Field::Field("a", DataType::Int),
          Field::Field("b", DataType::String),
        ]),
      ),
    ),
  )
  // A struct's value names nothing when a field is null or unnamed.
  assert_eq(sv(Scalar::Int(1), Null).named_dtype(), None)
  assert_eq(sv(Scalar::Int(1), lv([])).named_dtype(), None)
  let bare = Scalar::Struct(StructValue::StructValue([])).named_dtype()
  assert_eq(bare, Some(DataType::Struct(Schema::Schema([]))))
  // A repeated field name spells no schema, so the value names nothing.
  let repeated = Scalar::Struct(
    StructValue::StructValue([fv("a", Scalar::Int(1)), fv("a", Scalar::Int(2))]),
  )
  assert_eq(repeated.named_dtype(), None)
  // A list of structs names the list of that struct dtype.
  let one = sv(Scalar::Int(1), Scalar::String("x"))
  let of_structs = lv([one]).named_dtype()
  assert_eq(of_structs, Some(DataType::List(one.named_dtype().unwrap())))
}
