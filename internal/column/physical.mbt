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
///
/// Carries no `Show` / `Debug` / `Eq`: a caller *matches* on a physical tag
/// (`series`' empty-column dispatch is the only one), and nothing renders or
/// compares one. Deriving or hand-writing a trait here would publish it —
/// MoonBit promotes a trait impl's methods to regular methods, so an impl this
/// package needs to keep visible cannot avoid putting `to_string` / `to_repr` /
/// `equal` in the generated interface with it — which is capability this side of
/// the module boundary can reach for no reason any of it has. A future
/// diagnostic that wants the tag's name adds the derive then, with a caller to
/// point at.
pub(all) enum PhysicalType {
  I64
  F64
  Bool
  Utf8
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
