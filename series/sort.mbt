// The single-column sort kernel: resolve a column into a typed key with a
// pre-computed missing mask, compare two of its cells under a direction and
// a missing-placement rule, and order indices with a stable bottom-up
// mergesort. `Series::sort` and `frame`'s multi-key `DataFrame::sort` both
// build on this, so one column's ordering means the same thing either way.

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
  order : @types.SortOrder,
  null_order : @types.NullOrder,
) -> SortKey {
  // `validity_bools` is total over both backends: a `Numeric` column carries
  // only `Int` / `Float` and is all-valid (mask all-`true`), while `Bool` /
  // `String` are always `Builtin` — so for a `Numeric` `Float` the only
  // "missing" source is the `is_nan` test in the `Float` arm below.
  let valid = validity_bools(column)
  let storage = column.storage
  match storage.data() {
    @column.ColumnData::Int(a) =>
      SortKey::Int(
        a,
        Array::makei(a.length(), i => !valid[i]),
        order,
        null_order,
      )
    @column.ColumnData::Float(a) =>
      // NaN behaves like Null for ordering (see `sort`).
      SortKey::Float(
        a,
        Array::makei(a.length(), i => !valid[i] || a[i].is_nan()),
        order,
        null_order,
      )
    @column.ColumnData::Bool(a) =>
      SortKey::Bool(
        a,
        Array::makei(a.length(), i => !valid[i]),
        order,
        null_order,
      )
    @column.ColumnData::String(a) =>
      SortKey::String(
        a,
        Array::makei(a.length(), i => !valid[i]),
        order,
        null_order,
      )
  }
}

// ── Internal: comparator + stable mergesort ───────────────────────────

///|
/// Package-private resolved form of a sort key: the raw data buffer, a
/// dense per-row `missing` mask (`Null`, or `NaN` for `Float`), and the
/// per-key direction / null placement. Pre-resolving missingness lets
/// the comparator stay branch-free per element type (no `Scalar` boxing,
/// no per-comparison bitmap lookup).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub enum SortKey {
  Int(Array[Int64], Array[Bool], @types.SortOrder, @types.NullOrder)
  Float(Array[Double], Array[Bool], @types.SortOrder, @types.NullOrder)
  Bool(Array[Bool], Array[Bool], @types.SortOrder, @types.NullOrder)
  String(Array[String], Array[Bool], @types.SortOrder, @types.NullOrder)
}

///|
/// Single-key comparison. The validity bitmap (and, for `Float`, the
/// NaN check) decides "missing"; missingness combines with
/// `null_order` to place missing cells, and only non-missing pairs
/// reach the value comparison + `order` flip.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn compare_one_key(key : SortKey, i : Int, j : Int) -> Int {
  match key {
    Int(data, missing, order, null_order) => {
      // `missing` was materialised over `[0, n)`; `i`, `j` come from the
      // `[0, n)` permutation, so the index is in-bounds (like `data[i]`).
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, null_order, order, fn() {
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
    Float(data, missing, order, null_order) => {
      // NaN was already folded into `missing` at build time, so the value
      // comparison below only runs on two non-NaN, non-null cells.
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, null_order, order, fn() {
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
    Bool(data, missing, order, null_order) => {
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, null_order, order, fn() {
        let a = data[i]
        let b = data[j]
        // `false < true`, matching `Scalar::lt` on Bool.
        if !a && b {
          -1
        } else if a && !b {
          1
        } else {
          0
        }
      })
    }
    String(data, missing, order, null_order) => {
      let mi = missing[i]
      let mj = missing[j]
      compare_with_missing(mi, mj, null_order, order, fn() {
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
  null_order : @types.NullOrder,
  order : @types.SortOrder,
  cmp_valid : () -> Int,
) -> Int {
  match (mi, mj) {
    (true, true) => 0
    (true, false) => missing_offset(null_order)
    (false, true) => -missing_offset(null_order)
    (false, false) => {
      let raw = cmp_valid()
      match order {
        @types.Asc => raw
        @types.Desc => -raw
      }
    }
  }
}

///|
/// `-1` when missing sorts before non-missing (`@types.NullsFirst`), `1` when
/// missing sorts after non-missing (`@types.NullsLast`). The sign is applied
/// from the left-hand side's perspective in `compare_with_missing`.
fn missing_offset(null_order : @types.NullOrder) -> Int {
  match null_order {
    @types.NullsFirst => -1
    @types.NullsLast => 1
  }
}

///|
/// Sort the series' own values, returning a new series with the same name —
/// Polars' `Series.sort`. `order` defaults to ascending and `nulls` to
/// `NullsLast`, and both mean exactly what they mean for `DataFrame::sort`:
/// the same kernel resolves the column, so a `Float` `NaN` counts as missing
/// alongside `Null` (the repository's deliberate ordering convention) and
/// ties keep their input order — the sort is stable.
///
/// Total: every dtype has an order, and the permutation indexes the series
/// itself, so nothing can fail.
pub fn Series::sort(
  self : Series,
  order? : @types.SortOrder = Asc,
  nulls? : @types.NullOrder = NullsLast,
) -> Series {
  let key = build_sort_key(self, order, nulls)
  let perm = @order.stable_mergesort_indices(self.len(), (i, j) => {
    compare_one_key(key, i, j)
  })
  gather_series(self, perm)
}

///|
/// The first `n` cells, or every cell when `n` exceeds the length — the
/// `Series` twin of `DataFrame::head`. A negative `n` clamps to an empty
/// series. Total.
pub fn Series::head(self : Series, n : Int) -> Series {
  slice_series(self, 0, @order.clamp_take(n, self.len()))
}

///|
/// The last `n` cells, or every cell when `n` exceeds the length — the
/// `Series` twin of `DataFrame::tail`. A negative `n` clamps to an empty
/// series. Total.
pub fn Series::tail(self : Series, n : Int) -> Series {
  let len = self.len()
  let take = @order.clamp_take(n, len)
  // `slice_series`' third argument is the window *length*, not the end index —
  // pass `take` (as `DataFrame::tail` does), so `start + take == len` stays in
  // bounds. Passing `len` here relied on the slice clamping an over-large end
  // back down, and `start + len` overflows `Int` for a column past ~2^30 rows,
  // wrapping negative and yielding an empty result.
  slice_series(self, len - take, take)
}

///|
/// The cells in reverse order, name unchanged — Polars' `Series.reverse`.
/// Total.
pub fn Series::reverse(self : Series) -> Series {
  let len = self.len()
  gather_series(self, Array::makei(len, i => len - 1 - i))
}
