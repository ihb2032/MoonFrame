///|
/// Fill every null cell of the **dtype-compatible** columns with `value`,
/// leaving the rest of the frame verbatim — Polars' frame-wide
/// `DataFrame.fill_null(value)`. A column is compatible when its dtype
/// matches `value`'s variant: an `Int` value fills `Int` columns, a `Float`
/// value fills `Float` columns, and so on. Columns of any other dtype are
/// left untouched (not an error), and so are **all** columns when `value` is
/// `Scalar::Null` — filling nulls with null is a no-op, so it skips
/// everything and returns the frame unchanged.
///
/// Per-column control, cross-dtype fills (an `Int` value into a `Float`
/// column, say), or filling with a computed value go through the expression
/// form instead: `df.with_columns([col("c").fill_null(lit(value))])`.
///
/// Filling rewrites cells in place — each filled column keeps its name and
/// dtype (a compatible fill is dtype-preserving) and every other column is
/// untouched — so names, dtypes, and the row count are unchanged. The
/// returned frame therefore reuses `self`'s schema and `O(1)` name→index
/// cache verbatim (the same same-schema rebuild `head` / `tail` /
/// `to_numeric` use) rather than re-deriving them through `DataFrame::new`.
///
/// `raise`-typed because `Series::fill_null` is, but the compatibility gate
/// means it is only ever called on a column it cannot fail on (a matching
/// non-null value), so no error is actually produced here.
pub fn DataFrame::fill_null(
  self : DataFrame,
  value : @types.Scalar,
) -> DataFrame raise @types.DataError {
  let new_cols = []
  for s in self.columns {
    new_cols.push(
      if fills_dtype(value, s.dtype()) {
        s.fill_null(value)
      } else {
        s
      },
    )
  }
  self.with_same_schema(new_cols, self.nrows)
}

///|
/// Whether the frame-wide `fill_null` value fills a column of `dtype`: a
/// concrete value fills its own dtype only (so the fill is always
/// dtype-preserving), and the null value fills nothing.
fn fills_dtype(value : @types.Scalar, dtype : @types.DataType) -> Bool {
  match value {
    @types.Scalar::Null => false
    _ => value.dtype() == dtype
  }
}
