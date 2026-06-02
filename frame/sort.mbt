///|
/// Direction of a sort key. `Asc` sorts smaller values first, `Desc`
/// sorts larger values first. The convention applies to every dtype:
/// `Int` / `Float` use numeric ordering, `Bool` uses `false < true`,
/// `String` uses lexicographic comparison.
pub(all) enum SortOrder {
  Asc
  Desc
} derive(Eq, Debug)

///|
/// Where missing cells go relative to non-missing ones. Missing means
/// either a `Null` slot (validity bit 0) or — for `Float` columns —
/// `NaN`. The plan specifies that NaN is treated identically to Null
/// for ordering, so callers don't need a separate knob.
pub(all) enum NullOrder {
  NullsFirst
  NullsLast
} derive(Eq, Debug)

///|
/// A single sort key: which column to read, what direction, and where
/// to place missing cells. Construct via `SortSpec::asc` /
/// `SortSpec::desc` and optionally override the null placement with
/// `with_null_order`.
pub struct SortSpec {
  column : String
  order : SortOrder
  null_order : NullOrder
} derive(Eq, Debug)

///|
/// Ascending `SortSpec` for `column`. Default null placement is
/// `NullsLast`, matching pandas / polars defaults — most exploratory
/// sorts want the "real" data at the top of the frame and missing
/// rows at the bottom.
pub fn SortSpec::asc(column : String) -> SortSpec {
  { column, order: Asc, null_order: NullsLast }
}

///|
/// Descending `SortSpec` for `column`. Default null placement is
/// `NullsLast` (same as `asc` — the dimension that flips is the
/// value ordering, not where missings go).
pub fn SortSpec::desc(column : String) -> SortSpec {
  { column, order: Desc, null_order: NullsLast }
}

///|
/// Override the null placement on an existing `SortSpec` without
/// touching its column or order — `SortSpec::desc("score")
/// .with_null_order(NullsFirst)` reads naturally at call sites.
pub fn SortSpec::with_null_order(
  self : SortSpec,
  null_order : NullOrder,
) -> SortSpec {
  { column: self.column, order: self.order, null_order }
}

///|
/// Lets `sort_by` accept either a single `SortSpec` or an
/// `Array[SortSpec]` under one method name. A single key needs no `[]`
/// wrapper (`df.sort_by(SortSpec::desc("x"))`); a multi-key sort passes
/// the array (`df.sort_by([asc("a"), desc("b")])`). Both impl bodies are
/// trivial, so the two call shapes fully cover them.
pub trait IntoSortSpecs {
  fn to_sort_specs(Self) -> Array[SortSpec]
}

///|
pub impl IntoSortSpecs for SortSpec with fn to_sort_specs(self) {
  [self]
}

///|
pub impl IntoSortSpecs for Array[SortSpec] with fn to_sort_specs(self) {
  self
}

// ── Operations ────────────────────────────────────────────────────────

