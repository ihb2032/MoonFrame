// The dtype registry: one row per logical `DataType`, holding every fact about
// the dtype that is not a variant of the type itself — its display name, the
// physical buffer its columns materialise into, and whether numeric kernels
// accept it. The registry is why adding a logical dtype is a local edit: a new
// dtype writes one row here (plus the `DataType` / `Scalar` variants and
// whatever rendering it needs) and every scattered "is this dtype numeric /
// what does it render as / which buffer does it ride" decision reads the row,
// instead of growing an arm in another package.
//
// This file is also where the physical buffer vocabulary lives. The logical
// and physical sets grow independently: logical dtypes arrive often (a `Date`
// rides the `I64` buffer), while the physical set is frozen by design and only
// grows for a buffer no existing one can serve (a fixed-point `Decimal`, say).
// A dtype riding an existing buffer is *defined* by how it reinterprets the
// buffer's raw cell on read — that lift lives in one place,
// `internal/column`'s `scalar_of` (the `I64` arm branches per dtype), which
// is where the next I64 rider registers its read side.

///|
/// The physical buffer kind a column's logical `DataType` is materialised
/// into. Module-internal (`#doc(hidden)` + `#internal(engine)`): a downstream
/// user never needs it — creating, transforming, or reading a column is
/// expressed entirely in logical `DataType`s — so exposing it would pin the
/// physical layout into the public compatibility surface.
///
/// Carries no `Show` / `Debug` / `Eq`: a caller *matches* on a physical tag
/// (`series`' empty-column dispatch is the only one), and nothing renders or
/// compares one. Deriving or hand-writing a trait here would publish it —
/// MoonBit promotes a trait impl's methods to regular methods, so an impl this
/// package needs to keep visible cannot avoid putting `to_string` / `to_repr` /
/// `equal` in the generated interface with it — which is capability this side
/// of the module boundary can reach for no reason any of it has. A future
/// diagnostic that wants the tag's name adds the derive then, with a caller to
/// point at.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub(all) enum PhysicalType {
  I64
  F64
  Bool
  Utf8
}

///|
/// One logical dtype's registered facts. Private: the registry is read through
/// the accessors below, so the row layout can grow (an FFI tag column, cast
/// targets) without touching a reader.
priv struct DTypeProfile {
  /// The `Show` spelling of the dtype (the `display` rendering, e.g. `Date`).
  display : String
  /// The buffer kind the dtype's columns materialise into; `None` for the
  /// value-level `Null`, which has no storable representation.
  physical : PhysicalType?
  /// Whether numeric kernels (arithmetic, sum / mean / std / var / median)
  /// accept the dtype. `Date` is `false`: its `I64` cells are days, and
  /// summing them is a bug, not a reduction.
  numeric : Bool
}

///|
/// The registry itself — one row per variant, wildcard-free so a dtype added
/// to `DataType` fails compilation here until its row is written. That is the
/// intended sequence: the row is the dtype's registration.
fn DataType::dtype_profile(self : DataType) -> DTypeProfile {
  match self {
    Int => { display: "Int", physical: Some(I64), numeric: true, }
    Float => { display: "Float", physical: Some(F64), numeric: true, }
    Bool => { display: "Bool", physical: Some(Bool), numeric: false, }
    String => { display: "String", physical: Some(Utf8), numeric: false, }
    Date => { display: "Date", physical: Some(I64), numeric: false, }
    Null => { display: "Null", physical: None, numeric: false, }
  }
}

///|
/// The `Show` spelling of the dtype — the single home of the display name
/// (`DataType::output` renders through this).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataType::display_name(self : DataType) -> String {
  self.dtype_profile().display
}

///|
/// The physical buffer a logical `DataType` needs, or `None` for `Null`. `Null`
/// deliberately has **no** `PhysicalType`: it is a value-level concept (a
/// missing cell, `Scalar::Null`), not a storable column kind, which is why a
/// `Null`-dtype column cannot be built — the storage dispatch reads that as "no
/// physical backend" rather than a special-cased variant.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataType::physical(self : DataType) -> PhysicalType? {
  self.dtype_profile().physical
}

///|
/// Whether a pair of dtypes reaches a comparison kernel's value arms: the same
/// dtype, or two numeric dtypes (`Int` vs `Float` compares exactly). This is
/// the column-level compare gate — it keeps an `I64`-riding dtype like `Date`
/// from comparing against a plain `Int`, whose cells are indistinguishable at
/// the physical level but unrelated logically.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataType::comparable_with(self : DataType, other : DataType) -> Bool {
  self == other || (self.is_numeric() && other.is_numeric())
}
