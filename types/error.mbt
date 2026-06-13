///|
/// Unified error type for all MoonFrame operations.
pub(all) suberror DataError {
  ColumnNotFound(String)
  DuplicateColumn(String)
  TypeMismatch(String)
  LengthMismatch
  IndexOutOfBounds(Int)
  ParseError(String)
  InvalidOperation(String)
  IoError(String)
  EmptyDataFrame
  Unsupported(String)
} derive(Eq, Debug)

///|
/// Human-readable message describing the error.
pub fn DataError::message(self : DataError) -> String {
  match self {
    ColumnNotFound(name) => "Column not found: " + name
    DuplicateColumn(name) => "Duplicate column: " + name
    TypeMismatch(detail) => "Type mismatch: " + detail
    LengthMismatch => "Length mismatch between columns"
    IndexOutOfBounds(i) => "Index out of bounds: " + i.to_string()
    ParseError(detail) => "Parse error: " + detail
    InvalidOperation(detail) => "Invalid operation: " + detail
    IoError(detail) => "I/O error: " + detail
    EmptyDataFrame => "DataFrame is empty"
    Unsupported(detail) => "Unsupported: " + detail
  }
}

///|
/// `Show` renders the variant form (`ColumnNotFound("age")`), useful for
/// assertions and snapshots. The user-facing description is `message()`.
pub impl Show for DataError with fn output(self, logger) {
  match self {
    ColumnNotFound(name) =>
      logger.write_string("ColumnNotFound(\"" + escape_debug(name) + "\")")
    DuplicateColumn(name) =>
      logger.write_string("DuplicateColumn(\"" + escape_debug(name) + "\")")
    TypeMismatch(detail) =>
      logger.write_string("TypeMismatch(\"" + escape_debug(detail) + "\")")
    LengthMismatch => logger.write_string("LengthMismatch")
    IndexOutOfBounds(i) =>
      logger.write_string("IndexOutOfBounds(" + i.to_string() + ")")
    ParseError(detail) =>
      logger.write_string("ParseError(\"" + escape_debug(detail) + "\")")
    InvalidOperation(detail) =>
      logger.write_string("InvalidOperation(\"" + escape_debug(detail) + "\")")
    IoError(detail) =>
      logger.write_string("IoError(\"" + escape_debug(detail) + "\")")
    EmptyDataFrame => logger.write_string("EmptyDataFrame")
    Unsupported(detail) =>
      logger.write_string("Unsupported(\"" + escape_debug(detail) + "\")")
  }
}
