///|
/// Logical data type for a column.
///
/// `Null` represents a column that carries no inferred type (e.g. an
/// all-null CSV column where inference could not promote it to anything
/// more specific). Concrete columns always carry one of the other variants.
pub(all) enum DataType {
  Int
  Float
  Bool
  String
  Null
} derive(Eq, Debug)

///|
pub extend DataType with Eq::{equal, not_equal}

///|
pub extend DataType with Show::{to_string, output}

///|
pub extend DataType with Debug::{to_repr}

///|
/// `true` only for the `Int` variant.
pub fn DataType::is_integer(self : DataType) -> Bool {
  self is Int
}

///|
/// `true` only for the `Float` variant.
pub fn DataType::is_float(self : DataType) -> Bool {
  self is Float
}

///|
/// `true` for `Int` and `Float` — both are usable in numeric reductions.
pub fn DataType::is_numeric(self : DataType) -> Bool {
  self is Int || self is Float
}

///|
/// `true` only for the `Bool` variant.
pub fn DataType::is_bool(self : DataType) -> Bool {
  self is Bool
}

///|
/// `true` only for the `String` variant.
pub fn DataType::is_string(self : DataType) -> Bool {
  self is String
}

///|
pub impl Show for DataType with fn output(self, logger) {
  let name = match self {
    Int => "Int"
    Float => "Float"
    Bool => "Bool"
    String => "String"
    Null => "Null"
  }
  logger.write_string(name)
}
