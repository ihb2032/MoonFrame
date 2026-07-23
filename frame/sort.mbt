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
/// The returned frame routes through `DataFrame::gather`, so the schema
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
  keys : Array[(@expr.Expr, @types.SortOrder, @types.NullOrder)],
) -> DataFrame raise @types.DataError {
  // No keys ⇒ every comparison returns 0 ⇒ a stable sort is the identity.
  // Return `self` rather than building an identity permutation and gathering
  // a copy (the comparator + mergesort + `gather` would all be no-ops).
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
    @series.build_sort_key(column.storage(), order, null_order)
  })
  // Stable mergesort produces the permutation; `gather` applies it to the
  // original frame. Every index in the permutation is in `[0, nrows)` by
  // construction, so `gather` cannot fail.
  let perm = @series.stable_mergesort_indices(n, (i, j) => {
    compare_rows(sort_keys, i, j)
  })
  self.gather(perm)
}

///|
/// Lexicographic comparison across the resolved keys: first key that
/// disagrees decides. Returns -1 / 0 / 1 in the usual sense.
fn compare_rows(keys : Array[@series.SortKey], i : Int, j : Int) -> Int {
  for k in 0..<keys.length() {
    let c = @series.compare_one_key(keys[k], i, j)
    if c != 0 {
      return c
    }
  }
  0
}
