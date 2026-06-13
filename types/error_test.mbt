///|
test "DataError::message covers every variant" {
  inspect(
    DataError::ColumnNotFound("age").message(),
    content="Column not found: age",
  )
  inspect(
    DataError::DuplicateColumn("name").message(),
    content="Duplicate column: name",
  )
  inspect(
    DataError::TypeMismatch("expected Int, got String").message(),
    content="Type mismatch: expected Int, got String",
  )
  inspect(
    DataError::LengthMismatch.message(),
    content="Length mismatch between columns",
  )
  inspect(
    DataError::IndexOutOfBounds(10).message(),
    content="Index out of bounds: 10",
  )
  inspect(
    DataError::ParseError("bad row").message(),
    content="Parse error: bad row",
  )
  inspect(
    DataError::InvalidOperation("mean of String column").message(),
    content="Invalid operation: mean of String column",
  )
  inspect(
    DataError::IoError("file not found").message(),
    content="I/O error: file not found",
  )
  inspect(DataError::EmptyDataFrame.message(), content="DataFrame is empty")
  inspect(
    DataError::Unsupported("Arrow backend").message(),
    content="Unsupported: Arrow backend",
  )
}

///|
test "DataError equality is structural" {
  assert_eq(DataError::ColumnNotFound("age"), DataError::ColumnNotFound("age"))
  assert_not_eq(
    DataError::ColumnNotFound("age"),
    DataError::ColumnNotFound("name"),
  )
  assert_not_eq(DataError::LengthMismatch, DataError::EmptyDataFrame)
  assert_eq(DataError::IndexOutOfBounds(5), DataError::IndexOutOfBounds(5))
}

///|
test "DataError Show uses variant form" {
  inspect(DataError::ColumnNotFound("age"), content="ColumnNotFound(\"age\")")
  inspect(DataError::LengthMismatch, content="LengthMismatch")
  inspect(DataError::IndexOutOfBounds(3), content="IndexOutOfBounds(3)")
}

///|
test "DataError Show covers every remaining variant" {
  inspect(DataError::DuplicateColumn("x"), content="DuplicateColumn(\"x\")")
  inspect(
    DataError::TypeMismatch("expected Int, got String"),
    content="TypeMismatch(\"expected Int, got String\")",
  )
  inspect(
    DataError::ParseError("bad token"),
    content="ParseError(\"bad token\")",
  )
  inspect(
    DataError::InvalidOperation("mean of String column"),
    content="InvalidOperation(\"mean of String column\")",
  )
  inspect(
    DataError::IoError("file not found"),
    content="IoError(\"file not found\")",
  )
  inspect(DataError::EmptyDataFrame, content="EmptyDataFrame")
  inspect(
    DataError::Unsupported("Arrow backend"),
    content="Unsupported(\"Arrow backend\")",
  )
}

///|
test "DataError Show escapes quotes and backslashes in the payload" {
  // A payload carrying a `"` (e.g. a column name) or `\` is escaped inside
  // the quoted variant form so the rendering stays unambiguous.
  inspect(
    DataError::ColumnNotFound("a\"b"),
    content="ColumnNotFound(\"a\\\"b\")",
  )
  inspect(DataError::ParseError("path\\x"), content="ParseError(\"path\\\\x\")")
}
