///|
/// Logical data type for a column.
///
/// `Null` is the dtype of a *missing value*, not of a column: it is what
/// `Scalar::Null.dtype()` reports, and so what a `TypeMismatch`'s "expected T,
/// got Null" names when a null cell reaches a typed read. A hand-built `Schema`
/// may also carry it, but nothing materialises a column on it —
/// `DataFrame::empty` raises `Unsupported` for such a field, `cast` refuses it
/// as a target, and **no reader infers it**: an all-null probe window falls back
/// to `String`.
/// Concrete columns always carry one of the other variants.
///
/// A logical dtype is more than its variant: its display name, the physical
/// buffer its columns ride, and its numericity are registered in
/// the dtype registry, whose per-dtype rows are the compile-forced
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
  /// A point in time, stored as microseconds since the Unix epoch
  /// (`1970-01-01T00:00:00` = microsecond 0, negative for earlier instants) —
  /// an `I64` physical buffer with timestamp semantics at microsecond
  /// resolution, the finest of the common interchange timestamps. Not
  /// numeric, for the same reason `Date` is not: arithmetic on raw
  /// microseconds is a bug.
  /// Renders as ISO 8601 (`YYYY-MM-DDTHH:MM:SS.ffffff`, the microsecond
  /// fraction always six digits so the rendering round-trips); readers never
  /// infer it.
  Timestamp
  /// A fixed-point decimal, parameterised by its `scale` — the number of
  /// decimal digits after the point. A cell carries its *unscaled* magnitude
  /// as an `Int64` (the value is `unscaled × 10⁻ˢᶜᶜᵃˡᵉ`), so the usable
  /// precision is `18 - scale` integer digits: `Decimal(2)` over `12345` is
  /// `123.45`. An `I64` physical buffer with decimal semantics, like `Date` /
  /// `Timestamp` riders. Comparison, ordering, grouping, `sum` / `min` /
  /// `max` / `count` are exact over the unscaled cells; `+` / `-` / `*` are
  /// exact across scales (both sides lift to the larger scale, `Int` lifts
  /// as scale 0, `*` adds the scales) and refuse — `InvalidOperation`,
  /// never a wrap — when a magnitude leaves the range; division stays
  /// fenced pending a result-scale rule, and so does mixing with `Float`;
  /// the `Int` lift is arithmetic-only — a `Decimal` compared against an
  /// `Int` is a `TypeMismatch`, so a compared bound is written as a
  /// decimal literal; readers never infer it.
  Decimal(Int32)
  Null
} derive(Eq, Debug)

///|
/// The decimal envelope's one enforcement point: a `Decimal` dtype's scale
/// stays in `[0, 18]` — eighteen fraction digits is the most an `Int64`
/// unscaled magnitude leaves room for, the bound the `Decimal` variant's
/// docstring states. Every constructor that authors a decimal dtype (the
/// series builder, the scalar projection, the arithmetic's output scale)
/// raises here, so no column the library builds carries a scale the
/// rendering and the rescale would only meet downstream. A hand-built
/// `Scalar::Decimal` can still name any scale — `Scalar` is `pub(all)` —
/// which is why the rendering stays total over every input it is handed.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn check_decimal_scale(
  scale : Int32,
  origin : String,
) -> Unit raise DataError {
  if scale < 0 || scale > 18 {
    raise DataError::InvalidOperation(
      "decimal \{origin} carries scale \{scale}, outside the envelope [0, 18]",
    )
  }
}

///|
pub extend DataType with Eq::{equal, not_equal}

///|
pub extend DataType with Show::{to_string, output}

///|
pub extend DataType with Debug::{to_repr}

///|
/// `true` for `Int` and `Float` — both are usable in numeric reductions.
/// Reads the registry's `numeric` flag, so an `I64`-riding dtype like `Date`
/// is correctly *not* numeric.
pub fn DataType::is_numeric(self : DataType) -> Bool {
  self.dtype_profile().numeric
}

///|
/// Whether the exact reduction `sum` accepts the dtype — the registry row it
/// reads states why this is wider than `is_numeric` for exactly one rider:
/// unscaled decimal cells of a single scale add exactly, refusing the total
/// that leaves the `Int64` range.
pub fn DataType::is_summable(self : DataType) -> Bool {
  self.dtype_profile().summable
}

///|
/// Whether a pair of dtypes reaches a comparison kernel's value arms: the same
/// dtype, or two numeric dtypes (`Int` vs `Float` compares exactly). This is
/// the column-level compare gate — it keeps an `I64`-riding dtype like `Date`
/// from comparing against a plain `Int`, whose cells are indistinguishable at
/// the physical level but unrelated logically. A derived rule, not a
/// registered one: same dtype or two `is_numeric` dtypes, with no per-dtype
/// arm of its own.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataType::comparable_with(self : DataType, other : DataType) -> Bool {
  self == other || (self.is_numeric() && other.is_numeric())
}

///|
/// The `Show` spelling renders the registry's display name — the name is
/// registered per dtype, not matched here.
pub impl Show for DataType with fn output(self, logger) {
  logger.write_string(self.dtype_profile().display)
}
