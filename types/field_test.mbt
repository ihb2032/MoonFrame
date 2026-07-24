// The bare `Field(...)` spelling resolves wherever the expected type is
// concrete — inside `Schema::Schema([...])`, an annotated binding, a typed array
// literal (see `schema_test.mbt`). These tests bind fields on their own or
// hand them to the generic `assert_eq` / `inspect`, where no expected type is
// available, so they use the fully qualified `Field::Field(...)` form.

///|
test "Field defaults to nullable" {
  let f : Field = Field("age", DataType::Int)
  assert_eq(f.name(), "age")
  assert_eq(f.dtype(), DataType::Int)
  assert_true(f.nullable())
}

///|
test "Field honours an explicit nullable flag" {
  let f : Field = Field("id", DataType::Int, nullable=false)
  assert_eq(f.name(), "id")
  assert_false(f.nullable())
  let g : Field = Field("note", DataType::String, nullable=true)
  assert_true(g.nullable())
}

///|
test "Field::rename returns a new field, leaves the source intact" {
  let original : Field = Field("a", DataType::Float)
  let renamed = original.rename("b")
  assert_eq(renamed.name(), "b")
  assert_eq(renamed.dtype(), DataType::Float)
  assert_eq(renamed.nullable(), original.nullable())
  assert_eq(original.name(), "a")
}

///|
test "Field equality is structural" {
  assert_eq(
    Field::Field("x", DataType::Int, nullable=false),
    Field::Field("x", DataType::Int, nullable=false),
  )
  assert_not_eq(
    Field::Field("x", DataType::Int),
    Field::Field("y", DataType::Int),
  )
  assert_not_eq(
    Field::Field("x", DataType::Int),
    Field::Field("x", DataType::Float),
  )
  assert_not_eq(
    Field::Field("x", DataType::Int, nullable=true),
    Field::Field("x", DataType::Int, nullable=false),
  )
}

///|
test "Field Show uses struct form" {
  inspect(
    Field::Field("age", DataType::Int),
    content="Field { name: \"age\", dtype: Int, nullable: true }",
  )
  inspect(
    Field::Field("id", DataType::String, nullable=false),
    content="Field { name: \"id\", dtype: String, nullable: false }",
  )
}

///|
test "Field Show escapes quotes and backslashes in the name" {
  // The struct form quotes the name, so a `"` / `\` in it is escaped.
  inspect(
    Field::Field("a\"b", DataType::Int),
    content="Field { name: \"a\\\"b\", dtype: Int, nullable: true }",
  )
}
