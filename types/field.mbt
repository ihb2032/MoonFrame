///|
/// Column metadata: a name, the column's logical `DataType`, and a declared
/// `nullable` flag.
///
/// `nullable = false` is a declared constraint that `DataFrame::from_rows`
/// enforces: row data placing a `Scalar::Null` in such a column `raise`s
/// `NullInNonNullable(name)`. (`DataFrame::empty` builds 0-row columns, so it
/// can never violate the constraint.) The flag is otherwise advisory — it is
/// neither inferred from a column's contents nor propagated across operations:
/// the constructor's `nullable` default (and so `DataFrame::new`, the IO
/// readers, and the ops that rebuild through them) always sets
/// `nullable = true`, so a `nullable = false` field only ever originates from
/// an explicit `Field(..., nullable=false)` in a caller-supplied schema.
///
/// The fields are readable but not constructible from outside `types`: build
/// one through `Field(...)`, so a future field can be added without breaking
/// callers.
pub struct Field {
  name : String
  dtype : DataType
  nullable : Bool
} derive(Eq, Debug)

///|
pub extend Field with Eq::{equal, not_equal}

///|
pub extend Field with Show::{to_string, output}

///|
pub extend Field with Debug::{to_repr}

///|
/// Build a field. `nullable` defaults to `true`, the common setting for
/// inferred CSV / JSON columns; pass `nullable=false` to declare the
/// constraint `DataFrame::from_rows` enforces.
#as_free_fn(visibility="pub")
pub fn Field::Field(
  name : String,
  dtype : DataType,
  nullable? : Bool = true,
) -> Field {
  { name, dtype, nullable }
}

///|
/// The column's name.
pub fn Field::name(self : Field) -> String {
  self.name
}

///|
/// The column's logical `DataType`.
pub fn Field::dtype(self : Field) -> DataType {
  self.dtype
}

///|
/// The declared `nullable` flag (see the type doc for how `DataFrame::from_rows`
/// enforces it).
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
  logger.write_string(@text.escape_debug(self.name))
  logger.write_string("\", dtype: ")
  self.dtype.output(logger)
  logger.write_string(", nullable: ")
  logger.write_string(self.nullable.to_string())
  logger.write_string(" }")
}
