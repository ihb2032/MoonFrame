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
/// The win is twofold and measurable (construction in `numeric_wbtest.mbt`,
/// reductions in `numeric_reduce_wbtest.mbt`):
///   1. **construction / sub-views** allocate no validity `Bytes`:
///      `from_ints` / `from_floats` are just the data array, and `slice` /
///      `take` copy only the data — where `BuiltinColumn` additionally
///      allocates a `Bitmap` (`from_ints`), repacks one (`take`), or carries a
///      zero-copy view of its parent's (`slice`);
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
/// all-valid numeric `Series`, not just a parallel implementation (the folds
/// live in `numeric_reduce.mbt`). Cross-dtype
/// transforms
/// (`cast` / `to_int` / `to_float`) are
/// intentionally absent: `ColumnStorage::cast` widens to the `Builtin` backend
/// and lets `BuiltinColumn` do the work, keeping this type to the fast-path
/// operations that actually benefit from the missing bitmap.
pub struct NumericColumn {
  priv data : NumericData
} derive(Debug)

///|

///|
pub extend NumericColumn with Debug::{to_repr}

///|
/// Backing storage for `NumericColumn`, discriminated by dtype. The element
/// type is the raw value; there is no nullability to track (every slot is
/// valid). Numeric only — `Bool` / `String` columns are always backed by a
/// `BuiltinColumn`, so `NumericData` has just the two numeric arms.
pub(all) enum NumericData {
  Int(ArrayView[Int64])
  Float(ArrayView[Double])
} derive(Debug)

///|

///|
pub extend NumericData with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values. There is no null path — if any cell
/// may be missing, build a `BuiltinColumn` (`from_int_options`) and keep the
/// column `Builtin` instead. No validity `Bitmap` is allocated. `values` is
/// copied, so the column owns its data.
pub fn NumericColumn::from_ints(values : ArrayView[Int64]) -> NumericColumn {
  { data: Int(values.to_owned()), }
}

///|
/// Build a `Float` column from raw values. As with `from_ints` there is no
/// null path and no validity `Bitmap`. `NaN` is a perfectly valid stored
/// value here — it is *not* a missing marker (only an absent slot is, and
/// this column has none) — and it participates in reductions exactly as
/// Polars treats it: propagating through `sum` / `mean`, skipped by
/// `min` / `max`. `values` is copied, so the column owns its data.
pub fn NumericColumn::from_floats(values : ArrayView[Double]) -> NumericColumn {
  { data: Float(values.to_owned()), }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// The column's logical `DataType` — `Int` or `Float` (a `NumericColumn` is
/// numeric by construction).
fn NumericColumn::dtype(self : NumericColumn) -> @types.DataType {
  match self.data {
    Int(_) => @types.DataType::Int
    Float(_) => @types.DataType::Float
  }
}

///|
/// Number of cells.
fn NumericColumn::len(self : NumericColumn) -> Int {
  match self.data {
    Int(a) => a.length()
    Float(a) => a.length()
  }
}

///|
/// `true` when the column has no cells.
fn NumericColumn::is_empty(self : NumericColumn) -> Bool {
  self.len() == 0
}

///|
/// Always `0`: an all-valid column has no nulls by construction. Total — no
/// bitmap to popcount, the answer is structural.
fn NumericColumn::null_count(_self : NumericColumn) -> Int {
  0
}

///|
/// The unboxed buffer as the two-variant `NumericData` this backend can
/// actually hold. `data()` widens the same array into the four-variant
/// `ColumnData` every backend shares, which costs a vectorized pass two arms
/// that cannot happen; the kernels match this instead. The array is shared
/// (read-only), and the field itself is package-private so the buffer is
/// reached by a name the surface audit can see.
pub fn NumericColumn::numeric_data(self : NumericColumn) -> NumericData {
  self.data
}

///|
/// The raw backing storage as a `ColumnData`, so callers (and the
/// `ColumnStorage::Numeric` arm) read values through the same total `data()`
/// surface `BuiltinColumn` exposes. The element array is shared (read-only).
fn NumericColumn::data(self : NumericColumn) -> ColumnData {
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
fn NumericColumn::is_null(
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
fn NumericColumn::get(
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
/// - `IndexOutOfBounds(end)` when `end` is outside `[0, len]`.
/// - `InvalidOperation("slice start > end: ...")` when `start > end`.
///
/// Stays a `NumericColumn` — a sub-range of an all-valid column is itself
/// all-valid, so there is no bitmap here at all, where `BuiltinColumn::slice`
/// still carries a zero-copy view of its parent's.
fn NumericColumn::slice(
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
    Int(a) => { data: Int(Array::makei(n, i => a[start + i])), }
    Float(a) => { data: Float(Array::makei(n, i => a[start + i])), }
  }
}

///|
/// Gather: produce a new column whose i-th entry is `self[indices[i]]`. Any
/// out-of-bounds index `raise IndexOutOfBounds(idx)`, matching
/// `BuiltinColumn::take`. Stays a `NumericColumn` (no bitmap to gather).
fn NumericColumn::take(
  self : NumericColumn,
  indices : Array[Int],
) -> NumericColumn raise @types.DataError {
  validate_gather_indices(indices, self.len())
  match self.data {
    Int(a) => { data: Int(indices.map(i => a[i])), }
    Float(a) => { data: Float(indices.map(i => a[i])), }
  }
}

// ── Materialise ───────────────────────────────────────────────────────

///|
/// Widen to a `BuiltinColumn` with an all-valid validity bitmap. Total and
/// lossless: the data array is reused (the source column owns it and is
/// immutable, so the two may safely share it) and `Bitmap::all_valid(len)`
/// records that every slot is present. The widening is value-preserving — it
/// equals `BuiltinColumn::from_ints` / `from_floats` on the same data (proven
/// in `numeric_wbtest.mbt`). It reuses the array via a struct literal rather than
/// `from_ints` / `from_floats`, which now defensively copy.
fn NumericColumn::to_builtin(self : NumericColumn) -> BuiltinColumn {
  match self.data {
    Int(a) =>
      { data: ColumnData::Int(a), validity: Bitmap::all_valid(a.length()), }
    Float(a) =>
      { data: ColumnData::Float(a), validity: Bitmap::all_valid(a.length()), }
  }
}
