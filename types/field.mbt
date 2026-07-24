///|
/// Column metadata: a name, the column's logical `DataType`, and a declared
/// `nullable` flag.
///
/// `nullable = false` is a declared constraint that `DataFrame::from_rows`
/// enforces: row data placing a `Scalar::Null` in such a column `raise`s
/// `NullInNonNullable(name)`. (`DataFrame::empty` builds 0-row columns, so it
/// can never violate the constraint.) The flag is never *inferred* from a
/// column's contents: the constructor's `nullable` default — and so
/// `DataFrame::DataFrame` and the IO readers — always sets `nullable = true`,
/// so a `nullable = false` field only ever originates from an explicit
/// `Field::Field(..., nullable=false)` in a caller-supplied schema.
///
/// Once declared, it travels with the cells it describes. Every operation that
/// *moves* a column carries its field rather than re-deriving one:
/// `Field::rename` (and so `DataFrame::rename` / `rename_with`, which change
/// nothing but the name), `Schema::select` / `Schema::rename`, the row-only
/// frame transforms that reuse their input's schema verbatim (`head` / `tail`
/// / `slice` / `filter` / `sort` / `unique` / `fill_null` / …), and the
/// projections: a `select` or `with_columns` entry that is a bare `col("x")`
/// (or an aliased one, which carries the field renamed), every column `drop`
/// or `select` leaves in place, and the counter-prepending `with_row_index`.
/// A column *replaced* through `with_columns` takes the field of whichever
/// column now supplies its cells.
///
/// An operation that *computes* cells derives a fresh field instead, with the
/// constructor default: arithmetic, aggregations, `cast`, `fill_null` as an
/// expression, `group_by(...).agg(...)`, `join` (an outer one introduces
/// nulls), and the summary frames (`describe` / `null_count` / `sum` / …).
/// The declaration was made about the input's cells, not about these.
///
/// That split is what keeps the flag honest without ever inspecting a column:
/// it is validated once, by `from_rows`, and thereafter only accompanies cells
/// it was validated against — the operations that carry it drop, reorder or
/// rename, and never introduce a value.
///
/// The fields are readable but not constructible from outside `types`: build
/// one through `Field::Field(...)`, so a future field can be added without breaking
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
