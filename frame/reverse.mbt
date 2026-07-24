// Row-order and row-numbering verbs: `reverse` flips the row order,
// `with_row_index` prepends a positional counter. Neither can fail on the
// *cells* — one is a permutation that is in bounds by construction, the other a
// column append over an already-validated frame. That makes `reverse` total;
// `with_row_index` still raises on what a new column can clash with: a name the
// frame already carries, and a counter that would run past `Int64::MAX`.

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
///
/// Raises `InvalidOperation` when the last number would not fit: the counter
/// runs `offset ..= offset + nrows - 1`, and past `Int64::MAX` MoonBit's
/// wrapping addition would carry it round to `Int64::MIN`, leaving a column
/// that is neither increasing nor dense. Polars refuses the same overflow
/// against its own index type.
pub fn DataFrame::with_row_index(
  self : DataFrame,
  name? : String = "index",
  offset? : Int64 = 0,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  // Rearranged to `offset > MAX - (n - 1)` so the check itself cannot overflow:
  // `n - 1` is at most `Int::MAX`, far inside the subtraction's range. Only the
  // top end can run out — every counter step is upward, so a negative `offset`
  // moves away from `Int64::MIN`, never toward it.
  if n > 0 && offset > 9223372036854775807L - (n - 1).to_int64() {
    raise @types.DataError::InvalidOperation(
      "row index overflows Int64: offset \{offset} with \{n} rows",
    )
  }
  let index = @series.Series::from_ints(
    name,
    Array::makei(n, i => offset + i.to_int64()),
  )
  let columns = [index]
  for column in self.column_series() {
    columns.push(column)
  }
  // Prepending a column leaves every existing one exactly where it was, so
  // each keeps the field it arrived with rather than a re-derived one.
  let fields = [@types.Field::Field(name, @types.DataType::Int)]
  for field in self.schema.fields() {
    fields.push(field)
  }
  DataFrame::from_parts_with_fields(columns, fields, n)
}
