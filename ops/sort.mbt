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

// ── Operations ────────────────────────────────────────────────────────

///|
/// Sort `df` by a single column. Convenience wrapper around
/// `sort_by_many` for the common single-key case. See `sort_by_many`
/// for the contract on stability, null placement, and error reporting.
pub fn sort_by(
  df : @frame.DataFrame,
  spec : SortSpec,
) -> Result[@frame.DataFrame, @types.DataError] {
  sort_by_many(df, [spec])
}

///|
/// Sort `df` by a sequence of keys, applied in order. Earlier specs
/// dominate; later specs only break ties between rows that compare
/// equal under all earlier keys.
///
/// The sort is **stable** (bottom-up merge sort on row indices): two
/// rows that compare equal under every key keep their original
/// relative order. This is what makes `sort_by_many([asc("dept"),
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
/// Errors:
/// - `Err(ColumnNotFound(name))` — `name` doesn't appear in `df`.
///   Reported on the first offending spec in `specs`. v0.1 columns
///   are always one of `Int` / `Float` / `Bool` / `String` (Null-dtype
///   columns aren't constructible through any `DataFrame` constructor),
///   so a successful column lookup always yields a sortable column.
///
/// An empty `specs` is a no-op identity: zero keys ⇒ every comparison
/// returns 0 ⇒ stability preserves the input order.
pub fn sort_by_many(
  df : @frame.DataFrame,
  specs : Array[SortSpec],
) -> Result[@frame.DataFrame, @types.DataError] {
  let n = df.nrows()
  // Resolve each spec to its typed buffer + bitmap once, up front.
  // The dispatch then happens per-spec, not per-comparison.
  let keys : Array[SortKey] = []
  for spec in specs {
    let series = match df.get_column(spec.column) {
      Ok(s) => s
      Err(e) => return Err(e)
    }
    keys.push(build_sort_key(series.storage(), spec.order, spec.null_order))
  }
  // Stable mergesort produces the permutation; `take` applies it.
  // Every index in the permutation is in `[0, n)` by construction, so
  // `take` cannot fail.
  let perm = stable_mergesort_indices(n, fn(i, j) { compare_rows(keys, i, j) })
  df.take(perm)
}

///|
/// Resolve a `BuiltinColumn` into a typed `SortKey`. The dispatch
/// cascades through the four typed accessors — `BuiltinColumn` is
/// always one of `Int` / `Float` / `Bool` / `String` (per
/// `ColumnData`'s four variants), so the last branch must succeed
/// and `unwrap()` is safe. Routing the dispatch through the typed
/// accessors avoids re-matching `DataType` (whose `Null` variant
/// can never appear here) and keeps the public surface tight.
fn build_sort_key(
  storage : @column.BuiltinColumn,
  order : SortOrder,
  null_order : NullOrder,
) -> SortKey {
  match storage.int_values() {
    Ok((data, validity)) => SortKey::Int(data, validity, order, null_order)
    Err(_) =>
      match storage.float_values() {
        Ok((data, validity)) =>
          SortKey::Float(data, validity, order, null_order)
        Err(_) =>
          match storage.bool_values() {
            Ok((data, validity)) =>
              SortKey::Bool(data, validity, order, null_order)
            Err(_) => {
              // Exhaustive: the remaining `ColumnData` variant is
              // `String`, so `string_values` must succeed.
              let (data, validity) = storage.string_values().unwrap()
              SortKey::String(data, validity, order, null_order)
            }
          }
      }
  }
}

// ── Internal: comparator + stable mergesort ───────────────────────────

///|
/// Package-private resolved form of a `SortSpec`: the raw data buffer,
/// the validity bitmap, and the per-spec direction / null placement.
/// Keeping the dtype tag here lets the comparator stay branch-free per
/// element type (no `Scalar` boxing, no re-dispatch through
/// `BuiltinColumn::get`).
priv enum SortKey {
  Int(Array[Int], @column.Bitmap, SortOrder, NullOrder)
  Float(Array[Float], @column.Bitmap, SortOrder, NullOrder)
  Bool(Array[Bool], @column.Bitmap, SortOrder, NullOrder)
  String(Array[String], @column.Bitmap, SortOrder, NullOrder)
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
    Int(data, validity, order, null_order) => {
      // `is_valid` cannot fail: i, j come from the [0, n) permutation
      // and the bitmap length matches the column length == nrows.
      let mi = !validity.is_valid(i).unwrap()
      let mj = !validity.is_valid(j).unwrap()
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
    Float(data, validity, order, null_order) => {
      let a = data[i]
      let b = data[j]
      // NaN behaves like Null for ordering — IEEE 754 would otherwise
      // make NaN incomparable, and downstream stats already treat NaN
      // as "the absence of a numeric value" in `min` / `max` etc.
      let mi = !validity.is_valid(i).unwrap() || a.is_nan()
      let mj = !validity.is_valid(j).unwrap() || b.is_nan()
      compare_with_missing(mi, mj, null_order, order, fn() {
        if a < b {
          -1
        } else if a > b {
          1
        } else {
          0
        }
      })
    }
    Bool(data, validity, order, null_order) => {
      let mi = !validity.is_valid(i).unwrap()
      let mj = !validity.is_valid(j).unwrap()
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
    String(data, validity, order, null_order) => {
      let mi = !validity.is_valid(i).unwrap()
      let mj = !validity.is_valid(j).unwrap()
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
  let buf : Array[Int] = Array::new(capacity=n)
  for i in 0..<n {
    buf.push(i)
  }
  if n <= 1 {
    return buf
  }
  let aux : Array[Int] = Array::new(capacity=n)
  for _ in 0..<n {
    aux.push(0)
  }
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
