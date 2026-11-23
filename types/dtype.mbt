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
  /// A variable-length list of values, every cell holding the element
  /// dtype's scalars (an element may be null — a `Scalar::Null` inside
  /// the list). The element dtype is the payload, itself possibly
  /// nested (`List(List(Int))`).
  ///
  /// Not numeric and not summable, so nothing that computes over a cell
  /// reads one: arithmetic, the statistics (`sum` / `mean` / `std` /
  /// `median` / the quantiles), the logical and string verbs, the running
  /// and rolling arithmetic, and every cast refuse a nested column. What
  /// moves, compares, or keys cells works on it whole:
  ///
  /// - the row verbs — selecting, renaming, filtering on another column,
  ///   slicing, reversing, stacking;
  /// - the comparisons — `eq` / `ne` by content (element by element, a
  ///   null cell comparing unknown), and `lt` / `le` / `gt` / `ge` by the
  ///   order the order verbs read, which `clip` bounds a column by too;
  /// - the order verbs — `sort`, `rank`, `arg_sort`, `min` / `max`, and
  ///   `arg_min` / `arg_max`, all reading one order: element by element
  ///   through the order the element dtype sorts by, a shorter prefix
  ///   first, and a null element before a present one;
  /// - the keys — `group_by`, `join`, `unique`, `n_unique`, and `mode`
  ///   read a list by its content, and `first` / `last` / `count` carry
  ///   its cells;
  /// - the positional verbs that move or count cells — `shift`,
  ///   `forward_fill`, `cum_count`, `is_first_distinct`, and
  ///   `unique_counts`.
  ///
  /// A nested literal (`lit` of a list value), `is_in`, and
  /// `when(c).then(a).otherwise(b)` take part in comparing and selecting
  /// cells. JSON writes a list cell as the array it is and infers a list
  /// column on a read, and `Series::from_scalars` infers one from its
  /// cells; a CSV cell is one text field, so `write_csv` writes the
  /// cell's text and the CSV reader cannot read a list back.
  List(DataType)
  /// A fixed set of named fields, every cell holding one value per
  /// field, in the fields' own order (a value may be null — a
  /// `Scalar::Null` for that field). The payload is the struct's
  /// schema: an immutable `Schema` whose fields name and type the
  /// struct's members, themselves possibly nested (`Struct` of
  /// `Struct`, `List` of `Struct`).
  ///
  /// The verbs and refusals stated on the `List` variant are a struct
  /// column's too; its cells differ only in how they compare — by field,
  /// in the fields' own order, where a list compares by element — and in
  /// what JSON writes: a struct cell leaves as the object it is.
  Struct(Schema)
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
/// Whether the reduction `sum` accepts the dtype — the registry row it
/// reads states why this is wider than `is_numeric` for exactly one dtype:
/// a `Decimal` column folds through the engine's value arithmetic (NaN
/// propagates, an overflow is ±∞), while the approximate statistics stay
/// behind the numeric gate.
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
/// semantics: this one (comparison), the arithmetic gate (the `Decimal`
/// pair's engine route first, then `is_numeric` on both sides —
/// `numeric_general_pair` in the kernel, no same-dtype clause, so `Date`
/// does not subtract from `Date`), and the ternary gate (same dtype — now
/// including `Decimal` — or `Int` with `Float` — `eval_ternary`). The
/// comparison and ternary gates share the same-dtype clause; the
/// arithmetic gate reads the registry's numeric flag. Changing a row's
/// `numeric` flag is a review of all three, which is why each spells a
/// pointer back here.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataType::comparable_with(self : DataType, other : DataType) -> Bool {
  self == other || (self.is_numeric() && other.is_numeric())
}

///|
/// The `Show` spelling: the registry's display name for a scalar dtype —
/// the name is registered per dtype, not matched here — and, for a
/// nested dtype, that name with its shape spelled out: `List(Int)`,
/// `List(List(String))`, `Struct(a: Int, b: String)`. A bare `List` would
/// name every list dtype alike, and an error message that reads
/// "expected List, got List" says nothing; the element dtype and the
/// fields are what tell two nested dtypes apart, so they ride the
/// spelling. A struct's fields render in the struct's own order.
pub impl Show for DataType with fn output(self, logger) {
  if self is List(element) {
    logger.write_string("List(")
    logger <+ "\{element}"
    logger.write_string(")")
  } else if self is Struct(fields) {
    logger.write_string("Struct(")
    let declared = fields.fields()
    for i, field in declared {
      if i > 0 {
        logger.write_string(", ")
      }
      logger.write_string(field.name())
      logger.write_string(": ")
      logger <+ "\{field.dtype()}"
    }
    logger.write_string(")")
  } else {
    logger.write_string(self.dtype_profile().display)
  }
}