///|
/// Sort `self` by one or more keys, applied in order. A single key may
/// be passed directly (`df.sort_by(SortSpec::desc("q"))`); multiple keys
/// pass an array (`df.sort_by([asc("dept"), desc("salary")])`) — both go
/// through the `IntoSortSpecs` trait. Earlier specs dominate; later
/// specs only break ties between rows that compare equal under all
/// earlier keys.
///
/// The sort is **stable** (bottom-up merge sort on row indices): two
/// rows that compare equal under every key keep their original
/// relative order. This is what makes `sort_by([asc("dept"),
/// desc("salary")])` behave the same as "sort by dept, then within
/// each dept sort by salary descending".
///
/// Null and `NaN` placement is governed by each spec's `null_order`.
/// `NaN` in `Float` columns is treated identically to `Null` for
/// ordering — IEEE 754 makes `<` / `>` against NaN return `false`, so
/// a naive comparator would scatter NaNs unpredictably.
///
/// The returned frame routes through `DataFrame::take`, so the schema
/// (column names, dtypes, order) is preserved verbatim and only the
/// row order changes. Every output passes `check_invariants()`.
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` doesn't appear in `self`.
///   Reported on the first offending spec. v0.1 columns are always one
///   of `Int` / `Float` / `Bool` / `String` (Null-dtype columns aren't
///   constructible through any `DataFrame` constructor), so a successful
///   column lookup always yields a sortable column.
///
/// An empty key set is a no-op identity: zero keys ⇒ every comparison
/// returns 0 ⇒ stability preserves the input order.
pub fn[K : IntoSortSpecs] DataFrame::sort_by(
  self : DataFrame,
  keys : K,
) -> DataFrame raise @types.DataError {
  let specs = keys.to_sort_specs()
  let n = self.nrows()
  // Resolve each spec to its typed buffer + bitmap once, up front.
  // The dispatch then happens per-spec, not per-comparison.
  let sort_keys : Array[SortKey] = []
  for spec in specs {
    // `get_column` raises `ColumnNotFound` for an unknown spec column.
    let series = self.get_column(spec.column)
    sort_keys.push(
      build_sort_key(series.storage(), spec.order, spec.null_order),
    )
  }
  // Stable mergesort produces the permutation; `take` applies it.
  // Every index in the permutation is in `[0, n)` by construction, so
  // `take` cannot fail.
  let perm = stable_mergesort_indices(n, fn(i, j) {
    compare_rows(sort_keys, i, j)
  })
  self.take(perm)
}

///|
/// Resolve a `BuiltinColumn` into a typed `SortKey`, matching on the
/// concrete backing array via `storage.data()` — `ColumnData`'s four
/// variants are exhaustive, so there's no fallback branch to `unwrap`.
/// Missingness (`Null`, plus `NaN` for `Float`) is pre-computed into a
/// dense `Array[Bool]` here, once per key, so the comparator reads it by
/// plain index instead of repeating a bitmap lookup on every comparison.
fn build_sort_key(
  storage : @column.BuiltinColumn,
  order : SortOrder,
  null_order : NullOrder,
) -> SortKey {
  let valid = storage.validity().to_bools()
  match storage.data() {
    @column.ColumnData::Int(a) =>
      SortKey::Int(
        a,
        Array::makei(a.length(), i => !valid[i]),
        order,
        null_order,
      )
    @column.ColumnData::Float(a) =>
      // NaN behaves like Null for ordering (see `sort_by`).
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
/// Package-private resolved form of a `SortSpec`: the raw data buffer, a
/// dense per-row `missing` mask (`Null`, or `NaN` for `Float`), and the
/// per-spec direction / null placement. Pre-resolving missingness lets
/// the comparator stay branch-free per element type (no `Scalar` boxing,
/// no per-comparison bitmap lookup).
priv enum SortKey {
  Int(Array[Int64], Array[Bool], SortOrder, NullOrder)
  Float(Array[Double], Array[Bool], SortOrder, NullOrder)
  Bool(Array[Bool], Array[Bool], SortOrder, NullOrder)
  String(Array[String], Array[Bool], SortOrder, NullOrder)
}

///|
/// Lexicographic comparison across the resolved keys: first key that
/// disagrees decides. Returns -1 / 0 / 1 in the usual sense.
fn compare_rows(keys : Array[SortKey], i : Int, j : Int) -> Int {
  for k in 0..<keys.length() {
    let c = compare_one_key(keys[k], i, j)
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// Single-key comparison. The validity bitmap (and, for `Float`, the
/// NaN check) decides "missing"; missingness combines with
/// `null_order` to place missing cells, and only non-missing pairs
/// reach the value comparison + `order` flip.
fn compare_one_key(key : SortKey, i : Int, j : Int) -> Int {
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
        @types.compare_string_lex(data[i], data[j])
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
  null_order : NullOrder,
  order : SortOrder,
  cmp_valid : () -> Int,
) -> Int {
  match (mi, mj) {
    (true, true) => 0
    (true, false) => missing_offset(null_order)
    (false, true) => -missing_offset(null_order)
    (false, false) => {
      let raw = cmp_valid()
      match order {
        Asc => raw
        Desc => -raw
      }
    }
  }
}

///|
/// `-1` when missing sorts before non-missing (`NullsFirst`), `1` when
/// missing sorts after non-missing (`NullsLast`). The sign is applied
/// from the left-hand side's perspective in `compare_with_missing`.
fn missing_offset(null_order : NullOrder) -> Int {
  match null_order {
    NullsFirst => -1
    NullsLast => 1
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
fn stable_mergesort_indices(n : Int, cmp : (Int, Int) -> Int) -> Array[Int] {
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
      let mid = if start + width < n { start + width } else { n }
      let right_end = if start + 2 * width < n { start + 2 * width } else { n }
      merge_run(buf, aux, left, mid, right_end, cmp)
      start = start + 2 * width
    }
    // Copy the merged pass back into `buf` so the next pass reads
    // from a contiguous source.
    for k in 0..<n {
      buf[k] = aux[k]
    }
    width = width * 2
  }
  buf
}

///|
/// Merge `src[left..mid)` and `src[mid..right_end)` into
/// `dst[left..right_end)`. Stable: on `cmp(left, right) <= 0`, the
/// left element wins the slot.
fn merge_run(
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
