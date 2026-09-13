// The dtype-conversion policy over `BuiltinColumn`'s buffers: `cast` and the
// `to_int` / `to_float` / `to_string_column` implementations behind it — split
// from `builtin.mbt` so the Arrow layout and the conversion rules read apart.
// Parsing strictness is a shared fact, not a local choice: text cells route
// through the same `@text` probes the CSV reader's inference uses, so an
// explicit cast and inference agree on what a cell means.

// ── Cast ──────────────────────────────────────────────────────────────

///|
/// Cast by target dtype — the single public cross-dtype conversion. `Int`
/// truncates / parses, `Float` promotes / parses (per the file-private
/// `to_int` / `to_float` helpers this dispatches to), and `String` renders
/// every dtype through the total `to_string_column`. `Bool` and `Null`
/// targets are unsupported and `raise Unsupported`.
fn BuiltinColumn::cast(
  self : BuiltinColumn,
  target : @types.DataType,
) -> BuiltinColumn raise @types.DataError {
  match target {
    Int => self.to_int()
    Float => self.to_float()
    String => self.to_string_column()
    Bool => raise @types.DataError::Unsupported("cast to Bool")
    Null => raise @types.DataError::Unsupported("cast to Null")
  }
}

///|
/// Assemble a cast result from a per-cell conversion: each valid slot maps
/// through `conv`, each null slot takes the `fill` placeholder, and the
/// validity bitmap is reused verbatim (a cast preserves nullity). The "read the
/// mask once, `makei` with a null guard, reuse the validity" shell shared by
/// every cast, rather than written once per source dtype.
///
/// The error effect follows `conv` (`raise?`): the fallible casts `to_int` /
/// `to_float` pass a `conv` that `raise`s on an out-of-range or malformed cell,
/// so those stay fallible; the total `to_string_column` passes a `conv` that
/// never fails, so it stays total. One shell serves both — MoonBit's error
/// polymorphism resolves the effect at each call site, so the total surface is
/// not forced to adopt an error it never produces.
fn[U] BuiltinColumn::cast_cells(
  self : BuiltinColumn,
  conv : (Int) -> U raise?,
  fill : U,
  wrap : (Array[U]) -> ColumnData,
) -> BuiltinColumn raise? {
  let valid = self.validity.to_bools()
  let buf : Array[U] = Array::makei(valid.length(), i => {
    if valid[i] {
      conv(i)
    } else {
      fill
    }
  })
  { data: wrap(buf), validity: self.validity, }
}

///|
/// Convert to `Int` — the file-private implementation behind `cast(Int)`.
/// Validity is preserved verbatim. Supported sources:
/// - `Int`: identity, no copy.
/// - `Float`: truncated towards zero. `NaN`, `+Inf`, `-Inf`, and values
///   outside the `Int64` range are rejected with `ParseError` — the
///   underlying `Double::to_int64` is implementation-defined on those
///   inputs, so the cast layer guards against them explicitly. Null
///   slots skip the conversion entirely.
/// - `Bool`: `true` → 1, `false` → 0.
/// - `String`: only plain base-10 integers are accepted — an optional
///   `+` / `-` sign followed by ASCII digits. Any other form on a valid
///   (non-null) slot returns `ParseError`, mirroring the CSV reader's
///   inference: `0x` / `0o` / `0b` base prefixes and `1_000` underscore
///   grouping are rejected (pandas / polars keep them as strings), as are
///   leading/trailing whitespace, non-numeric suffixes, empty strings,
///   and decimal integers that overflow 64-bit `Int64`.
fn BuiltinColumn::to_int(
  self : BuiltinColumn,
) -> BuiltinColumn raise @types.DataError {
  match self.data {
    Int(_) => self
    Float(a) =>
      self.cast_cells(
        i => {
          let x = a[i]
          if x.is_nan() {
            raise @types.DataError::ParseError(
              @types.ParseErrorDetail::Message("cannot cast NaN to Int"),
            )
          } else if x.is_inf() {
            raise @types.DataError::ParseError(
              @types.ParseErrorDetail::Message("cannot cast Infinity to Int"),
            )
          } else if !@numeric.double_fits_int64(x) {
            raise @types.DataError::ParseError(
              @types.ParseErrorDetail::Message(
                "Float value out of Int range: \{x}",
              ),
            )
          } else {
            x.to_int64()
          }
        },
        0,
        b => Int(b),
      )
    Bool(a) =>
      self.cast_cells(i => (if a[i] { 1 } else { 0 }).to_int64(), 0, b => Int(b))
    String(a) =>
      self.cast_cells(
        i => {
          let s = a[i]
          // Plain base-10 only, via the shared `@text.parse_decimal_int_opt`
          // (the CSV reader's inference routes through the same routine, so an
          // explicit cast and inference agree on what text is an integer); a
          // rejected form or an out-of-`Int64`-range value is a `ParseError`.
          match @text.parse_decimal_int_opt(s) {
            Some(n) => n
            None =>
              raise @types.DataError::ParseError(
                @types.ParseErrorDetail::Message(
                  "cannot parse Int from \"\{s}\"",
                ),
              )
          }
        },
        0,
        b => Int(b),
      )
  }
}

