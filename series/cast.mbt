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
/// - `String` — `Int` / `Float` / `Bool` render to their value form;
///   never rejects a value, so the only failure is an unsupported side
///   below.
/// - `Timestamp` from `Date` — each day count scaled by the microseconds a
///   day holds, exact (a day count whose instant leaves `Int64` `raise`s
///   `ParseError`).
/// - `Date` from `Timestamp` — the microsecond count floored to whole
///   days, total at every value.
///
/// Null slots are preserved verbatim. A numeric result lands on the
/// `Builtin` backend; the engine re-converges it onto the unboxed fast path
/// where a later step benefits. Every other pairing — `Bool`, `Null`,
/// `Decimal` targets, a temporal target from a non-temporal source, or a
/// `Decimal` source — `raise`s `Unsupported(_)`: the decimal rider's
/// scaled magnitude is not a conversion this library offers; `item` /
/// `to_string` render it instead.
pub fn Series::cast(
  self : Series,
  target : @types.DataType,
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.cast(target), }
}
