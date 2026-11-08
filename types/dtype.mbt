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
#derive(Eq, Debug)
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
  /// An IEEE 754-2019 decimal128 floating-point number — the `Dec128`
  /// value layer's semantics in a column: up to 34 significant digits,
  /// a per-value quantum exponent in `[-6176, 6144]`, and the
  /// exceptional shapes ±infinity, `NaN`, and signed zero as *values*
  /// (ordered by the total order the `Float` stack already uses — NaN
  /// past everything, −0 and +0 equal — never routed through the
  /// missing-placement rule). Arithmetic computes exactly and rounds
  /// once, ties to even; `+` / `-` / `*` / `/` stay `Decimal` (`Int`
  /// lifts exactly, a `Float` operand promotes the pair to `Float`);
  /// a magnitude past `10^6144` is ±∞, one below the subnormal floor a
  /// signed zero — an overflow is a value, never a refusal. Exact
  /// results keep the cohort's preferred exponent (the addends' finer
  /// one, the operand exponents' sum for `*`, their difference for
  /// `/`), so `1.50 + 0` is `1.50`. `sum` propagates NaN and folds
  /// +∞ with −∞ into NaN; `min` / `max` skip NaN as missing. Not
  /// numeric (mean / median / quantile / rolling refuse); comparison,
  /// ordering, grouping, joins read numeric value equality (cohorts
  /// compare equal — `1.0` joins `1.00`). The parquet interchange
  /// rides the `DECIMAL` annotation: a column every cell of which
  /// fits 18 digits rides `INT64` as before, wider ones
  /// `FIXED_LEN_BYTE_ARRAY(16)` at precision 38; a NaN or ±∞ cell
  /// refuses the write. Readers never infer it.
  Decimal
  /// A span of time, stored as whole microseconds (negative for a span
  /// running backwards) — an `I64` physical buffer with duration
  /// semantics, `Timestamp`'s unit without its epoch. The temporal
  /// arithmetic reads it: `Timestamp − Timestamp` and `Date − Date`
  /// produce one, `Timestamp ± Duration` stays `Timestamp` (a `Date`
  /// promoted to `Timestamp` first). Not numeric; ordering / grouping
  /// compare the raw microsecond spans. Renders as an ISO 8601 duration
  /// (days-and-time form, the second's fraction always six digits); the
  /// readers have no parser for it — a written-back column reads as
  /// `String`, and a `dtypes` pin refuses it.
  Duration
  Null
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
///
/// This is one of three dtype-pair gates in the engine, each with its own
/// semantics: this one (comparison), the arithmetic gate
/// (`is_numeric` on both sides, `numeric_general_pair` in the kernel — no
/// same-dtype clause, so `Date` does not subtract from `Date`), and the
/// ternary gate (same dtype, or one side numeric — `eval_ternary`). They
/// agree on every registry row today because the non-numeric rows are all
/// riders; changing a row's `numeric` flag is a review of all three, which
/// is why each spells a pointer back here.
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
