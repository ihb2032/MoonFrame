///|
/// Keep only the rows where `predicate` evaluates to `true` — the
/// expression twin of the closure `filter`. Where a closure is opaque
/// host code invoked row by row, an `Expr` predicate is *data*: it
/// evaluates vectorized (one column pass, not one call per row), it can
/// be printed, and a lazy `Filter` node can introspect it for predicate
/// pushdown — which is why this method exists alongside `filter`.
///
/// The predicate must evaluate to a `Bool` column (`TypeMismatch`
/// otherwise). A row is kept where its cell is `true`; `false` **and
/// null** cells drop the row (the Polars rule — an unknown is not a
/// keep). A length-1 result — a literal, or an aggregation comparison
/// like `col("qty").sum().gt(lit_int(0))` — broadcasts over the frame,
/// keeping every row or none.
///
/// The returned frame has the same schema as `self` (a
/// rejects-everything predicate leaves a 0-row frame with the original
/// schema), and every column keeps its storage backend, as for the
/// closure `filter`. Evaluation errors (unknown columns, dtype
/// mismatches) surface here; building the predicate was total.
pub fn DataFrame::filter_where(
  self : DataFrame,
  predicate : @expr.Expr,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  let evaluated = eval_expr(predicate, self, Array::makei(n, i => i))
  // Evaluation yields a frame-tall or length-1 column — stretch a
  // length-1 mask (literal / aggregation) over the frame, down to zero
  // rows on an empty one.
  let mask = if evaluated.len() == n {
    evaluated
  } else {
    gather_series(evaluated, Array::make(n, 0))
  }
  let cells = match mask.storage().data() {
    @column.ColumnData::Bool(a) => a
    _ =>
      raise @types.DataError::TypeMismatch(
        "filter_where predicate must be Bool, got " + mask.dtype().to_string(),
      )
  }
  // A null cell fails `valid`, so it drops its row alongside `false`.
  let valid = mask.storage().validity().to_bools()
  let kept = Array::makei(n, i => i).filter(i => valid[i] && cells[i])
  // Every kept index came from `[0, nrows)`, so `take` cannot fail.
  self.take(kept)
}
