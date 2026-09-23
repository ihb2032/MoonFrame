// The single-column sort kernel: resolve a column into a typed key with a
// pre-computed missing mask, and compare two of its cells under a direction
// and a missing-placement rule. `Series::sort` and `frame`'s multi-key
// `DataFrame::sort` both build on this, so one column's ordering means the
// same thing either way; both then hand the comparator to the stable index
// sort, which knows nothing about columns.

///|
/// Resolve a column into a typed `SortKey`, matching on the concrete backing
/// array via `storage.data()` — `ColumnData`'s four variants are exhaustive,
/// so there's no fallback branch to `unwrap`.
/// Missingness (`Null`, plus `NaN` for `Float`) is pre-computed into a
/// dense `Array[Bool]` here, once per key, so the comparator reads it by
/// plain index instead of repeating a bitmap lookup on every comparison.
/// Takes the `Series` and reaches its storage here, so `frame`'s multi-key
/// sort hands over a column rather than a storage representation.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn build_sort_key(
  column : Series,
  descending : Bool,
  nulls_last : Bool,
) -> SortKey {
  // `validity_bools` is total over both backends: a `Numeric` column carries
  // only `Int` / `Float` and is all-valid (mask all-`true`), while `Bool` /
  // `String` are always `Builtin` — so for a `Numeric` `Float` the only
  // "missing" source is the `is_nan` test in the `Float` arm below.
  let valid = validity_bools(column)
  let storage = column.storage
  match storage.data() {
    @column.ColumnData::I64(a) =>
      SortKey::Int(
        a,
        Array::makei(a.length(), i => !valid[i]),
        descending,
        nulls_last,
      )
    @column.ColumnData::F64(a) =>
      // NaN behaves like Null for ordering.
      SortKey::Float(
        a,
        Array::makei(a.length(), i => !valid[i] || a[i].is_nan()),
        descending,
        nulls_last,
      )
    @column.ColumnData::Bool(a) =>
      SortKey::Bool(
        a,
        Array::makei(a.length(), i => !valid[i]),
        descending,
        nulls_last,
      )
    @column.ColumnData::Utf8(a) =>
      // Decoded once here: comparisons during the sort read the materialised
      // strings rather than decoding per comparison.
      SortKey::String(
        a.to_strings(),
        Array::makei(a.len(), i => !valid[i]),
        descending,
        nulls_last,
      )
  }
}

// ── Internal: the resolved key and its comparator ─────────────────────

///|
/// Module-internal resolved form of a sort key — an engine seam, not a public
/// type: the variants stay unnameable outside this package, while `frame`'s
/// multi-key sort holds one to compare with. The raw data buffer, a
/// dense per-row `missing` mask (`Null`, or `NaN` for `Float`), and the
/// per-key direction / null placement (`descending`, `nulls_last`).
/// Pre-resolving missingness lets
/// the comparator stay branch-free per element type (no `Scalar` boxing,
/// no per-comparison bitmap lookup).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub enum SortKey {
  Int(ArrayView[Int64], Array[Bool], Bool, Bool)
  Float(ArrayView[Double], Array[Bool], Bool, Bool)
  Bool(ArrayView[Bool], Array[Bool], Bool, Bool)
  String(ArrayView[String], Array[Bool], Bool, Bool)
}

///|
/// Single-key comparison. The validity bitmap (and, for `Float`, the
/// NaN check) decides "missing"; missingness combines with
/// `nulls_last` to place missing cells, and only non-missing pairs
/// reach the value comparison + `descending` flip.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn compare_one_key(key : SortKey, i : Int, j : Int) -> Int {
  match key {
    Int(data, missing, descending, nulls_last) => {
      // `missing` was materialised over `[0, n)`; `i`, `j` come from the
      // `[0, n)` permutation, so the index is in-bounds (like `data[i]`).
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, nulls_last, descending, fn() {
        let a = data[i]
        let b = data[j]
        if a < b {
          -1
        } else if a > b {
          1
        } else {
          0
        }
      })
    }
    Float(data, missing, descending, nulls_last) => {
      // NaN was already folded into `missing` at build time, so the value
      // comparison below only runs on two non-NaN, non-null cells.
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, nulls_last, descending, fn() {
        let a = data[i]
        let b = data[j]
        if a < b {
          -1
        } else if a > b {
          1
        } else {
          0
        }
      })
    }
    Bool(data, missing, descending, nulls_last) => {
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, nulls_last, descending, fn() {
        let a = data[i]
        let b = data[j]
        // `false < true`, the Bool order the comparison kernel uses.
        if !a && b {
          -1
        } else if a && !b {
          1
        } else {
          0
        }
      })
    }
    String(data, missing, descending, nulls_last) => {
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, nulls_last, descending, fn() {
        @text.compare_string_lex(data[i], data[j])
      })
    }
  }
}

///|
/// Combine missingness (post-NaN classification), null placement, and
/// sort direction into a single -1 / 0 / 1 comparison result. `cmp_valid`
/// is only invoked when both sides are non-missing.
fn compare_with_missing(
  mi : Bool,
  mj : Bool,
  nulls_last : Bool,
  descending : Bool,
  cmp_valid : () -> Int,
) -> Int {
  match (mi, mj) {
    (true, true) => 0
    (true, false) => missing_offset(nulls_last)
    (false, true) => -missing_offset(nulls_last)
    (false, false) => {
      let raw = cmp_valid()
      if descending {
        -raw
      } else {
        raw
      }
    }
  }
}

///|
/// `-1` when missing sorts before non-missing (`nulls_last = false`), `1`
/// when missing sorts after non-missing (`nulls_last = true`). The sign is
/// applied from the left-hand side's perspective in `compare_with_missing`.
fn missing_offset(nulls_last : Bool) -> Int {
  if nulls_last {
    1
  } else {
    -1
  }
}

///|
/// Sort the series' own values, returning a new series with the same name —
/// Polars' `Series.sort`. `descending` defaults to ascending and
/// `nulls_last` to `false` — Polars' own default, which places missing cells
/// first in an ascending sort — and both mean exactly what they mean for the
/// corresponding `DataFrame::sort` key flags: the same kernel resolves the
/// column, so a `Float` `NaN` counts as missing alongside `Null` (the
/// repository's deliberate ordering convention) and ties keep their input
/// order — the sort is stable.
///
/// Total: every dtype has an order, and the permutation indexes the series
/// itself, so nothing can fail.
pub fn Series::sort(
  self : Series,
  descending? : Bool = false,
  nulls_last? : Bool = false,
) -> Series {
  let key = build_sort_key(self, descending, nulls_last)
  let perm = @order.stable_mergesort_indices(self.len(), (i, j) => {
    compare_one_key(key, i, j)
  })
  gather_series(self, perm)
}
