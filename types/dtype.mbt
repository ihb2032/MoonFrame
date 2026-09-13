///|
/// Logical data type for a column.
///
/// `Null` is the dtype of a *missing value*, not of a column: it is what
/// `Scalar::Null.dtype()` reports, and so what a `TypeMismatch`'s "expected T,
/// got Null" names when a null cell reaches a typed read. A hand-built `Schema`
/// may also carry it, but nothing materialises a column on it —
/// `DataFrame::empty` raises `Unsupported` for such a field, `cast` refuses it
/// as a target, and **no reader infers it**: an all-null probe window falls back
/// to `String` (see [`docs/type-inference.md`](../docs/type-inference.md)).
/// Concrete columns always carry one of the other variants.
///
/// A logical dtype is more than its variant: its display name, the physical
/// buffer its columns ride, and its numericity are registered in
/// `dtype_registry.mbt`, whose per-dtype rows are the compile-forced
/// registration point for a dtype added here.
pub(all) enum DataType {
  Int
  Float
  Bool
  String
  /// A calendar date, stored as whole days since the Unix epoch
  /// (`1970-01-01` = day 0, negative for earlier dates) — an `I64` physical
  /// buffer with date semantics. Not numeric: arithmetic on days is a
  /// `TypeMismatch`, comparisons / ordering / grouping are date-wise. Readers
  /// never infer it (an ISO-shaped CSV column arrives as `String`).
  Date
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
/// Reads the registry's `numeric` flag, so an `I64`-riding dtype like `Date`
/// is correctly *not* numeric.
pub fn DataType::is_numeric(self : DataType) -> Bool {
  self.dtype_profile().numeric
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
/// The `Show` spelling renders the registry's display name — the name is
/// registered per dtype, not matched here.
pub impl Show for DataType with fn output(self, logger) {
  logger.write_string(self.display_name())
}
