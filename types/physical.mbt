///|
/// The physical storage a column's logical `DataType` is materialised into —
/// the buffer kind the backends (`internal/column`) actually hold. The
/// logical / physical split is what lets a *future* logical type reuse an
/// existing buffer without a new physical column kind: a `Date` or a `Datetime`
/// stored as `I64`, a small `Decimal` as `I64`, a `Categorical` as `I64` indices
/// into a dictionary. Today MoonFrame's four concrete logical types map to their
/// four physical types one-to-one (see `DataType::physical`), so the split is
/// structure rather than new capability — the point at which it earns its keep
/// is the first logical type that differs from its physical representation.
///
/// `Null` deliberately has **no** `PhysicalType`: it is a value-level concept
/// (a missing cell, `Scalar::Null`), not a storable column kind, which is why
/// `DataType::physical(Null)` is `None` and a `Null`-dtype column cannot be
/// built.
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
