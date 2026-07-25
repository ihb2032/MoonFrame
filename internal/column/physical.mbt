// The physical storage a logical `@types.DataType` materialises into, kept
// module-internal: it is the vocabulary the storage backends dispatch on, and
// storage lives in this package. A downstream user never needs it — creating,
// transforming, or reading a column is expressed entirely in logical
// `DataType`s — so exposing it would pin the physical layout into the public
// compatibility surface, which is exactly what a future logical type reusing a
// buffer (a `Date` as `I64`, a dictionary-encoded `String`) needs freedom to
// change.

///|
/// The physical buffer kind a column's logical `DataType` is materialised into.
/// The logical / physical split is what lets a *future* logical type reuse an
/// existing buffer without a new physical column kind: a `Date` / `Datetime`
/// stored as `I64`, a small `Decimal` as `I64`, a `Categorical` as `I64`
/// indices into a dictionary. Today the four concrete logical types map to
/// their four physical types one-to-one (see `physical_type`), so the split is
/// structure rather than new capability.
pub(all) enum PhysicalType {
  I64
  F64
  Bool
  Utf8
} derive(Eq, Debug)

///|
pub extend PhysicalType with Eq::{equal, not_equal}

///|
pub extend PhysicalType with Show::{to_string, output}

///|
pub extend PhysicalType with Debug::{to_repr}

///|
pub impl Show for PhysicalType with fn output(self, logger) {
  let name = match self {
    I64 => "I64"
    F64 => "F64"
    Bool => "Bool"
    Utf8 => "Utf8"
  }
  logger.write_string(name)
}

///|
/// The physical buffer a logical `DataType` needs, or `None` for `Null`. `Null`
/// deliberately has **no** `PhysicalType`: it is a value-level concept (a
/// missing cell, `Scalar::Null`), not a storable column kind, which is why a
/// `Null`-dtype column cannot be built — the storage dispatch reads that as "no
/// physical backend" rather than a special-cased variant.
pub fn physical_type(dtype : @types.DataType) -> PhysicalType? {
  match dtype {
    Int => Some(I64)
    Float => Some(F64)
    Bool => Some(Bool)
    String => Some(Utf8)
    Null => None
  }
}
