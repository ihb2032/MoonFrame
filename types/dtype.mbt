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
pub fn DataType::is_integer(self : DataType) -> Bool {
  match self {
    Int => true
    _ => false
  }
}

///|
pub fn DataType::is_float(self : DataType) -> Bool {
  match self {
    Float => true
    _ => false
  }
}

///|
/// `true` for `Int` and `Float` — both are usable in numeric reductions.
pub fn DataType::is_numeric(self : DataType) -> Bool {
  match self {
    Int | Float => true
    _ => false
  }
}

///|
pub fn DataType::is_bool(self : DataType) -> Bool {
  match self {
    Bool => true
    _ => false
  }
}

///|
pub fn DataType::is_string(self : DataType) -> Bool {
  match self {
    String => true
    _ => false
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
