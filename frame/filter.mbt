///|
/// Keep only the rows where `predicate` evaluates to `true` — MoonFrame's
/// single row-selection verb. The predicate is an `Expr`, not a closure:
/// it evaluates vectorized (one column pass, not one call per row), it can
/// be printed, and a lazy `Filter` node can introspect it for predicate
/// pushdown. A row-wise host predicate is still reachable through the
/// `map_many` escape hatch — `filter(map_many(label~, inputs, f))` reifies
/// the v0.1 closure predicate as a `Bool`-returning `Expr`.
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
/// schema), and every column keeps its storage backend. Evaluation errors
/// (unknown columns, dtype mismatches) surface here; building the
/// predicate was total.
pub fn DataFrame::filter(
  self : DataFrame,
  predicate : @expr.Expr,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  // Evaluation yields a frame-tall or length-1 column — stretch a
  // length-1 mask (literal / aggregation) over the frame, down to zero
  // rows on an empty one.
  let mask = broadcast_series(eval_expr(predicate, self, scope), n)
  let cells = match mask.storage().data() {
    @column.ColumnData::Bool(a) => a
    _ =>
      raise @types.DataError::TypeMismatch(
        "filter predicate must be Bool, got \{mask.dtype()}",
      )
  }
  // A null cell fails `valid`, so it drops its row alongside `false`.
  let valid = mask.storage().validity().to_bools()
  let kept = scope.filter(i => valid[i] && cells[i])
  // Every kept index came from `[0, nrows)`, so `take` cannot fail.
  self.take(kept)
}
