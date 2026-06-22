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

// ── Operations ────────────────────────────────────────────────────────

///|
/// Sort `self` by one or more `Expr` keys, applied in order — MoonFrame's
/// single sort verb (Polars' `df.sort(...)`). `keys` is an array of
/// `(key, order, null_order)` tuples: a single-key sort passes a
/// one-element array (`df.sort([(col("q"), Desc, NullsLast)])`), a
/// multi-key sort lists several
/// (`df.sort([(col("dept"), Asc, NullsLast), (col("salary"), Desc, NullsLast)])`).
/// Earlier keys dominate; later keys only break ties between rows that
/// compare equal under all earlier keys.
///
/// Each key is an arbitrary expression, evaluated over the whole frame
/// under the rules in `expr_eval.mbt`: a bare `col("q")` sorts by an
/// existing column, a derived key like `col("a") + col("b")` sorts by the
/// computed value without materialising it into the output. A key that
/// reduces to a single cell (a literal, or an aggregation such as
/// `col("q").sum()`) broadcasts over the frame — every row shares it, so
/// it is a stable no-op that leaves earlier keys and the input order
/// untouched.
///
/// The sort is **stable** (bottom-up merge sort on row indices): two
/// rows that compare equal under every key keep their original relative
/// order. This is what makes `[(col("dept"), Asc, _), (col("salary"), Desc, _)]`
/// behave the same as "sort by dept, then within each dept sort by
/// salary descending".
///
/// Null and `NaN` placement is governed by each key's `null_order`.
/// `NaN` in a `Float` key is treated identically to `Null` for
/// ordering — IEEE 754 makes `<` / `>` against NaN return `false`, so a
/// naive comparator would scatter NaNs unpredictably. (This is the one
/// deliberate departure from Polars, which orders `NaN` as the largest
/// value and treats only `Null` as missing.)
///
/// The returned frame routes through `DataFrame::take`, so the schema
/// (column names, dtypes, order) is preserved verbatim and only the row
/// order changes — the key expressions decide the permutation but never
/// appear in the output. Every output passes `check_invariants()`.
///
/// Evaluation errors surface here (building the keys was total): a key
/// referencing an unknown column raises `ColumnNotFound` on the first
/// offending key, a dtype clash raises `TypeMismatch`, and the
/// unrepresentable `Null` literal raises `Unsupported`. Every evaluated
/// key is one of `Int` / `Float` / `Bool` / `String` (there is no
/// Null-dtype backend), so it is always sortable.
///
/// An empty key set is a no-op identity: zero keys ⇒ every comparison
/// returns 0 ⇒ stability preserves the input order.
pub fn DataFrame::sort(
  self : DataFrame,
  keys : Array[(@expr.Expr, SortOrder, NullOrder)],
) -> DataFrame raise @types.DataError {
  // No keys ⇒ every comparison returns 0 ⇒ a stable sort is the identity.
  // Return `self` rather than building an identity permutation and gathering
  // a copy (the comparator + mergesort + `take` would all be no-ops).
  if keys.is_empty() {
    return self
  }
  // Evaluate each key over the whole frame, then resolve it to its typed
  // buffer + missing mask once, up front, so the dispatch happens per-key
  // rather than per-comparison. A length-1 key (literal / aggregation)
  // broadcasts to frame height — a stable no-op. Evaluation raises on the
  // first offending key (unknown column, dtype clash); `Array::map`
  // forwards that raise.
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  let sort_keys = keys.map(key => {
    let (expr, order, null_order) = key
    let column = broadcast_series(eval_expr(expr, self, scope), n)
    build_sort_key(column.storage(), order, null_order)
  })
  // Stable mergesort produces the permutation; `take` applies it to the
  // original frame. Every index in the permutation is in `[0, nrows)` by
  // construction, so `take` cannot fail.
  let perm = stable_mergesort_indices(n, (i, j) => compare_rows(sort_keys, i, j))
  self.take(perm)
}

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
fn build_sort_key(
  storage : @column.ColumnStorage,
  order : SortOrder,
  null_order : NullOrder,
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
