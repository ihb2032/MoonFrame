///|
/// Apache Arrow style columnar storage used by `Series` in v0.1.
///
/// The column splits values from validity. `data` is a typed array of raw
/// values (no `Option` boxing); `validity` is a bit-packed `Bitmap` where
/// `1 = valid, 0 = null`, matching Arrow's binary layout. Null slots in
/// `data` carry a per-dtype placeholder (`Int = 0`, `Float = 0.0`,
/// `Bool = false`, `String = ""`); public methods always consult
/// `validity` before reading `data`, so the placeholder never leaks.
///
/// As of v0.3 a `ColumnStorage` abstraction (plus a `NumericColumn` for
/// unboxed-numeric fast paths) sits above this layer at the `Series` backend
/// seam (see `storage.mbt`); it leaves `BuiltinColumn`'s own public API
/// unchanged — a `Series` simply holds one of the two backends behind it.
///
/// Numeric columns are 64-bit: the `Int` variant stores `Int64` and the
/// `Float` variant stores `Double`, matching `Scalar`'s payloads and the
/// pandas / polars `int64` / `float64` defaults so reductions neither
/// silently overflow nor lose precision.
pub struct BuiltinColumn {
  data : ColumnData
  validity : Bitmap
} derive(Eq, Debug)

///|
pub extend BuiltinColumn with Eq::{equal, not_equal}

///|
pub extend BuiltinColumn with Debug::{to_repr}

///|
/// Backing storage discriminated by dtype. The element type is the raw
/// value; nullability is tracked in the enclosing column's `validity`
/// bitmap.
pub(all) enum ColumnData {
  Int(Array[Int64])
  Float(Array[Double])
  Bool(Array[Bool])
  String(Array[String])
} derive(Eq, Debug)

///|
pub extend ColumnData with Eq::{equal, not_equal}

