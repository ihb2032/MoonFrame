// The cast verb: `Series::cast`, the single cross-dtype conversion entry,
// delegating to the storage layer's cast machine.

///|
/// Cast to the target dtype, the single cross-dtype conversion entry.
/// Delegates to `BuiltinColumn::cast`; the supported targets are:
///
/// - `Int` — identity on Int; Float truncates toward zero (`NaN`, `±Inf`,
///   and out-of-`Int64`-range values `raise ParseError`); Bool → `1` / `0`;
///   String parses plain base-10 integers (other forms `raise ParseError`).
/// - `Float` — Int promoted; identity on Float; Bool → `1.0` / `0.0`;
///   String parses decimals / scientific notation.
/// - `String` — every dtype renders to its value form, including
///   `Decimal` (the engine's own spelling).
/// - `Decimal` — from `Int` exactly, from `Float` through the
///   correctly-rounded conversion, from `String` through the value
///   parser; toward `Int` it truncates toward zero (a `NaN` / ±∞ / an
///   out-of-`Int64` magnitude `raise`s `ParseError`), toward `Float` it
///   is the correctly-rounded conversion, and toward `String` the value
///   rendering.
/// - `Timestamp` from `Date` — each day count scaled by the microseconds a
///   day holds, exact (a day count whose instant leaves `Int64` `raise`s
///   `ParseError`).
/// - `Date` from `Timestamp` — the microsecond count floored to whole
///   days, total at every value.
///
/// Null slots are preserved verbatim. A cast onto the column's **own**
/// dtype is the identity — the column is shared, not rebuilt — for every
/// dtype, including `Bool` / `Date` / `Timestamp` / `Decimal` /
/// `Duration`, whose other cross-dtype pairings are refused. A numeric
/// result lands on the `Builtin` backend; the engine re-converges it onto
/// the unboxed fast path where a later step benefits. Every other pairing
/// — a `Bool` or `Null` target, a temporal target from a non-temporal
/// source or one outside the `Date` / `Timestamp` pair, and a `Decimal`
/// from a dtype the list above does not name — `raise`s `Unsupported(_)`.
pub fn Series::cast(
  self : Series,
  target : @types.DataType,
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.cast(target), }
}
