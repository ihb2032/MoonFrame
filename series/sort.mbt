// The single-column sort kernel: resolve a column into a typed key with a
// pre-computed missing mask, compare two of its cells under a direction and
// a missing-placement rule, and order indices with a stable bottom-up
// mergesort. `Series::sort` and `frame`'s multi-key `DataFrame::sort` both
// build on this, so one column's ordering means the same thing either way.

///|
/// Resolve a column's `ColumnStorage` into a typed `SortKey`, matching on
/// the concrete backing array via `storage.data()` — `ColumnData`'s four
/// variants are exhaustive, so there's no fallback branch to `unwrap`.
/// Missingness (`Null`, plus `NaN` for `Float`) is pre-computed into a
/// dense `Array[Bool]` here, once per key, so the comparator reads it by
/// plain index instead of repeating a bitmap lookup on every comparison.
/// Reads only `validity()` / `data()`, both of which `ColumnStorage`
/// forwards, so the v0.3 `Series::storage()` flip needed no logic change
/// here — only this parameter's type.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn build_sort_key(
  storage : @column.ColumnStorage,
  order : @types.SortOrder,
  null_order : @types.NullOrder,
) -> SortKey {
  // `validity_bools` is total over both backends: a `Numeric` column carries
  // only `Int` / `Float` and is all-valid (mask all-`true`), while `Bool` /
  // `String` are always `Builtin` — so for a `Numeric` `Float` the only
  // "missing" source is the `is_nan` test in the `Float` arm below.
  let valid = validity_bools(storage)
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
pub(all) enum SortKey {
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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn compare_with_missing(
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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn missing_offset(null_order : @types.NullOrder) -> Int {
  match null_order {
    @types.NullsFirst => -1
    @types.NullsLast => 1
  }
}

///|
/// The next bottom-up merge width, or `None` once the current run already
/// covers at least half of `n`. The guards make this total for every `Int`:
/// subtraction only happens after `0 < width < n`, and doubling only happens
/// when `width < n - width`, which proves `2 * width < n <= Int::MAX`.
/// Keeping this arithmetic separate lets tests exercise the `2^30` boundary
/// without allocating multi-gigabyte sort buffers.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn next_merge_width(width : Int, n : Int) -> Int? {
  if width <= 0 || n <= 1 || width >= n {
    return None
  }
  if width >= n - width {
    None
  } else {
    Some(width * 2)
  }
}

///|
/// Iterative bottom-up stable merge sort over the index permutation
/// `[0, 1, ..., n - 1]`. Returns the permutation that, when applied to
/// any length-`n` array via `take`, yields the data in `cmp` order.
///
/// Stability comes from the `<= 0` tie-break in `merge_run`: on equal
/// keys, the left run's element is emitted first, which preserves the
/// original relative order (left run came before right run in the
/// input).
///
/// Complexity: `O(n log n)` comparisons, `O(n)` auxiliary memory
/// (two buffers of length `n`).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn stable_mergesort_indices(n : Int, cmp : (Int, Int) -> Int) -> Array[Int] {
  let buf = Array::makei(n, i => i)
  if n <= 1 {
    return buf
  }
  let aux = Array::make(n, 0)
  let mut width = 1
  while width < n {
    let mut start = 0
    while start < n {
      let left = start
      // Derive the run boundaries by subtraction against the room left
      // (`n - start`, `n - mid`) rather than `start + width` / `start + 2*width`,
      // so the arithmetic can't overflow `Int` on a pathologically large `n`
      // (the overflow-avoidance `bitmap.mbt` also uses). `right_end` is the
      // second run's end, so advancing `start` to it equals the old
      // `start + 2*width`: both land at `min(start + 2*width, n)` and end the
      // pass once they reach `n`.
      let mid = if width < n - start { start + width } else { n }
      let right_end = if width < n - mid { mid + width } else { n }
      merge_run(buf, aux, left, mid, right_end, cmp)
      start = right_end
    }
    // Copy the merged pass back into `buf` so the next pass reads
    // from a contiguous source.
    for k in 0..<n {
      buf[k] = aux[k]
    }
    match next_merge_width(width, n) {
      Some(next) => width = next
      None => break
    }
  }
  buf
}

///|
/// Merge `src[left..mid)` and `src[mid..right_end)` into
/// `dst[left..right_end)`. Stable: on `cmp(left, right) <= 0`, the
/// left element wins the slot.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn merge_run(
  src : Array[Int],
  dst : Array[Int],
  left : Int,
  mid : Int,
  right_end : Int,
  cmp : (Int, Int) -> Int,
) -> Unit {
  let mut p = left
  let mut q = mid
  let mut k = left
  while p < mid && q < right_end {
    if cmp(src[p], src[q]) <= 0 {
      dst[k] = src[p]
      p = p + 1
    } else {
      dst[k] = src[q]
      q = q + 1
    }
    k = k + 1
  }
  while p < mid {
    dst[k] = src[p]
    p = p + 1
    k = k + 1
  }
  while q < right_end {
    dst[k] = src[q]
    q = q + 1
    k = k + 1
  }
}

// ── Public ordering verbs ─────────────────────────────────────────────

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
  let key = build_sort_key(self.storage, order, nulls)
  let perm = stable_mergesort_indices(self.len(), (i, j) => {
    compare_one_key(key, i, j)
  })
  gather_series(self, perm)
}

///|
/// The first `n` cells, or every cell when `n` exceeds the length — the
/// `Series` twin of `DataFrame::head`. A negative `n` clamps to an empty
/// series. Total.
pub fn Series::head(self : Series, n : Int) -> Series {
  slice_series(self, 0, clamp_take(n, self.len()))
}

///|
/// The last `n` cells, or every cell when `n` exceeds the length — the
/// `Series` twin of `DataFrame::tail`. A negative `n` clamps to an empty
/// series. Total.
pub fn Series::tail(self : Series, n : Int) -> Series {
  let len = self.len()
  let take = clamp_take(n, len)
  slice_series(self, len - take, len)
}

///|
/// The cells in reverse order, name unchanged — Polars' `Series.reverse`.
/// Total.
pub fn Series::reverse(self : Series) -> Series {
  let len = self.len()
  gather_series(self, Array::makei(len, i => len - 1 - i))
}

///|
/// Clamp a requested row count into `[0, len]`, so a negative `n` is an empty
/// result and an oversized one is the whole series.
fn clamp_take(n : Int, len : Int) -> Int {
  if n < 0 {
    0
  } else if n > len {
    len
  } else {
    n
  }
}
