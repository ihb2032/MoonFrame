///|
/// Column metadata: a name, the column's logical `DataType`, and a declared
/// `nullable` flag.
///
/// `nullable = false` is a declared constraint that `DataFrame::from_rows`
/// enforces: row data placing a `Scalar::Null` in such a column `raise`s
/// `NullInNonNullable(name)`. (`DataFrame::empty` builds 0-row columns, so it
/// can never violate the constraint.) The flag is otherwise advisory — it is
/// neither inferred from a column's contents nor propagated across operations:
/// `Field::new` (and so `DataFrame::new`, the IO readers, and the ops that
/// rebuild through them) always sets `nullable = true`, so a `nullable = false`
/// field only ever originates from an explicit
/// `Field::with_nullable(..., false)` in a caller-supplied schema.
pub(all) struct Field {
  name : String
  dtype : DataType
  nullable : Bool
} derive(Eq, Debug)

///|
/// Build a field with `nullable = true` (the common default for inferred
/// CSV / JSON columns).
pub fn Field::new(name : String, dtype : DataType) -> Field {
  { name, dtype, nullable: true }
}

///|
/// Build a field with an explicit nullability flag.
pub fn Field::with_nullable(
  name : String,
  dtype : DataType,
  nullable : Bool,
) -> Field {
  { name, dtype, nullable }
}

///|
pub fn Field::name(self : Field) -> String {
  self.name
}

///|
pub fn Field::dtype(self : Field) -> DataType {
  self.dtype
}

///|
pub fn Field::nullable(self : Field) -> Bool {
  self.nullable
}

///|
/// Return a copy of this field with a new name.
pub fn Field::rename(self : Field, new_name : String) -> Field {
  { ..self, name: new_name }
}

///|
/// `Show` renders the struct form (`Field { name: "age", dtype: Int,
/// nullable: true }`), useful for assertion snapshots.
pub impl Show for Field with fn output(self, logger) {
  logger.write_string("Field { name: \"")
  logger.write_string(escape_debug(self.name))
  logger.write_string("\", dtype: ")
  self.dtype.output(logger)
  logger.write_string(", nullable: ")
  logger.write_string(self.nullable.to_string())
  logger.write_string(" }")
}
