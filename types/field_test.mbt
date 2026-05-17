///|
test "Field::new defaults to nullable" {
  let f = Field::new("age", DataType::Int)
  assert_eq(f.name(), "age")
  assert_eq(f.dtype(), DataType::Int)
  assert_true(f.nullable())
}

///|
test "Field::with_nullable honours the flag" {
  let f = Field::with_nullable("id", DataType::Int, false)
  assert_eq(f.name(), "id")
  assert_false(f.nullable())
  let g = Field::with_nullable("note", DataType::String, true)
  assert_true(g.nullable())
}

///|
test "Field::rename returns a new field, leaves the source intact" {
  let original = Field::new("a", DataType::Float)
  let renamed = original.rename("b")
  assert_eq(renamed.name(), "b")
  assert_eq(renamed.dtype(), DataType::Float)
  assert_eq(renamed.nullable(), original.nullable())
  assert_eq(original.name(), "a")
}

///|
test "Field equality is structural" {
  assert_eq(
    Field::with_nullable("x", DataType::Int, false),
    Field::with_nullable("x", DataType::Int, false),
  )
  assert_not_eq(Field::new("x", DataType::Int), Field::new("y", DataType::Int))
  assert_not_eq(
    Field::new("x", DataType::Int),
    Field::new("x", DataType::Float),
  )
  assert_not_eq(
    Field::with_nullable("x", DataType::Int, true),
    Field::with_nullable("x", DataType::Int, false),
  )
}

///|
test "Field Show uses struct form" {
  inspect(
    Field::new("age", DataType::Int),
    content="Field { name: \"age\", dtype: Int, nullable: true }",
  )
  inspect(
    Field::with_nullable("id", DataType::String, false),
    content="Field { name: \"id\", dtype: String, nullable: false }",
  )
}
