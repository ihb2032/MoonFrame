///|
/// Unboxed, **all-valid** numeric column — the `null_count == 0` fast path.
///
/// Unlike `BuiltinColumn` (which always pairs `data` with a `validity`
/// `Bitmap`), `NumericColumn` carries no bitmap at all: every slot is a
/// present value by construction, so there is nothing to mask. The moment a
/// `null` enters the picture the column is materialised back into a
/// `BuiltinColumn` (`to_builtin`, total + lossless). This mirrors Arrow /
/// Polars, where a buffer with `null_count == 0` skips the validity check on
/// the hot path.
///
/// The win is twofold and measurable (see `numeric_test.mbt`):
///   1. **construction / sub-views** allocate no validity `Bytes`:
///      `from_int64s` / `from_doubles` are just the data array, and `slice` /
///      `take` repack only the data — `BuiltinColumn` additionally allocates
///      (`from_ints`) or repacks (`slice` / `take`) a `Bitmap`;
///   2. **reductions** read the raw array with no `validity().to_bools()`
///      materialisation and no per-slot `if valid[i]` branch that `Series`'
///      reductions run: `sum` / `mean` are a tight fold over the array, and
///      `min` / `max` share one `fold_extremum` pass whose only
///      per-slot test is the `Float` `NaN`-skip (a no-op on the `Int` arm).
///
/// The accessor surface is named identically to `BuiltinColumn`'s numeric
/// accessors so `ColumnStorage::Numeric` can forward to it verbatim (S2) and
/// the `Series.storage` flip (S3) stays mechanical. The reductions (`sum` /
/// `mean` / `min` / `max`) match `Series`' own semantics
/// (`BuiltinColumn` carries none of its own), and `Series::sum` / `mean` /
/// `min` / `max` dispatch straight here on a `Numeric`-backed
/// column — so the bitmap-free fold is the path actually taken for an
/// all-valid numeric `Series`, not just a parallel implementation. Cross-dtype
/// transforms
/// (`cast` / `to_int` / `to_float`) are
/// intentionally absent: a caller that needs them goes through `to_builtin()`
/// and lets `BuiltinColumn` do the work, keeping this type's surface to the
/// fast-path operations that actually benefit from the missing bitmap.
pub struct NumericColumn {
  data : NumericData
} derive(Eq, Debug)

///|
pub extend NumericColumn with Eq::{equal, not_equal}

///|
pub extend NumericColumn with Debug::{to_repr}

///|
/// Backing storage for `NumericColumn`, discriminated by dtype. The element
/// type is the raw value; there is no nullability to track (every slot is
/// valid). Numeric only — `Bool` / `String` columns are always backed by a
/// `BuiltinColumn`, so `NumericData` has just the two numeric arms.
pub(all) enum NumericData {
  Int(Array[Int64])
  Float(Array[Double])
} derive(Eq, Debug)

///|
pub extend NumericData with Eq::{equal, not_equal}

///|
pub extend NumericData with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values. There is no null path — if any cell
/// may be missing, build a `BuiltinColumn` (`from_int_options`) and keep the
/// column `Builtin` instead. No validity `Bitmap` is allocated. `values` is
/// copied, so the column owns its data.
pub fn NumericColumn::from_int64s(values : Array[Int64]) -> NumericColumn {
  { data: Int(values.copy()) }
}

///|
/// Build a `Float` column from raw values. As with `from_int64s` there is no
/// null path and no validity `Bitmap`. `NaN` is a perfectly valid stored
/// value here — it is *not* a missing marker (only an absent slot is, and
/// this column has none) — and it participates in reductions exactly as
/// Polars treats it: propagating through `sum` / `mean`, skipped by
/// `min` / `max`. `values` is copied, so the column owns its data.
pub fn NumericColumn::from_doubles(values : Array[Double]) -> NumericColumn {
  { data: Float(values.copy()) }
}

///|
/// Alias of `from_int64s` under the spelling the rest of the library uses
/// for a raw `Array[Int64]` (`BuiltinColumn::from_ints` /
/// `Series::from_ints`), so the storage seam reads uniformly at every
/// layer.
pub fn NumericColumn::from_ints(values : Array[Int64]) -> NumericColumn {
  NumericColumn::from_int64s(values)
}

