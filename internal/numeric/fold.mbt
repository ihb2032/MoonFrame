// The shared accumulations behind the column layer's `NumericColumn`
// fast-path reductions and the series layer's window reductions — the
// extremum fold, the exact `Int64` sum, and the `Double` sum with its
// present-count — so each loop lives in one place rather than once per
// package, and each caller supplies only its reader and skip test.
//
// One-file-one-test exemption: these generic helpers have no dedicated
// test file of their own. (doc-guard: unresolved) They are covered through the column / series reduction
// tests that exercise the empty, all-skipped, and accumulation paths.

///|
/// Fold the cells `0 ..< n` to their extremum, skipping every cell that
/// `skip(i)` marks (a null slot, plus `NaN` for a `Float` column) and using
/// `better(candidate, best)` to decide whether a kept cell replaces the
/// running best. Returns `None` when every cell is skipped — an empty range,
/// an all-null column, or an all-`NaN` `Float` column. The single extremum
/// accumulation behind `min` / `max` (whole-column, per-group, and
/// per-scope), so each caller supplies only its reader, skip test, and
/// comparator. Generic over the cell type `T`, so the element kind lives
/// entirely in the caller's closures. Total — pure folding, no failure path.
pub fn[T] fold_extremum(
  n : Int,
  get : (Int) -> T,
  skip : (Int) -> Bool,
  better : (T, T) -> Bool,
) -> T? {
  let mut best : T? = None
  for i in 0..<n {
    if !skip(i) {
      // Bind the cell once: the `Some` arm would otherwise evaluate `get(i)`
      // up to twice per kept element.
      let v = get(i)
      best = match best {
        None => Some(v)
        Some(b) => if better(v, b) { Some(v) } else { Some(b) }
      }
    }
  }
  best
}

///|
/// Exact `Int64` sum of the cells `0 ..< n` a `present(i)` marks kept —
/// the accumulation behind every `sum` that preserves the `Int` dtype (the
/// whole-column fast path and the windowed reducer alike). The accumulator
/// is `Int64` and wraps past 2^63: the documented price of an exact integer
/// sum, identical on both layers because the loop is this one. A `Double`
/// result must not use it — an `Int64` accumulator would wrap and flip the
/// sign of a value `Double` still represents; `fold_double_sum` widening
/// each cell before adding is the mean-safe form. Total.
pub fn fold_int64_sum(
  n : Int,
  get : (Int) -> Int64,
  present : (Int) -> Bool,
) -> Int64 {
  let mut acc : Int64 = 0
  for i in 0..<n {
    if present(i) {
      acc = acc + get(i)
    }
  }
  acc
}

///|
/// `Double`-accumulator sum of the cells `0 ..< n` a `present(i)` marks kept,
/// with the kept count for the dividing caller: the accumulation behind
/// `mean` on both layers (an `Int` column widens each cell through `get`
/// before adding, so the accumulator cannot wrap past 2^63 the way
/// `fold_int64_sum`'s does — matching Polars, which computes an `Int`-column
/// mean in f64) and behind `Float` `sum`, where a present `NaN` participates
/// — it is a value, only `Null` is missing — so a single `NaN` cell
/// propagates to a `NaN` total. A returned count of `0` (an empty range or
/// an all-null window) is the caller's empty-window signal. Total.
pub fn fold_double_sum(
  n : Int,
  get : (Int) -> Double,
  present : (Int) -> Bool,
) -> (Double, Int) {
  let mut acc : Double = 0.0
  let mut cnt = 0
  for i in 0..<n {
    if present(i) {
      acc = acc + get(i)
      cnt = cnt + 1
    }
  }
  (acc, cnt)
}
