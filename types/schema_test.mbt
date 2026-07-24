///|
fn sample_schema() -> Schema raise DataError {
  Schema::Schema([
    Field::Field("a", DataType::Int),
    Field::Field("b", DataType::Float),
    Field::Field("c", DataType::String),
  ])
}

///|
test "Schema::Schema accepts unique fields" {
  let s = sample_schema()
  assert_eq(s.len(), 3)
  assert_false(s.is_empty())
  assert_eq(s.field_names(), ["a", "b", "c"])
}

///|
test "Schema::Schema copies its input fields array" {
  let fields : Array[Field] = [Field::Field("a", DataType::Int)]
  let s = Schema::Schema(fields)
  // Would break the validated no-duplicates invariant if the array were aliased.
  fields.push(Field::Field("a", DataType::Float))
  assert_eq(s.len(), 1)
  assert_eq(s.field_names(), ["a"])
}

///|
test "Schema::Schema rejects duplicate names" {
  let dup = Ok(
    Schema::Schema([
      Field::Field("a", DataType::Int),
      Field::Field("b", DataType::Float),
      Field::Field("a", DataType::String),
    ]),
  ) catch {
    e => Err(e)
  }
  assert_eq(dup, Err(DataError::DuplicateColumn("a")))
}

///|
test "Schema::Schema on empty input is Ok" {
  let s = Schema::Schema([])
  assert_true(s.is_empty())
  assert_eq(s.len(), 0)
  assert_eq(s.field_names(), [])
}

///|
test "Schema::index_of / field / field_at" {
  let s = sample_schema()
  assert_eq(s.index_of("a"), 0)
  assert_eq(s.index_of("c"), 2)
  assert_eq(
    Ok(s.index_of("missing")) catch {
      e => Err(e)
    },
    Err(DataError::ColumnNotFound("missing")),
  )
  assert_eq(s.field("b"), Field::Field("b", DataType::Float))
  assert_eq(
    Ok(s.field("missing")) catch {
      e => Err(e)
    },
    Err(DataError::ColumnNotFound("missing")),
  )
  assert_eq(s.field_at(0), Field::Field("a", DataType::Int))
  assert_eq(
    Ok(s.field_at(3)) catch {
      e => Err(e)
    },
    Err(DataError::IndexOutOfBounds(3)),
  )
  assert_eq(
    Ok(s.field_at(-1)) catch {
      e => Err(e)
    },
    Err(DataError::IndexOutOfBounds(-1)),
  )
}

///|
test "Schema::select projects in requested order" {
  let s = sample_schema()
  let sub = s.select(["c", "a"])
  assert_eq(sub.field_names(), ["c", "a"])
  assert_eq(sub.field_at(0), Field::Field("c", DataType::String))
}

///|
test "Schema::select on empty list returns empty schema" {
  let s = sample_schema()
  let sub = s.select([])
  assert_true(sub.is_empty())
}

///|
test "Schema::select rejects missing columns" {
  let s = sample_schema()
  assert_eq(
    Ok(s.select(["a", "z"])) catch {
      e => Err(e)
    },
    Err(DataError::ColumnNotFound("z")),
  )
}

///|
test "Schema::select rejects duplicate picks" {
  let s = sample_schema()
  assert_eq(
    Ok(s.select(["a", "a"])) catch {
      e => Err(e)
    },
    Err(DataError::DuplicateColumn("a")),
  )
}

///|
test "Schema::rename happy path" {
  let s = sample_schema()
  let renamed = s.rename("b", "bb")
  assert_eq(renamed.field_names(), ["a", "bb", "c"])
  assert_eq(renamed.field_at(1), Field::Field("bb", DataType::Float))
  // Original is unchanged.
  assert_eq(s.field_names(), ["a", "b", "c"])
}

///|
test "Schema::rename to same name is a no-op but validates existence" {
  let s = sample_schema()
  assert_eq(s.rename("a", "a").field_names(), ["a", "b", "c"])
  assert_eq(
    Ok(s.rename("missing", "missing")) catch {
      e => Err(e)
    },
    Err(DataError::ColumnNotFound("missing")),
  )
}

///|
test "Schema::rename rejects missing source" {
  let s = sample_schema()
  assert_eq(
    Ok(s.rename("z", "zz")) catch {
      e => Err(e)
    },
    Err(DataError::ColumnNotFound("z")),
  )
}

///|
test "Schema::rename rejects collision with existing column" {
  let s = sample_schema()
  assert_eq(
    Ok(s.rename("a", "b")) catch {
      e => Err(e)
    },
    Err(DataError::DuplicateColumn("b")),
  )
}

///|
test "Schema equality is structural" {
  assert_eq(sample_schema(), sample_schema())
  let other = Schema::Schema([
    Field::Field("a", DataType::Int),
    Field::Field("b", DataType::Float),
  ])
  assert_not_eq(sample_schema(), other)
}

///|
test "Schema Show renders fields in order" {
  let s = Schema::Schema([
    Field::Field("x", DataType::Int),
    Field::Field("y", DataType::String, nullable=false),
  ])
  inspect(
    s,
    content="Schema([Field { name: \"x\", dtype: Int, nullable: true }, Field { name: \"y\", dtype: String, nullable: false }])",
  )
}

///|
test "Schema::fields returns a snapshot, mutating it does not break the schema" {
  let s = sample_schema()
  let copy = s.fields()
  assert_eq(copy.length(), 3)
  assert_eq(copy[0].name(), "a")
  // Mutate the returned array; the schema must remain intact.
  copy.push(Field::Field("a", DataType::Float))
  assert_eq(copy.length(), 4)
  assert_eq(s.len(), 3)
  assert_eq(s.field_names(), ["a", "b", "c"])
}