///|
/// Convert to `Float` — the file-private implementation behind `cast(Float)`.
/// Validity is preserved verbatim. Supported sources:
/// - `Float`: identity, no copy.
/// - `Int`: promoted via `Int64::to_double` (a `Double` has 52 bits of
///   significand, so `Int64`s with magnitude > 2^53 lose precision — this
///   is inherent to the target type and not flagged as an error).
/// - `Bool`: `true` → 1.0, `false` → 0.0.
/// - `String`: parsed via `@string.parse_double`. `1_000`-style underscore
///   grouping is rejected to match the CSV reader (pandas / polars keep
///   such cells as strings); the `inf` / `-inf` / `nan` literals are still
///   accepted. Other malformed strings on valid slots return `ParseError`;
///   finite values beyond the `Double` range collapse to `±Infinity` per
///   IEEE 754.
fn BuiltinColumn::to_float(
  self : BuiltinColumn,
) -> BuiltinColumn raise @types.DataError {
  match self.data {
    Float(_) => self
    Int(a) => self.cast_cells(i => a[i].to_double(), 0.0, b => Float(b))
    Bool(a) =>
      self.cast_cells(i => if a[i] { 1.0 } else { 0.0 }, 0.0, b => Float(b))
    String(a) =>
      self.cast_cells(
        i => {
          let s = a[i]
          // Via the shared `@text.parse_plain_double_opt` (the CSV reader uses
          // the same routine): `1_000`-style underscores are rejected to match
          // pandas / polars, while the `inf` / `-inf` / `nan` literals — and a
          // finite literal beyond the `Double` range, which collapses to a
          // signed Infinity (IEEE 754) — stay accepted; a genuine non-number on
          // a valid slot is a `ParseError`.
          match @text.parse_plain_double_opt(s) {
            Some(x) => x
            None =>
              raise @types.DataError::ParseError(
                @types.ParseErrorDetail::Message(
                  "cannot parse Float from \"\{s}\"",
                ),
              )
          }
        },
        0.0,
        b => Float(b),
      )
  }
}

///|
/// Convert to `String`. Each valid cell is rendered with the same
/// value-form used by `Scalar::to_string` (e.g. `Int(42)` → `"42"`,
/// `Bool(true)` → `"true"`). Null slots get an empty placeholder and
/// remain null in the validity bitmap.
///
/// Total: every dtype has a value-form rendering, so there is no failure
/// path. Unlike `to_int` / `to_float` (which can fail on out-of-range or
/// malformed input) this never raises.
fn BuiltinColumn::to_string_column(self : BuiltinColumn) -> BuiltinColumn {
  match self.data {
    String(_) => self
    Int(a) => self.cast_cells(i => a[i].to_string(), "", b => String(b))
    Float(a) => self.cast_cells(i => a[i].to_string(), "", b => String(b))
    Bool(a) =>
      self.cast_cells(i => if a[i] { "true" } else { "false" }, "", b => {
        String(b)
      })
  }
}
