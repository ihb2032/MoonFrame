///|
/// Replace every null cell in the column named `column` with `value`.
/// The remaining columns, and the schema's column order, are kept
/// verbatim. The target column's dtype is **unchanged** — the fill
/// `value` must match the column's existing dtype; cross-dtype filling
/// is not supported in v0.1 (callers can build a new series and pipe it
/// through `replace_column` if they need that).
///
/// Raises:
/// - `ColumnNotFound(column)` — `column` doesn't exist in `self`.
/// - `TypeMismatch(...)` — `value` is `Scalar::Null` (filling nulls with
///   null is meaningless), or `value.dtype()` differs from the target
///   column's dtype. Both diagnostics bubble unchanged from
///   `Series::fill_null` so the message text matches the Series API.
///   Column-lookup runs before the fill so a missing name is surfaced
///   ahead of a type-mismatch error.
///
/// `fill_null` rewrites cells in place — the target column keeps its name
/// and dtype (a cross-dtype fill is rejected upstream) and every other
/// column is untouched — so names, dtypes, and the row count are unchanged.
/// The returned frame therefore reuses `self`'s schema and `O(1)`
/// name→index cache verbatim (the same same-schema rebuild `head` / `tail`
/// / `to_numeric` use) rather than re-deriving them through `DataFrame::new`.
pub fn DataFrame::fill_null(
  self : DataFrame,
  column : String,
  value : @types.Scalar,
) -> DataFrame raise @types.DataError {
  // `get_column` is the receiver, so it is evaluated first: a missing
  // column raises `ColumnNotFound` before the (more expensive)
  // `Series::fill_null` traversal runs.
  let filled = self.get_column(column).fill_null(value)
  // Same-schema rebuild: only the target column's cells change, so names,
  // dtypes, and the row count are unchanged — reuse the schema and the
  // name→index cache verbatim (as `head` / `tail` / `to_numeric` do),
  // dropping `DataFrame::new`'s unreachable `LengthMismatch` /
  // `DuplicateColumn` arms with it.
  let new_cols = self.columns.map(s => {
    if s.name() == column {
      filled
    } else {
      s
    }
  })
  {
    schema: self.schema,
    columns: new_cols,
    nrows: self.nrows,
    name_to_index: self.name_to_index,
  }
}
