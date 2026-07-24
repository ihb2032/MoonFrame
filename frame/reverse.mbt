// Row-order and row-numbering verbs: `reverse` flips the row order,
// `with_row_index` prepends a positional counter. Both are pure gathers /
// column appends over an already-validated frame, so both are total.

///|
/// Reverse the row order, keeping every column and its dtype — Polars'
/// `df.reverse()`. The schema is untouched, so a reversed frame is a frame
/// with the same columns in the same order, read bottom-up.
///
/// Total: the permutation is `[n-1, …, 0]`, in bounds by construction. A
/// 0-row or 1-row frame is returned unchanged rather than gathered into an
/// identical copy.
pub fn DataFrame::reverse(self : DataFrame) -> DataFrame {
  let n = self.nrows()
  if n <= 1 {
    return self
  }
  // Every index comes from `[0, n)`, so the gather cannot fail.
  let perm = Array::makei(n, i => n - 1 - i)
  let columns = self.column_series().map(c => gather_series(c, perm))
  self.with_same_schema(columns, n)
}

///|
/// Prepend a row-number column — Polars' `df.with_row_index(name, offset)`.
/// The counter is an `Int` column named `name` (default `"index"`) holding
/// `offset`, `offset + 1`, … in row order, and it lands **first**, ahead of
/// the frame's own columns, as in Polars.
///
/// Raises `DuplicateColumn(name)` when the frame already has a column of that
/// name — the frame's own invariant, surfaced through `DataFrame::DataFrame`. The
/// counter is dense and always non-null, so it never changes any other
/// column's dtype or nullability.
pub fn DataFrame::with_row_index(
  self : DataFrame,
  name? : String = "index",
  offset? : Int64 = 0,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  let index = @series.Series::from_ints(
    name,
    Array::makei(n, i => offset + i.to_int64()),
  )
  let columns = [index]
  for column in self.column_series() {
    columns.push(column)
  }
  DataFrame::DataFrame(columns)
}
