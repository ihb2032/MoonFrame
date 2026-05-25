///|
/// Replace every null cell in the column named `column` with `value`.
/// The remaining columns, and the schema's column order, are kept
/// verbatim. The target column's dtype is **unchanged** — the fill
/// `value` must match the column's existing dtype; cross-dtype filling
/// is not supported in v0.1 (callers can build a new series and pipe it
/// through `replace_column` if they need that).
///
/// Errors:
/// - `Err(ColumnNotFound(column))` — `column` doesn't exist in `df`.
/// - `Err(TypeMismatch(...))` — `value` is `Scalar::Null` (filling
///   nulls with null is meaningless), or `value.dtype()` differs from
///   the target column's dtype. Both diagnostics bubble unchanged from
///   `Series::fill_null` so the message text matches the Series API.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new`, which rebuilds the schema and `name_to_index`
/// cache in lock-step with the column vector.
pub fn fill_null(
  df : @frame.DataFrame,
  column : String,
  value : @types.Scalar,
) -> Result[@frame.DataFrame, @types.DataError] {
  // Look up the target column first so a missing-column error fires
  // before the (more expensive) `Series::fill_null` traversal runs.
  let target = match df.get_column(column) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let filled = match target.fill_null(value) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let new_cols : Array[@frame.Series] = []
  for name in df.columns() {
    if name == column {
      new_cols.push(filled)
    } else {
      // `get_column` cannot fail: the name came from `df.columns()`.
      new_cols.push(df.get_column(name).unwrap())
    }
  }
  @frame.DataFrame::new(new_cols)
}
