///|
/// Drop every row in which a gating column has a null cell. The schema
/// (column names, dtypes, order) is preserved verbatim; only the row
/// count shrinks.
///
/// `subset` selects the gating columns — MoonFrame's single null-dropping
/// verb (Polars' `df.drop_nulls(subset)`):
/// - **omitted** → every column gates (drop a row null in **any** column).
///   A 0-column frame is the special case: there are no columns whose
///   validity could fail, so every row passes; with `DataFrame::new`'s
///   convention that a 0-column frame has `nrows = 0`, the output is
///   structurally identical to the input.
/// - **`Some(keys)`** → only the columns named by `keys` gate; a row null in
///   an unlisted column is kept. Each key is an `Expr` resolved to a column
///   name through the §0 naming rule (`Expr::output_name`) — a bare
///   `col("x")` names `"x"`. The `Array[Expr]` container mirrors `drop` and
///   leaves room for a future column selector; today only `col` / aliased
///   keys are meaningful and the expression is never evaluated.
/// - **`Some([])`** → no gating columns, so every row passes: a no-op
///   identity, schema preserved.
///
/// Duplicate keys are tolerated and act idempotently; asking the same
/// column to gate twice is the same as asking once.
///
/// Raises:
/// - `ColumnNotFound(name)` — a resolved name does not exist in `self`.
///   Reported on the first offending key in `subset` order. (Cannot arise
///   when `subset` is omitted: the names come straight from the frame.)
pub fn DataFrame::drop_nulls(
  self : DataFrame,
  subset? : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  // Resolve the gating column names: an omitted `subset` gates on every
  // column (names taken straight from the frame, so they always resolve); a
  // present `subset` maps each key to its `output_name`.
  let names = match subset {
    None => self.columns()
    Some(keys) => keys.map(key => expr_output_name(key))
  }
  // Resolve every gating column first, in `names` order; `get_column` raises
  // `ColumnNotFound` on the first unknown name, so a bad name surfaces before
  // any per-row work runs. A name repeated in `names` just resolves the same
  // column twice, which the AND below absorbs — drops stay idempotent.
  let gating = names.map(n => self.get_column(n))
  // No gating column carries a null (so also: an empty gate set) → no row can
  // be dropped. Return `self` rather than materialising masks and gathering
  // an identical copy; `null_count` is O(1) for a `Numeric` column.
  if gating.all(c => c.storage().null_count() == 0) {
    return self
  }
  // Materialise each gating column's validity mask (`validity_bools` skips the
  // throwaway bitmap for any `Numeric` gating column in the mix).
  let masks = gating.map(c => validity_bools(c.storage()))
  // Keep row `i` when every gating mask is valid there. The kept indices come
  // straight from `[0, nrows)`, so `take` cannot fail.
  let kept = Array::makei(self.nrows(), i => i).filter(i => masks.all(m => m[i]))
  self.gather(kept)
}
