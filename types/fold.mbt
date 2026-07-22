// `fold_extremum` — the generic extremum accumulation shared by `@column`'s
// `NumericColumn::min` / `max` and `@series`' reductions, so the `best : T?`
// loop lives in one place rather than once per package.
//
// One-file-one-test exemption: this generic helper has no dedicated
// `fold_test.mbt`. It is covered through the column / series `min` / `max`
// tests that exercise the empty (`None`), all-skipped, and replacement paths.

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
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
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
