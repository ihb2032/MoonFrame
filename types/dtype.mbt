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
/// The physical storage this logical type materialises into, or `None` for
/// `Null` — the one logical type with **no** physical backing, so a
/// `Null`-dtype column cannot be built (`DataFrame::empty` / `from_rows` reject
/// it, and a bare `Null` literal has no dtype witness at evaluation). The four
/// concrete types map one-to-one today; the indirection is what a future
/// logical type reusing an existing buffer — a `Date` or `Datetime` as `I64`, a
/// small `Decimal` as `I64` — would consume instead of adding a new physical
/// column kind (see `PhysicalType`).
pub fn DataType::physical(self : DataType) -> PhysicalType? {
  match self {
    Int => Some(PhysicalType::I64)
    Float => Some(PhysicalType::F64)
    Bool => Some(PhysicalType::Bool)
    String => Some(PhysicalType::Utf8)
    Null => None
  }
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
