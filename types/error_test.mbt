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
    DataError::TypeMismatch(
      TypeMismatchDetail::Message("expected Int, got String"),
    ).message(),
    content="Type mismatch: expected Int, got String",
  )
  // `Expected` rebuilds the same wording from its structured fields: with no
  // column the bare "expected T, got X", and with one the `column "n" ` prefix.
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Expected(DataType::Int, DataType::Null, ""),
    ).message(),
    content="Type mismatch: expected Int, got Null",
  )
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Expected(DataType::Int, DataType::Float, "age"),
    ).message(),
    content="Type mismatch: column \"age\" expected Int, got Float",
  )
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Column(DataType::Int, DataType::Float),
    ).message(),
    content="Type mismatch: expected Int column, got Float",
  )
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Operation(
        "take the remainder of",
        DataType::String,
        DataType::Int,
      ),
    ).message(),
    content="Type mismatch: cannot take the remainder of String and Int",
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
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Row,
        "score",
        3,
        DataType::Int,
        "oops",
      ),
    ).message(),
    content="Parse error: column \"score\" row 3: cannot parse \"oops\" as Int",
  )
  inspect(
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Record,
        "score",
        4,
        DataType::Float,
        "oops",
      ),
    ).message(),
    content="Parse error: column \"score\" record 4: JSON value is not a number (\"oops\")",
  )
  inspect(
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Record,
        "score",
        4,
        DataType::Int,
        "oops",
      ),
    ).message(),
    content="Parse error: column \"score\" record 4: JSON value is not an Int (\"oops\")",
  )
  inspect(
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Line,
        "active",
        5,
        DataType::Bool,
        "1",
      ),
    ).message(),
    content="Parse error: column \"active\" line 5: JSON value is not a Bool (\"1\")",
  )
  inspect(
    DataError::ParseError(ParseErrorDetail::Message("bad row")).message(),
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
  inspect(
    DataError::Unsupported("Arrow backend").message(),
    content="Unsupported: Arrow backend",
  )
  inspect(
    DataError::NullInNonNullable("note").message(),
    content="Null in non-nullable column: note",
  )
}

///|
test "DataError equality is structural" {
  assert_eq(DataError::ColumnNotFound("age"), DataError::ColumnNotFound("age"))
  assert_not_eq(
    DataError::ColumnNotFound("age"),
    DataError::ColumnNotFound("name"),
  )
  assert_not_eq(DataError::LengthMismatch, DataError::IndexOutOfBounds(0))
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
    DataError::TypeMismatch(
      TypeMismatchDetail::Message("expected Int, got String"),
    ),
    content="TypeMismatch(Message(\"expected Int, got String\"))",
  )
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Expected(DataType::Int, DataType::Null, ""),
    ),
    content="TypeMismatch(Expected(Int, Null, \"\"))",
  )
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Column(DataType::Int, DataType::Float),
    ),
    content="TypeMismatch(Column(Int, Float))",
  )
  inspect(
    DataError::TypeMismatch(
      TypeMismatchDetail::Operation("add", DataType::String, DataType::Int),
    ),
    content="TypeMismatch(Operation(\"add\", String, Int))",
  )
  inspect(
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Line,
        "a\"b",
        5,
        DataType::Bool,
        "path\\x",
      ),
    ),
    content="ParseError(Cell(Line, \"a\\\"b\", 5, Bool, \"path\\\\x\"))",
  )
  inspect(
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Row,
        "score",
        3,
        DataType::Int,
        "oops",
      ),
    ),
    content="ParseError(Cell(Row, \"score\", 3, Int, \"oops\"))",
  )
  inspect(
    DataError::ParseError(
      ParseErrorDetail::Cell(
        CellParseLocation::Record,
        "score",
        4,
        DataType::Float,
        "oops",
      ),
    ),
    content="ParseError(Cell(Record, \"score\", 4, Float, \"oops\"))",
  )
  inspect(
    DataError::ParseError(ParseErrorDetail::Message("bad token")),
    content="ParseError(Message(\"bad token\"))",
  )
  inspect(
    DataError::InvalidOperation("mean of String column"),
    content="InvalidOperation(\"mean of String column\")",
  )
  inspect(
    DataError::IoError("file not found"),
    content="IoError(\"file not found\")",
  )
  inspect(
    DataError::Unsupported("Arrow backend"),
    content="Unsupported(\"Arrow backend\")",
  )
  inspect(
    DataError::NullInNonNullable("note"),
    content="NullInNonNullable(\"note\")",
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
  inspect(
    DataError::ParseError(ParseErrorDetail::Message("path\\x")),
    content="ParseError(Message(\"path\\\\x\"))",
  )
}
