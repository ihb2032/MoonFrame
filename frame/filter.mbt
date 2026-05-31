///|
/// Keep only the rows for which `predicate` returns `true`. The
/// predicate receives a `RowView` borrowed from `self`, so per-row cell
/// access is `O(1)` and allocates nothing — the view stores the frame
/// by value (cheap, internals are shared) plus a row index.
///
/// The returned frame has the same schema (column names, dtypes,
/// nullability) as `self`; the row count equals the number of `true`
/// returns from the predicate. A frame whose predicate rejects every
/// row collapses to a 0-row frame *with the original schema* — that is
/// the meaningful distinction from `select([])`, which collapses the
/// columns.
///
/// The predicate may raise: the v0.1 `filter` / `filter_try` split is
/// gone, because a single `(RowView) -> Bool raise DataError` signature
/// accepts both a total predicate (which simply never raises) and a
/// fallible one that calls a typed `RowView` accessor like
/// `RowView::get_int`. The first error the predicate raises
/// short-circuits the scan and propagates verbatim; rows accepted
/// before the failing row are discarded (no partial frame). This is what
/// makes `df.filter(row => row.get_int("x") > 0)` surface a missing
/// column or dtype mismatch instead of silently excluding the row.
///
/// On a well-formed `self`, `filter` adds no failure of its own: every
/// row index it forwards to `take` is in `[0, nrows)` by construction.
/// The predicate is **not** invoked on a zero-row frame.
pub fn DataFrame::filter(
  self : DataFrame,
  predicate : (RowView) -> Bool raise @types.DataError,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  let kept : Array[Int] = []
  for i in 0..<n {
    // `i` is in `[0, nrows)`, so the borrowed row view is valid.
    let view = self.row_view(i)
    if predicate(view) {
      kept.push(i)
    }
  }
  // `take` cannot fail because every pushed index came from the
  // `[0, nrows)` loop above.
  self.take(kept)
}
