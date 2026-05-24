///|
/// Keep only the rows for which `predicate` returns `true`. The
/// predicate receives a `RowView` borrowed from `df`, so per-row cell
/// access is `O(1)` and allocates nothing — the view stores the frame
/// by value (cheap, internals are shared) plus a row index.
///
/// The returned frame has the same schema (column names, dtypes,
/// nullability) as `df`; the row count equals the number of `true`
/// returns from the predicate. A frame whose predicate rejects every
/// row collapses to a 0-row frame *with the original schema* — that is
/// the meaningful distinction from `select(df, [])`, which collapses
/// the columns.
///
/// `filter` itself never fails on a well-formed `df`: every row index
/// it forwards to `DataFrame::take` is in `[0, nrows)` by construction.
/// The `Result` shape is preserved for parity with the other ops (and
/// for `take`'s signature) so call sites can chain uniformly.
///
/// For predicates that need to surface their own failures — typically
/// because they use a typed `RowView` accessor like
/// `RowView::get_int` — use `filter_try` instead. Wrapping a fallible
/// predicate in `match ... { Ok(v) => v, Err(_) => false }` silently
/// downgrades a missing column or a dtype mismatch into "row excluded",
/// which hides real bugs.
pub fn filter(
  df : @frame.DataFrame,
  predicate : (@frame.RowView) -> Bool,
) -> Result[@frame.DataFrame, @types.DataError] {
  let n = df.nrows()
  let kept : Array[Int] = []
  for i in 0..<n {
    // `df.row(i)` cannot fail in `[0, nrows)`.
    let view = df.row(i).unwrap()
    if predicate(view) {
      kept.push(i)
    }
  }
  // `take` cannot fail because every pushed index came from the
  // `[0, nrows)` loop above.
  df.take(kept)
}

///|
/// Like `filter`, but the predicate is fallible. The first `Err` the
/// predicate returns short-circuits the scan and propagates to the
/// caller; any rows accepted before the failing row are discarded. No
/// partial frame is produced.
///
/// This variant exists because the ergonomic `RowView` accessors
/// (`get_int` / `get_float` / `get_bool` / `get_string`) all return
/// `Result[T, DataError]`: a misspelled column name or a wrong-dtype
/// access becomes a `Err(ColumnNotFound(_))` / `Err(TypeMismatch(_))`
/// that a caller almost certainly wants to surface rather than swallow.
///
/// Errors:
/// - whatever the predicate returns on the first failing row.
pub fn filter_try(
  df : @frame.DataFrame,
  predicate : (@frame.RowView) -> Result[Bool, @types.DataError],
) -> Result[@frame.DataFrame, @types.DataError] {
  let n = df.nrows()
  let kept : Array[Int] = []
  for i in 0..<n {
    let view = df.row(i).unwrap()
    match predicate(view) {
      Err(e) => return Err(e)
      Ok(true) => kept.push(i)
      Ok(false) => ()
    }
  }
  df.take(kept)
}
