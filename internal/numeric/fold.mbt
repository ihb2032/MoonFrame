// The shared accumulations behind the column layer's `NumericColumn`
// fast-path reductions and the series layer's window reductions — the
// extremum fold, the exact `Int64` sum, the `Double` sum with its
// present-count, and Welford's sample-variance fold — so each loop lives
// in one place rather than once per package, and each caller supplies
// only its reader and skip test.
//
// One-file-one-test exemption: these generic helpers have no dedicated
// test file of their own. (doc-guard: unresolved) They are covered through the column / series / kernel reduction
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
  n : Int32,
  get : (Int32) -> T,
  skip : (Int32) -> Bool,
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
  n : Int32,
  get : (Int32) -> Int64,
  present : (Int32) -> Bool,
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
  n : Int32,
  get : (Int32) -> Double,
  present : (Int32) -> Bool,
) -> (Double, Int32) {
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

///|
/// Welford's online sample-variance fold of the cells `0 ..< n` a
/// `present(i)` marks kept: one pass that never forms the raw sum, so a
/// finite-variance window of near-`Double`-max values — whose sum would
/// overflow to `±inf` and poison a two-pass mean, reporting `+inf` for a
/// true variance of 0 — still yields its finite variance. Returns the sum
/// of squared deviations `m2`, the kept count, and whether any kept cell
/// was non-finite. When the true variance itself exceeds `Double`'s range
/// (finite cells more than `Double::MAX` apart, e.g. opposite signs near
/// `±1.8e308`), the internal overflow saturates `m2` to `+inf` — never a
/// negative variance or a `NaN` result from the artefact — matching numpy /
/// Polars; genuine `NaN` / `±inf` inputs keep IEEE propagation (a `NaN`
/// cell makes the running mean, hence `m2` and the caller's result, `NaN`;
/// the rescue only fires when every input was finite). The caller owns the
/// fewer-than-two rule (`cnt < 2` has no sample denominator) and the
/// division by `cnt - 1`. Total.
pub fn fold_welford_m2(
  n : Int32,
  get : (Int32) -> Double,
  present : (Int32) -> Bool,
) -> (Double, Int32, Bool) {
  let mut cnt = 0
  let mut mean = 0.0
  let mut m2 = 0.0
  let mut saw_nonfinite = false
  for i in 0..<n {
    if present(i) {
      let x = get(i)
      cnt = cnt + 1
      saw_nonfinite = saw_nonfinite || x.is_nan() || x.is_inf()
      let delta = x - mean
      mean = mean + delta / cnt.to_double()
      m2 = m2 + delta * (x - mean)
    }
  }
  // Welford keeps `m2 >= 0` under finite in-range arithmetic, but `delta`
  // itself overflows to `±inf` when two finite cells sit more than
  // `Double::MAX` apart, and the artefact poisons `m2` to `-inf` or `NaN` —
  // reporting a mathematically impossible negative variance. With every
  // *input* finite, a negative / `NaN` `m2` can only be that artefact, so
  // saturate to `+inf`: the true variance exceeds `Double`'s range, and
  // `sqrt(+inf) = +inf` keeps a caller's std consistent.
  let m2 = if !saw_nonfinite && !(m2 >= 0.0) { @double.infinity } else { m2 }
  (m2, cnt, saw_nonfinite)
}
