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
/// Unified error type for all MoonFrame operations.
pub(all) suberror DataError {
  ColumnNotFound(String)
  DuplicateColumn(String)
  TypeMismatch(String)
  /// A dtype mismatch with the pieces kept structured rather than
  /// pre-formatted — `(expected, got, column)`, where `column` is `""` when the
  /// mismatch is not tied to a named column. The programmable form of
  /// `TypeMismatch` for the "expected T, got X" family; `message()` rebuilds the
  /// exact `TypeMismatch` wording, so migrating a site is display-compatible
  /// while callers can now read the dtypes and column directly. The bare
  /// `TypeMismatch(String)` stays for the messages this shape does not fit.
  TypedMismatch(DataType, DataType, String)
  /// A raw column-buffer accessor received the wrong column dtype. The two
  /// fields are `(expected, got)`; `message()` preserves the historical
  /// `expected T column, got X` wording while exposing both dtypes directly.
  ColumnTypeMismatch(DataType, DataType)
  /// A binary operation rejected its operand dtypes. The fields are
  /// `(operation, left, right)`; `message()` preserves the historical
  /// `cannot <operation> <left> and <right>` wording.
  OpTypeMismatch(String, DataType, DataType)
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
    TypeMismatch(detail) => "Type mismatch: \{detail}"
    // Rebuild the exact `TypeMismatch` detail: with no column it is
    // `expected T, got X`; a named column prefixes `column "name" `.
    TypedMismatch(expected, got, column) =>
      if column == "" {
        "Type mismatch: expected \{expected}, got \{got}"
      } else {
        "Type mismatch: column \"\{column}\" expected \{expected}, got \{got}"
      }
    ColumnTypeMismatch(expected, got) =>
      "Type mismatch: expected \{expected} column, got \{got}"
    OpTypeMismatch(operation, left, right) =>
      "Type mismatch: cannot \{operation} \{left} and \{right}"
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
      logger.write_string("ColumnNotFound(\"\{escape_debug(name)}\")")
    DuplicateColumn(name) =>
      logger.write_string("DuplicateColumn(\"\{escape_debug(name)}\")")
    TypeMismatch(detail) =>
      logger.write_string("TypeMismatch(\"\{escape_debug(detail)}\")")
    TypedMismatch(expected, got, column) =>
      logger.write_string(
        "TypedMismatch(\{expected}, \{got}, \"\{escape_debug(column)}\")",
      )
    ColumnTypeMismatch(expected, got) =>
      logger.write_string("ColumnTypeMismatch(\{expected}, \{got})")
    OpTypeMismatch(operation, left, right) =>
      logger.write_string(
        "OpTypeMismatch(\"\{escape_debug(operation)}\", \{left}, \{right})",
      )
    LengthMismatch => logger.write_string("LengthMismatch")
    IndexOutOfBounds(i) => logger.write_string("IndexOutOfBounds(\{i})")
    ParseError(detail) =>
      match detail {
        Message(message) =>
          logger.write_string(
            "ParseError(Message(\"\{escape_debug(message)}\"))",
          )
        Cell(location, column, position, expected, value) => {
          let location_name = match location {
            Row => "Row"
            Record => "Record"
            Line => "Line"
          }
          logger.write_string(
            "ParseError(Cell(\{location_name}, \"\{escape_debug(column)}\", \{position}, \{expected}, \"\{escape_debug(value)}\"))",
          )
        }
      }
    InvalidOperation(detail) =>
      logger.write_string("InvalidOperation(\"\{escape_debug(detail)}\")")
    IoError(detail) =>
      logger.write_string("IoError(\"\{escape_debug(detail)}\")")
    Unsupported(detail) =>
      logger.write_string("Unsupported(\"\{escape_debug(detail)}\")")
    NullInNonNullable(name) =>
      logger.write_string("NullInNonNullable(\"\{escape_debug(name)}\")")
  }
}