///|
pub extend ColumnData with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_ints(values : Array[Int64]) -> BuiltinColumn {
  { data: Int(values.copy()), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build an `Int` column where `None` entries are nulls. `None` slots
/// receive `0` as the data placeholder; public APIs never expose it.
pub fn BuiltinColumn::from_int_options(values : Array[Int64?]) -> BuiltinColumn {
  {
    data: Int(values.map(v => v.unwrap_or(0))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `Float` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_floats(values : Array[Double]) -> BuiltinColumn {
  { data: Float(values.copy()), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build a `Float` column where `None` entries are nulls. `None` slots
/// receive `0.0` as the data placeholder.
pub fn BuiltinColumn::from_float_options(
  values : Array[Double?],
) -> BuiltinColumn {
  {
    data: Float(values.map(v => v.unwrap_or(0.0))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `Bool` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_bools(values : Array[Bool]) -> BuiltinColumn {
  { data: Bool(values.copy()), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build a `Bool` column where `None` entries are nulls. `None` slots
/// receive `false` as the data placeholder.
pub fn BuiltinColumn::from_bool_options(values : Array[Bool?]) -> BuiltinColumn {
  {
    data: Bool(values.map(v => v.unwrap_or(false))),
    validity: Bitmap::from_options(values),
  }
}

///|
/// Build a `String` column from raw values (no nulls). `values` is copied, so
/// the column owns its data and is unaffected by later mutation of the array.
pub fn BuiltinColumn::from_strings(values : Array[String]) -> BuiltinColumn {
  { data: String(values.copy()), validity: Bitmap::all_valid(values.length()) }
}

///|
/// Build a `String` column where `None` entries are nulls. `None` slots
/// receive `""` as the data placeholder.
pub fn BuiltinColumn::from_string_options(
  values : Array[String?],
) -> BuiltinColumn {
  {
    data: String(values.map(v => v.unwrap_or(""))),
    validity: Bitmap::from_options(values),
  }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// The column's logical `DataType`, read from the `data` arm.
pub fn BuiltinColumn::dtype(self : BuiltinColumn) -> @types.DataType {
  match self.data {
    Int(_) => @types.DataType::Int
    Float(_) => @types.DataType::Float
    Bool(_) => @types.DataType::Bool
    String(_) => @types.DataType::String
  }
}

///|
/// The raw backing storage, discriminated by dtype. `ColumnData` is
/// `pub(all)`, so callers in other packages (sort, stats) match on the
/// concrete element type once and read values totally, rather than
/// cascading through the `*_values` accessors and `unwrap`-ing the final
/// branch the type system can't see is exhaustive. The element arrays are
/// shared (read-only), matching `int_values` / `float_values` / etc.
pub fn BuiltinColumn::data(self : BuiltinColumn) -> ColumnData {
  self.data
}

///|
/// The validity bitmap (`1 = valid`). Paired with `data` for callers that
/// read every slot in order: `validity().to_bools()` materialises the mask
/// once so a bounded loop indexes it totally, instead of catching a
/// per-slot `is_valid` raise. The bitmap is shared (read-only).
pub fn BuiltinColumn::validity(self : BuiltinColumn) -> Bitmap {
  self.validity
}

///|
/// Number of cells.
pub fn BuiltinColumn::len(self : BuiltinColumn) -> Int {
  match self.data {
    Int(a) => a.length()
    Float(a) => a.length()
    Bool(a) => a.length()
    String(a) => a.length()
  }
}

///|
/// `true` when the column has no cells.
pub fn BuiltinColumn::is_empty(self : BuiltinColumn) -> Bool {
  self.len() == 0
}

///|
/// Number of null cells (the count of zero bits in `validity`).
pub fn BuiltinColumn::null_count(self : BuiltinColumn) -> Int {
  self.validity.null_count()
}

///|
/// Whether every null slot's `data` holds this dtype's canonical placeholder
/// (`Int = 0`, `Float = 0.0`, `Bool = false`, `String = ""`). The
/// constructors, casts, and row transforms all write these, so a null slot's
/// value never leaks through `data()` / the `*_values` accessors — and, since
/// `BuiltinColumn` `derive`s `Eq` over the raw `data` array (null slots
/// included), two logically equal columns that differed only in a null slot's
/// placeholder would otherwise compare unequal. Surfaced as a predicate so a
/// test can assert the invariant directly instead of trusting each write site
/// by hand. Total — a bounded scan over the validity mask; the `data` match is
/// wildcard-free, so a future dtype must supply its placeholder here.
pub fn BuiltinColumn::placeholders_normalized(self : BuiltinColumn) -> Bool {
  let valid = self.validity.to_bools()
  match self.data {
    Int(a) => null_slots_hold(a, valid, 0L)
    Float(a) => null_slots_hold(a, valid, 0.0)
    Bool(a) => null_slots_hold(a, valid, false)
    String(a) => null_slots_hold(a, valid, "")
  }
}

///|
/// `true` when every null slot (`valid[i] == false`) of `data` holds `ph` — the
/// shared per-dtype scan behind `placeholders_normalized`.
fn[T : Eq] null_slots_hold(
  data : Array[T],
  valid : Array[Bool],
  ph : T,
) -> Bool {
  for i in 0..<data.length() {
    if !valid[i] && data[i] != ph {
      return false
    }
  }
  true
}

///|
/// `raise IndexOutOfBounds` if `index` is outside `[0, len)`.
pub fn BuiltinColumn::is_null(
  self : BuiltinColumn,
  index : Int,
) -> Bool raise @types.DataError {
  self.validity.is_null(index)
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index
/// `raise IndexOutOfBounds`.
pub fn BuiltinColumn::get(
  self : BuiltinColumn,
  index : Int,
) -> @types.Scalar raise @types.DataError {
  if self.validity.is_null(index) {
    @types.Scalar::Null
  } else {
    match self.data {
      Int(a) => @types.Scalar::Int(a[index])
      Float(a) => @types.Scalar::Float(a[index])
      Bool(a) => @types.Scalar::Bool(a[index])
      String(a) => @types.Scalar::String(a[index])
    }
  }
}

// ── Sub-views ─────────────────────────────────────────────────────────

///|
/// Half-open `[start, end)` slice. Requires `0 <= start <= end <= len`.
///
/// Errors (checked in this order):
/// - `IndexOutOfBounds(start)` when `start < 0`.
/// - `IndexOutOfBounds(end)` when `end > len`.
/// - `InvalidOperation("slice start > end: ...")` when `start > end`.
///
/// `start > len` is not a separate case: it can only occur together with
/// `end > len` (→ `IndexOutOfBounds(end)`) or `start > end`
/// (→ `InvalidOperation`), both already rejected above.
pub fn BuiltinColumn::slice(
  self : BuiltinColumn,
  start : Int,
  end : Int,
) -> BuiltinColumn raise @types.DataError {
  validate_slice_bounds(start, end, self.len())
  self.slice_unchecked(start, end)
}

///|
/// Total `[start, end)` slice — the shared core behind `slice` (which
/// validates the bounds then calls this). Copies the row data and takes a
/// zero-copy validity view (`Bitmap::slice_view`). The caller must guarantee
/// `0 <= start <= end <= len`; `slice` enforces that, and `ColumnStorage`'s
/// total `slice_total` clamps before delegating, so this never reads out of
/// bounds.
fn BuiltinColumn::slice_unchecked(
  self : BuiltinColumn,
  start : Int,
  end : Int,
) -> BuiltinColumn {
  let n = end - start
  let data_out : ColumnData = match self.data {
    Int(a) => Int(Array::makei(n, i => a[start + i]))
    Float(a) => Float(Array::makei(n, i => a[start + i]))
    Bool(a) => Bool(Array::makei(n, i => a[start + i]))
    String(a) => String(Array::makei(n, i => a[start + i]))
  }
  { data: data_out, validity: self.validity.slice_view(start, n) }
}

///|
/// Gather: produce a new column whose i-th entry is `self[indices[i]]`.
/// Any out-of-bounds index `raise IndexOutOfBounds(idx)`.
pub fn BuiltinColumn::take(
  self : BuiltinColumn,
  indices : Array[Int],
) -> BuiltinColumn raise @types.DataError {
  validate_gather_indices(indices, self.len())
  let data_out : ColumnData = match self.data {
    Int(a) => Int(indices.map(i => a[i]))
    Float(a) => Float(indices.map(i => a[i]))
    Bool(a) => Bool(indices.map(i => a[i]))
    String(a) => String(indices.map(i => a[i]))
  }
  // Indices are already validated against the same `len`, so gather the
  // validity bits through the unchecked `take_view` — no second O(n) bounds
  // scan, and no unreachable raise arm.
  { data: data_out, validity: self.validity.take_view(indices) }
}

// ── Cast ──────────────────────────────────────────────────────────────

///|
/// Cast by target dtype — the single public cross-dtype conversion. `Int`
/// truncates / parses, `Float` promotes / parses (per the file-private
/// `to_int` / `to_float` helpers this dispatches to), and `String` renders
/// every dtype through the total `to_string_column`. `Bool` and `Null`
/// targets are unsupported and `raise Unsupported`.
pub fn BuiltinColumn::cast(
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
  { data: wrap(buf), validity: self.validity }
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
          } else if !@types.double_fits_int64(x) {
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
          // Plain base-10 only, via the shared `@types.parse_decimal_int_opt`
          // (the CSV reader's inference routes through the same routine, so an
          // explicit cast and inference agree on what text is an integer); a
          // rejected form or an out-of-`Int64`-range value is a `ParseError`.
          match @types.parse_decimal_int_opt(s) {
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
          // Via the shared `@types.parse_plain_double_opt` (the CSV reader uses
          // the same routine): `1_000`-style underscores are rejected to match
          // pandas / polars, while the `inf` / `-inf` / `nan` literals — and a
          // finite literal beyond the `Double` range, which collapses to a
          // signed Infinity (IEEE 754) — stay accepted; a genuine non-number on
          // a valid slot is a `ParseError`.
          match @types.parse_plain_double_opt(s) {
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
pub fn BuiltinColumn::to_string_column(self : BuiltinColumn) -> BuiltinColumn {
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

// ── Typed accessors (zero-boxing fast path for ops) ──────────────────

///|
/// Return the underlying raw data array and validity bitmap (no `Option`
/// boxing). Data at null slots is a placeholder — always consult
/// `validity` before reading. `raise TypeMismatch(Column(...))` when the column is
/// not an `Int` column.
pub fn BuiltinColumn::int_values(
  self : BuiltinColumn,
) -> (Array[Int64], Bitmap) raise @types.DataError {
  match self.data {
    Int(a) => (a, self.validity)
    Float(_) | Bool(_) | String(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Column(@types.DataType::Int, self.dtype()),
      )
  }
}

///|
/// Like `int_values` but for `Float` columns.
pub fn BuiltinColumn::float_values(
  self : BuiltinColumn,
) -> (Array[Double], Bitmap) raise @types.DataError {
  match self.data {
    Float(a) => (a, self.validity)
    Int(_) | Bool(_) | String(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Column(@types.DataType::Float, self.dtype()),
      )
  }
}

///|
/// Like `int_values` but for `Bool` columns.
pub fn BuiltinColumn::bool_values(
  self : BuiltinColumn,
) -> (Array[Bool], Bitmap) raise @types.DataError {
  match self.data {
    Bool(a) => (a, self.validity)
    Int(_) | Float(_) | String(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Column(@types.DataType::Bool, self.dtype()),
      )
  }
}

///|
/// Like `int_values` but for `String` columns.
pub fn BuiltinColumn::string_values(
  self : BuiltinColumn,
) -> (Array[String], Bitmap) raise @types.DataError {
  match self.data {
    String(a) => (a, self.validity)
    Int(_) | Float(_) | Bool(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Column(@types.DataType::String, self.dtype()),
      )
  }
}