///|
/// Alias of `from_doubles` under the spelling the rest of the library uses
/// for a raw `Array[Double]` (`BuiltinColumn::from_floats` /
/// `Series::from_floats`), so the storage seam reads uniformly at every
/// layer.
pub fn NumericColumn::from_floats(values : Array[Double]) -> NumericColumn {
  NumericColumn::from_doubles(values)
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// The column's logical `DataType` — `Int` or `Float` (a `NumericColumn` is
/// numeric by construction).
pub fn NumericColumn::dtype(self : NumericColumn) -> @types.DataType {
  match self.data {
    Int(_) => @types.DataType::Int
    Float(_) => @types.DataType::Float
  }
}

///|
/// Number of cells.
pub fn NumericColumn::len(self : NumericColumn) -> Int {
  match self.data {
    Int(a) => a.length()
    Float(a) => a.length()
  }
}

///|
/// `true` when the column has no cells.
pub fn NumericColumn::is_empty(self : NumericColumn) -> Bool {
  self.len() == 0
}

///|
/// Always `0`: an all-valid column has no nulls by construction. Total — no
/// bitmap to popcount, the answer is structural.
pub fn NumericColumn::null_count(_self : NumericColumn) -> Int {
  0
}

///|
/// The raw backing storage as a `ColumnData`, so callers (and the
/// `ColumnStorage::Numeric` arm) read values through the same total `data()`
/// surface `BuiltinColumn` exposes. The element array is shared (read-only).
pub fn NumericColumn::data(self : NumericColumn) -> ColumnData {
  match self.data {
    Int(a) => ColumnData::Int(a)
    Float(a) => ColumnData::Float(a)
  }
}

// ── Cell access ───────────────────────────────────────────────────────

///|
/// Whether cell `index` is null — structurally **always `false`** for an
/// all-valid column. Out-of-bounds `index` `raise IndexOutOfBounds`; the
/// bounds check is the method's only real work. It mirrors
/// `BuiltinColumn::is_null`'s diagnostic so the two are interchangeable
/// through `ColumnStorage`.
pub fn NumericColumn::is_null(
  self : NumericColumn,
  index : Int,
) -> Bool raise @types.DataError {
  if index < 0 || index >= self.len() {
    raise @types.DataError::IndexOutOfBounds(index)
  }
  false
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index
/// `raise IndexOutOfBounds`. No null branch: a slot in `[0, len)` is always a
/// present value, so the read skips the validity check `BuiltinColumn::get`
/// must perform.
pub fn NumericColumn::get(
  self : NumericColumn,
  index : Int,
) -> @types.Scalar raise @types.DataError {
  if index < 0 || index >= self.len() {
    raise @types.DataError::IndexOutOfBounds(index)
  }
  match self.data {
    Int(a) => @types.Scalar::Int(a[index])
    Float(a) => @types.Scalar::Float(a[index])
  }
}

// ── Sub-views (no bitmap to repack — the construction win) ─────────────

///|
/// Half-open `[start, end)` slice. Requires `0 <= start <= end <= len`, with
/// the same diagnostics (and check order) as `BuiltinColumn::slice`:
/// - `IndexOutOfBounds(start)` when `start < 0`.
/// - `IndexOutOfBounds(end)` when `end > len`.
/// - `InvalidOperation("slice start > end: ...")` when `start > end`.
///
/// Stays a `NumericColumn` — a sub-range of an all-valid column is itself
/// all-valid, so there is no bitmap to slice (the win over
/// `BuiltinColumn::slice`, which repacks one).
pub fn NumericColumn::slice(
  self : NumericColumn,
  start : Int,
  end : Int,
) -> NumericColumn raise @types.DataError {
  validate_slice_bounds(start, end, self.len())
  self.slice_unchecked(start, end)
}

///|
/// Total `[start, end)` slice — the shared core behind `slice` (which
/// validates the bounds then calls this). Copies the sub-range; an all-valid
/// column stays all-valid, so there is still no bitmap. The caller must
/// guarantee `0 <= start <= end <= len` (enforced by `slice`, clamped by
/// `ColumnStorage::slice_total`).
fn NumericColumn::slice_unchecked(
  self : NumericColumn,
  start : Int,
  end : Int,
) -> NumericColumn {
  let n = end - start
  match self.data {
    Int(a) => { data: Int(Array::makei(n, i => a[start + i])) }
    Float(a) => { data: Float(Array::makei(n, i => a[start + i])) }
  }
}

///|
/// Gather: produce a new column whose i-th entry is `self[indices[i]]`. Any
/// out-of-bounds index `raise IndexOutOfBounds(idx)`, matching
/// `BuiltinColumn::take`. Stays a `NumericColumn` (no bitmap to gather).
pub fn NumericColumn::take(
  self : NumericColumn,
  indices : Array[Int],
) -> NumericColumn raise @types.DataError {
  validate_gather_indices(indices, self.len())
  match self.data {
    Int(a) => { data: Int(indices.map(i => a[i])) }
    Float(a) => { data: Float(indices.map(i => a[i])) }
  }
}

// ── Typed accessors (zero-boxing; all-valid bitmap synthesised) ────────

///|
/// Return the raw `Int64` array paired with an all-valid `Bitmap` sized to
/// the column, matching `BuiltinColumn::int_values`' `(data, validity)` shape
/// so the two are interchangeable through `ColumnStorage`. The bitmap is
/// synthesised on demand — the column stores none. `raise
/// TypeMismatch(Column(Int, Float))` when this is a `Float` column.
pub fn NumericColumn::int_values(
  self : NumericColumn,
) -> (Array[Int64], Bitmap) raise @types.DataError {
  match self.data {
    Int(a) => (a, Bitmap::all_valid(a.length()))
    Float(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Column(@types.DataType::Int, self.dtype()),
      )
  }
}

///|
/// Like `int_values` but for `Float` columns. `raise
/// TypeMismatch(Column(Float, Int))` when this is an `Int` column.
pub fn NumericColumn::float_values(
  self : NumericColumn,
) -> (Array[Double], Bitmap) raise @types.DataError {
  match self.data {
    Float(a) => (a, Bitmap::all_valid(a.length()))
    Int(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Column(@types.DataType::Float, self.dtype()),
      )
  }
}

///|
/// Always `raise TypeMismatch(Column(...))` — a `NumericColumn` is numeric by
/// construction, so it never holds `Bool` cells. Present so
/// `ColumnStorage::bool_values` can forward to both arms uniformly.
pub fn NumericColumn::bool_values(
  self : NumericColumn,
) -> (Array[Bool], Bitmap) raise @types.DataError {
  raise @types.DataError::TypeMismatch(
    @types.TypeMismatchDetail::Column(@types.DataType::Bool, self.dtype()),
  )
}

///|
/// Always `raise TypeMismatch(Column(...))` — a `NumericColumn` never holds `String`
/// cells. Present so `ColumnStorage::string_values` forwards uniformly.
pub fn NumericColumn::string_values(
  self : NumericColumn,
) -> (Array[String], Bitmap) raise @types.DataError {
  raise @types.DataError::TypeMismatch(
    @types.TypeMismatchDetail::Column(@types.DataType::String, self.dtype()),
  )
}

// ── Materialise ───────────────────────────────────────────────────────

///|
/// Widen to a `BuiltinColumn` with an all-valid validity bitmap. Total and
/// lossless: the data array is reused (the source column owns it and is
/// immutable, so the two may safely share it) and `Bitmap::all_valid(len)`
/// records that every slot is present. The widening is value-preserving — it
/// equals `BuiltinColumn::from_ints` / `from_floats` on the same data (proven
/// in `numeric_test.mbt`). It reuses the array via a struct literal rather than
/// `from_ints` / `from_floats`, which now defensively copy.
pub fn NumericColumn::to_builtin(self : NumericColumn) -> BuiltinColumn {
  match self.data {
    Int(a) =>
      { data: ColumnData::Int(a), validity: Bitmap::all_valid(a.length()) }
    Float(a) =>
      { data: ColumnData::Float(a), validity: Bitmap::all_valid(a.length()) }
  }
}

///|
/// Render every cell to its `String` value-form, yielding a `String`
/// `BuiltinColumn` (a numeric column cannot stay `Numeric` once stringified).
/// Total: an all-valid numeric column has no null placeholder and no
/// non-renderable cell, so this routes through `to_builtin` and reuses
/// `BuiltinColumn::to_string_column` rather than duplicating the rendering.
pub fn NumericColumn::to_string_column(self : NumericColumn) -> BuiltinColumn {
  self.to_builtin().to_string_column()
}

// ── Reductions (all-valid fast path) ──────────────────────────────────

///|
/// Plain `Int64` fold over the whole array — every slot is present, so unlike
/// the general `Builtin`-backend reduction there is no `validity().to_bools()`
/// and no per-slot `if valid[i]` branch. Used by `sum`, which keeps the `Int`
/// dtype (so sums past 2^63 overflow — the price of an exact integer sum).
/// `mean`, whose output is `Double`, widens through `fold_int_as_double`
/// instead: an `Int64` accumulator there would wrap past 2^63 and flip the
/// mean's sign even though `Double` represents the true value.
fn fold_int64(a : Array[Int64]) -> Int64 {
  let mut acc : Int64 = 0
  for x in a {
    acc = acc + x
  }
  acc
}

///|
/// Fold an `Int64` array into a `Double`, widening each cell before adding.
/// The accumulator behind `mean` for an `Int` column: because the mean's output
/// is `Double`, accumulating in `Double` from the start cannot wrap past 2^63
/// (which would flip the sign, yielding a mean outside `[min, max]`), unlike
/// `fold_int64`. Matches Polars, which computes an `Int`-column mean in f64.
fn fold_int_as_double(a : Array[Int64]) -> Double {
  let mut acc : Double = 0.0
  for x in a {
    acc = acc + x.to_double()
  }
  acc
}

///|
/// Plain `Double` fold over the whole array. `NaN` participates (it is a
/// present value, not missing), so a single `NaN` cell propagates to a `NaN`
/// total — Polars `sum` / `mean` semantics. Shared by `sum` and `mean`.
fn fold_double(a : Array[Double]) -> Double {
  let mut acc : Double = 0.0
  for x in a {
    acc = acc + x
  }
  acc
}

///|
/// Sum of every cell.
///
/// - `Int` → `Scalar::Int`, accumulated in 64-bit `Int64` (sums past the
///   32-bit ceiling do not overflow).
/// - `Float` → `Scalar::Float`, accumulated in `Double`; a `NaN` cell
///   propagates (Polars semantics — `NaN` is a value, not missing).
/// - Empty → the additive identity (`Scalar::Int(0)` / `Scalar::Float(0.0)`).
///
/// Total. There is no missing value to skip and no non-numeric dtype to
/// reject, so — unlike `Series::sum`, which `raise`s `TypeMismatch` for
/// `Bool` / `String` — this never fails. Keeping it total rather than
/// propagating an impossible `raise` avoids a dead `Err` arm that would break
/// 100% coverage (`feedback_lib_no_abort`).
pub fn NumericColumn::sum(self : NumericColumn) -> @types.Scalar {
  match self.data {
    Int(a) => @types.Scalar::Int(fold_int64(a))
    Float(a) => @types.Scalar::Float(fold_double(a))
  }
}

///|
/// Arithmetic mean of every cell, as a `Double` (matching `Series::mean`).
///
/// The denominator is the cell count `len` — every slot is present, so there
/// is no non-null count to compute. A `Float` `NaN` propagates through the
/// sum to a `NaN` mean (Polars semantics).
///
/// `raise InvalidOperation` on an empty column: the mean of zero values is
/// undefined (`0 / 0`), a genuine failure mode (unlike `sum`'s identity), so
/// the `raise` is real rather than an impossible one — it does not leave a
/// dead arm.
pub fn NumericColumn::mean(
  self : NumericColumn,
) -> Double raise @types.DataError {
  let n = self.len()
  if n == 0 {
    raise @types.DataError::InvalidOperation("mean of empty column")
  }
  let total = match self.data {
    Int(a) => fold_int_as_double(a)
    Float(a) => fold_double(a)
  }
  total / n.to_double()
}

///|
/// Minimum cell as a `Scalar`, by the dtype's natural order. Total, matching
/// `Series::min`:
/// - Empty column → `Scalar::Null`.
/// - `Float` `NaN` is skipped (treated as missing for the extremum, as in
///   `sort` and Polars' regular `min` — distinct from `sum` / `mean`,
///   where it propagates). An all-`NaN` `Float` column → `Scalar::Null`.
pub fn NumericColumn::min(self : NumericColumn) -> @types.Scalar {
  self.extremum(want_min=true)
}

///|
/// Maximum cell as a `Scalar`. Mirrors `min` with `>` for `<`; the
/// `Float` `NaN`-skip and empty rules are identical. Total.
pub fn NumericColumn::max(self : NumericColumn) -> @types.Scalar {
  self.extremum(want_min=false)
}

///|
/// Shared min/max kernel: the natural-order extremum over the cells, `want_min`
/// choosing `<` over `>`. `Float` `NaN` is skipped (missing for the extremum,
/// as in `sort` / Polars' regular min/max); an empty or all-`NaN` column yields
/// `Scalar::Null`. `min` / `max` are this with `want_min` true / false — the
/// comparison is the only difference, so it is the only thing parameterised
/// (the `fold_extremum` operand type differs per dtype arm, so the closure
/// stays inline rather than shared). Total.
fn NumericColumn::extremum(
  self : NumericColumn,
  want_min~ : Bool,
) -> @types.Scalar {
  match self.data {
    Int(a) => {
      let get = i => a[i]
      let skip = fn(_i) { false }
      let better = (x, y) => if want_min { x < y } else { x > y }
      let best = @types.fold_extremum(a.length(), get, skip, better)
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Int(b)
      }
    }
    Float(a) => {
      let get = i => a[i]
      let skip = i => a[i].is_nan()
      let better = (x, y) => if want_min { x < y } else { x > y }
      let best = @types.fold_extremum(a.length(), get, skip, better)
      match best {
        None => @types.Scalar::Null
        Some(b) => @types.Scalar::Float(b)
      }
    }
  }
}
