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
///   1. **construction** allocates no validity `Bytes` (`from_int64s` is just
///      the data array — `BuiltinColumn::from_ints` additionally allocates
///      `Bitmap::all_valid(len)`);
///   2. **reductions** (`sum`) fold the raw array directly, with no
///      `validity().to_bools()` materialisation and no per-slot `if valid[i]`
///      branch that `Series::sum`'s `sum_int_valid` must run.
///
/// ── S0 spike scope ─────────────────────────────────────────────────────
/// This is the Stage 2 spike (`PLAN_v0.3.md` §3 S0): the minimal slice
/// needed to validate the three uncertain points before the `Series.storage`
/// flip — `from_int64s` + `sum` + `to_builtin` + `get`, plus the accessors
/// `ColumnStorage` forwards through (`len` / `dtype` / `null_count` / `data`).
/// S1 extends `NumericData` with the `Float(Array[Double])` variant
/// (`from_doubles`, Float reductions, `mean`/`min_value`/`max_value`,
/// `slice`/`take`/`*_values`). Folds forward additively — no rewrite.
pub struct NumericColumn {
  data : NumericData
} derive(Eq, Debug)

///|
/// Backing storage for `NumericColumn`, discriminated by dtype. The element
/// type is the raw value; there is no nullability to track (every slot is
/// valid). S0 ships the `Int` arm only; S1 adds `Float(Array[Double])`.
pub(all) enum NumericData {
  Int(Array[Int64])
} derive(Eq, Debug)

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Build an `Int` column from raw values. There is no null path — pass
/// through `BuiltinColumn::from_int_options` (then `to_numeric`) if any cell
/// may be missing. No validity `Bitmap` is allocated.
pub fn NumericColumn::from_int64s(values : Array[Int64]) -> NumericColumn {
  { data: Int(values) }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
pub fn NumericColumn::dtype(self : NumericColumn) -> @types.DataType {
  match self.data {
    Int(_) => @types.DataType::Int
  }
}

///|
pub fn NumericColumn::len(self : NumericColumn) -> Int {
  match self.data {
    Int(a) => a.length()
  }
}

///|
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
/// `ColumnStorage::Numeric` arm) read values through the same total
/// `data()` surface `BuiltinColumn` exposes. The element array is shared
/// (read-only).
pub fn NumericColumn::data(self : NumericColumn) -> ColumnData {
  match self.data {
    Int(a) => ColumnData::Int(a)
  }
}

///|
/// Read a single cell as a `Scalar`. Out-of-bounds index
/// `raise IndexOutOfBounds`. No null branch: a slot in `[0, len)` is always
/// a present value, so the read skips the validity check `BuiltinColumn::get`
/// must perform.
pub fn NumericColumn::get(
  self : NumericColumn,
  index : Int,
) -> @types.Scalar raise @types.DataError {
  match self.data {
    Int(a) => {
      if index < 0 || index >= a.length() {
        raise @types.DataError::IndexOutOfBounds(index)
      }
      @types.Scalar::Int(a[index])
    }
  }
}

// ── Materialise ───────────────────────────────────────────────────────

///|
/// Widen to a `BuiltinColumn` with an all-valid validity bitmap. Total and
/// lossless: the data array is reused and `Bitmap::all_valid(len)` records
/// that every slot is present. This is the inverse of `to_numeric` on an
/// all-valid numeric `BuiltinColumn` — round-tripping either way is
/// value-preserving (proven in `numeric_test.mbt`).
pub fn NumericColumn::to_builtin(self : NumericColumn) -> BuiltinColumn {
  match self.data {
    Int(a) => BuiltinColumn::from_ints(a)
  }
}

// ── Reductions (all-valid fast path) ──────────────────────────────────

///|
/// Sum of every cell, accumulated in 64-bit `Int64`.
///
/// Total — there is no missing value to skip and no non-numeric dtype to
/// reject, so unlike `Series::sum` (which `raise`s `TypeMismatch` for
/// `Bool` / `String`) this never fails. An empty column sums to the additive
/// identity `Scalar::Int(0)`. The fold reads the raw array with no
/// `validity().to_bools()` materialisation and no per-slot validity branch —
/// the measurable reduction win over the `BuiltinColumn` path.
///
/// (`PLAN_v0.3.md` §6 lists `sum` as `raise`; the spike keeps it **total**
/// per `feedback_lib_no_abort` — an always-numeric, all-valid column has no
/// failure mode, and a propagated impossible `raise` would leave a dead
/// `Err` arm that breaks 100% coverage. Recorded in `SPIKE_S0.md`.)
pub fn NumericColumn::sum(self : NumericColumn) -> @types.Scalar {
  match self.data {
    Int(a) => {
      let mut acc : Int64 = 0
      for x in a {
        acc = acc + x
      }
      @types.Scalar::Int(acc)
    }
  }
}
