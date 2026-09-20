// The cast verb: `Series::cast`, the single cross-dtype conversion entry,
// delegating to the storage layer's cast machine.

///|
/// Cast to the target dtype, the single cross-dtype conversion entry
/// (Polars' `Series.cast`). Delegates to `BuiltinColumn::cast`; the
/// supported targets are:
///
/// - `Int` — identity on Int; Float truncates toward zero (`NaN`, `±Inf`,
///   and out-of-`Int64`-range values `raise ParseError`); Bool → `1` / `0`;
///   String parses plain base-10 integers (other forms `raise ParseError`).
/// - `Float` — Int promoted; identity on Float; Bool → `1.0` / `0.0`;
///   String parses decimals / scientific notation.
/// - `String` — every dtype renders to its value form; never rejects a
///   value, so the only failure is the unsupported-target guard below.
///
/// Null slots are preserved verbatim. A numeric result lands on the
/// `Builtin` backend; the engine re-converges it onto the unboxed fast path
/// where a later step benefits. `Bool` and `Null` targets `raise Unsupported(_)`.
pub fn Series::cast(
  self : Series,
  target : @types.DataType,
) -> Series raise @types.DataError {
  { name: self.name, storage: self.storage.cast(target), }
}
