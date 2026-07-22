///|
/// Identifies how a typed cell's 1-based source position is reported.
/// `Row` is used by CSV, `Record` by JSON arrays, and `Line` by NDJSON.
pub(all) enum CellParseLocation {
  Row
  Record
  Line
} derive(Eq, Debug)

///|
pub extend CellParseLocation with Eq::{equal, not_equal}

///|
pub extend CellParseLocation with Debug::{to_repr}

///|
/// Structured details carried by `DataError::ParseError`.
pub(all) enum ParseErrorDetail {
  /// A parser or shape diagnostic that does not have a shared typed shape.
  Message(String)
  /// A non-null cell did not fit the dtype locked in during inference. Fields
  /// are `(location, column, position, expected, value)`; `position` is
  /// 1-based and its meaning is carried by `location`.
  Cell(CellParseLocation, String, Int, DataType, String)
} derive(Eq, Debug)

///|
pub extend ParseErrorDetail with Eq::{equal, not_equal}

///|
pub extend ParseErrorDetail with Debug::{to_repr}

///|
/// Structured details carried by `DataError::TypeMismatch`.
pub(all) enum TypeMismatchDetail {
  /// A dtype diagnostic that does not have a shared typed shape.
  Message(String)
  /// A value had the wrong dtype. Fields are `(expected, got, column)`, where
  /// `column` is empty when the mismatch is not tied to a named column.
  Expected(DataType, DataType, String)
  /// A raw column-buffer accessor received the wrong dtype. Fields are
  /// `(expected, got)`.
  Column(DataType, DataType)
  /// A binary operation rejected its operands. Fields are
  /// `(operation, left, right)`.
  Operation(String, DataType, DataType)
} derive(Eq, Debug)

///|
pub extend TypeMismatchDetail with Eq::{equal, not_equal}

///|
pub extend TypeMismatchDetail with Debug::{to_repr}

///|
/// Unified error type for all MoonFrame operations.
pub(all) suberror DataError {
  ColumnNotFound(String)
  DuplicateColumn(String)
  TypeMismatch(TypeMismatchDetail)
  LengthMismatch
  IndexOutOfBounds(Int)
  ParseError(ParseErrorDetail)
  InvalidOperation(String)
  IoError(String)
  Unsupported(String)
  NullInNonNullable(String)
} derive(Eq, Debug)

///|
pub extend DataError with Eq::{equal, not_equal}

///|
pub extend DataError with Show::{to_string, output}

///|
pub extend DataError with Debug::{to_repr}

///|
fn json_cell_expectation(expected : DataType) -> String {
  match expected {
    Int => "an Int"
    Float => "a number"
    dtype => "a \{dtype}"
  }
}

///|
/// Human-readable message describing the error.
pub fn DataError::message(self : DataError) -> String {
  match self {
    ColumnNotFound(name) => "Column not found: \{name}"
    DuplicateColumn(name) => "Duplicate column: \{name}"
    TypeMismatch(detail) =>
      match detail {
        Message(message) => "Type mismatch: \{message}"
        Expected(expected, got, column) =>
          if column == "" {
            "Type mismatch: expected \{expected}, got \{got}"
          } else {
            "Type mismatch: column \"\{column}\" expected \{expected}, got \{got}"
          }
        Column(expected, got) =>
          "Type mismatch: expected \{expected} column, got \{got}"
        Operation(operation, left, right) =>
          "Type mismatch: cannot \{operation} \{left} and \{right}"
      }
    LengthMismatch => "Length mismatch between columns"
    IndexOutOfBounds(i) => "Index out of bounds: \{i}"
    ParseError(detail) =>
      match detail {
        Message(message) => "Parse error: \{message}"
        Cell(location, column, position, expected, value) =>
          match location {
            Row =>
              "Parse error: column \"\{column}\" row \{position}: cannot parse \"\{value}\" as \{expected}"
            Record => {
              let expectation = json_cell_expectation(expected)
              "Parse error: column \"\{column}\" record \{position}: JSON value is not \{expectation} (\"\{value}\")"
            }
            Line => {
              let expectation = json_cell_expectation(expected)
              "Parse error: column \"\{column}\" line \{position}: JSON value is not \{expectation} (\"\{value}\")"
            }
          }
      }
    InvalidOperation(detail) => "Invalid operation: \{detail}"
    IoError(detail) => "I/O error: \{detail}"
    Unsupported(detail) => "Unsupported: \{detail}"
    NullInNonNullable(name) => "Null in non-nullable column: \{name}"
  }
}

///|
/// `Show` renders the variant form (`ColumnNotFound("age")`), useful for
/// assertions and snapshots. The user-facing description is `message()`.
pub impl Show for DataError with fn output(self, logger) {
  match self {
    ColumnNotFound(name) =>
      logger.write_string("ColumnNotFound(\"\{@text.escape_debug(name)}\")")
    DuplicateColumn(name) =>
      logger.write_string("DuplicateColumn(\"\{@text.escape_debug(name)}\")")
    TypeMismatch(detail) =>
      match detail {
        Message(message) =>
          logger.write_string(
            "TypeMismatch(Message(\"\{@text.escape_debug(message)}\"))",
          )
        Expected(expected, got, column) =>
          logger.write_string(
            "TypeMismatch(Expected(\{expected}, \{got}, \"\{@text.escape_debug(column)}\"))",
          )
        Column(expected, got) =>
          logger.write_string("TypeMismatch(Column(\{expected}, \{got}))")
        Operation(operation, left, right) =>
          logger.write_string(
            "TypeMismatch(Operation(\"\{@text.escape_debug(operation)}\", \{left}, \{right}))",
          )
      }
    LengthMismatch => logger.write_string("LengthMismatch")
    IndexOutOfBounds(i) => logger.write_string("IndexOutOfBounds(\{i})")
    ParseError(detail) =>
      match detail {
        Message(message) =>
          logger.write_string(
            "ParseError(Message(\"\{@text.escape_debug(message)}\"))",
          )
        Cell(location, column, position, expected, value) => {
          let location_name = match location {
            Row => "Row"
            Record => "Record"
            Line => "Line"
          }
          logger.write_string(
            "ParseError(Cell(\{location_name}, \"\{@text.escape_debug(column)}\", \{position}, \{expected}, \"\{@text.escape_debug(value)}\"))",
          )
        }
      }
    InvalidOperation(detail) =>
      logger.write_string("InvalidOperation(\"\{@text.escape_debug(detail)}\")")
    IoError(detail) =>
      logger.write_string("IoError(\"\{@text.escape_debug(detail)}\")")
    Unsupported(detail) =>
      logger.write_string("Unsupported(\"\{@text.escape_debug(detail)}\")")
    NullInNonNullable(name) =>
      logger.write_string("NullInNonNullable(\"\{@text.escape_debug(name)}\")")
  }
}
