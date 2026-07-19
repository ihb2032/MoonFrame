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
  /// `TypeMismatch(String)` stays for the messages this shape does not fit
  /// (`cannot compare …`, operator mismatches).
  TypedMismatch(DataType, DataType, String)
  /// A raw column-buffer accessor received the wrong column dtype. The two
  /// fields are `(expected, got)`; `message()` preserves the historical
  /// `expected T column, got X` wording while exposing both dtypes directly.
  ColumnTypeMismatch(DataType, DataType)
  LengthMismatch
  IndexOutOfBounds(Int)
  ParseError(String)
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
    LengthMismatch => "Length mismatch between columns"
    IndexOutOfBounds(i) => "Index out of bounds: \{i}"
    ParseError(detail) => "Parse error: \{detail}"
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
    LengthMismatch => logger.write_string("LengthMismatch")
    IndexOutOfBounds(i) => logger.write_string("IndexOutOfBounds(\{i})")
    ParseError(detail) =>
      logger.write_string("ParseError(\"\{escape_debug(detail)}\")")
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
