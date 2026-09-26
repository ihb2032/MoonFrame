// The sort verb: arranging rows under ordered expression keys. Each key is
// evaluated over the whole frame and resolved to a typed buffer once
// (`build_sort_key`), a stable mergesort turns the key comparisons into a
// row permutation, and `gather` — the row-movement verb — applies it. The
// comparator across the resolved keys is `compare_rows`; an empty key set
// is the identity.

///|
/// Sort `self` by one or more `Expr` keys, applied in order — MoonFrame's
/// single sort verb (Polars' `df.sort(...)`). `keys` is an array of
/// `(key, descending, nulls_last)` tuples — two plain flags, Polars'
/// `descending` / `nulls_last`: a single-key sort passes a
/// one-element array (`df.sort([(col("q"), true, true)])` — descending,
/// nulls last), a
/// multi-key sort lists several
/// (`df.sort([(col("dept"), false, true), (col("salary"), true, true)])`).
/// Earlier keys dominate; later keys only break ties between rows that
/// compare equal under all earlier keys.
///
/// Each key is an arbitrary expression, evaluated over the whole frame
/// under the evaluator's shared rules: a bare `col("q")` sorts by an
/// existing column, a derived key like `col("a") + col("b")` sorts by the
/// computed value without materialising it into the output. A key that
/// reduces to a single cell (a literal, or an aggregation such as
/// `col("q").sum()`) broadcasts over the frame — every row shares it, so
/// it is a stable no-op that leaves earlier keys and the input order
/// untouched. A key of any other length — only a `lit_series` or a
/// `map_batches` closure can produce one — raises `LengthMismatch` under the
/// shared length contract, rather than ordering rows by a key it has no cell
/// for.
///
/// The sort is **stable** (bottom-up merge sort on row indices): two
/// rows that compare equal under every key keep their original relative
/// order. This is what makes `[(col("dept"), false, _), (col("salary"), true, _)]`
/// behave the same as "sort by dept, then within each dept sort by
/// salary descending".
///
/// Null placement is governed by each key's `nulls_last`; a `Float` `NaN` is
/// a value, not a placement decision: it orders by the IEEE total order —
/// larger than every other value — so it trails an ascending sort and leads
/// a descending one, independent of where the nulls sit (plain `<` / `>`
/// against `NaN` are `false`, so the total order is what places it at all).
///
/// The returned frame routes through `DataFrame::gather`, so the schema
/// (column names, dtypes, order) is preserved verbatim and only the row
/// order changes — the key expressions decide the permutation but never
/// appear in the output. Every output passes `check_invariants()`.
///
/// Evaluation errors surface here (building the keys was total): a key
/// referencing an unknown column raises `ColumnNotFound` on the first
/// offending key, a dtype clash raises `TypeMismatch`, an off-frame key length
/// raises `LengthMismatch`, and the
/// unrepresentable `Null` literal raises `Unsupported`. Every evaluated
/// key is one of `Int` / `Float` / `Bool` / `String` (there is no
/// Null-dtype backend), so it is always sortable.
///
/// An empty key set is a no-op identity: zero keys ⇒ every comparison
/// returns 0 ⇒ stability preserves the input order.
pub fn DataFrame::sort(
  self : DataFrame,
  keys : Array[(@expr.Expr, Bool, Bool)],
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
  // first offending key (unknown column, dtype clash, off-frame length);
  // `Array::map` forwards that raise.
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  let sort_keys = keys.map(key => {
    let (expr, descending, nulls_last) = key
    let column = @kernel.broadcast_series(eval_expr(expr, self, scope), n)
    column.build_sort_key(descending, nulls_last)
  })
  // Stable mergesort produces the permutation; `gather` applies it to the
  // original frame. Every index in the permutation is in `[0, nrows)` by
  // construction, so `gather` cannot fail.
  let perm = @order.stable_mergesort_indices(n, (i, j) => {
    compare_rows(sort_keys, i, j)
  })
  self.gather(perm)
}

///|
/// Lexicographic comparison across the resolved keys: first key that
/// disagrees decides. Returns -1 / 0 / 1 in the usual sense.
fn compare_rows(keys : Array[@series.SortKey], i : Int, j : Int) -> Int {
  for k in 0..<keys.length() {
    let c = keys[k].compare_one_key(i, j)
    if c != 0 {
      return c
    }
  }
  0
}
