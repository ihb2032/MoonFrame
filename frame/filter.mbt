///|
/// Keep only the rows where `predicate` evaluates to `true` — MoonFrame's
/// single row-selection verb. The predicate is an `Expr`, not a closure, and
/// that is what the built-in expression algebra buys: it evaluates vectorized
/// (one column pass per node, not one call per row), it can be printed, and a
/// lazy `Filter` node can introspect it for predicate pushdown. A row-wise host
/// predicate is still reachable through the `map_many` escape hatch —
/// `filter(map_many(label~, inputs, f))` reifies the original closure predicate
/// as a `Bool`-returning `Expr` — but a closure buys none of the three: the map
/// node renders as its label with the closure opaque, the optimizer can only
/// treat it as a barrier and sinks no filter across it, and `f` is called once
/// per row (once per batch for `map_batches`).
///
/// The predicate must evaluate to a `Bool` column (`TypeMismatch`
/// otherwise). A row is kept where its cell is `true`; `false` **and
/// null** cells drop the row (the Polars rule — an unknown is not a
/// keep). The mask rides the length contract in `expr_eval.mbt`: a length-1
/// result — a literal, or an aggregation comparison like
/// `col("qty").sum().gt(lit_int(0))` — broadcasts over the frame, keeping every
/// row or none, while a mask that is neither frame-tall nor length-1 raises
/// `LengthMismatch` instead of selecting rows by position.
///
/// The returned frame has the same schema as `self` (a
/// rejects-everything predicate leaves a 0-row frame with the original
/// schema). A filter that keeps every row returns `self` unchanged; once
/// any row drops, the surviving cells are re-gathered and each column
/// converges onto the backend its content implies (an all-valid numeric
/// column lands on `Numeric`) — the engine-wide "backend is a function of
/// content" rule, not a verbatim carry-over. Evaluation errors (unknown
/// columns, dtype mismatches, an off-frame mask length) surface here; building
/// the predicate was total.
pub fn DataFrame::filter(
  self : DataFrame,
  predicate : @expr.Expr,
) -> DataFrame raise @types.DataError {
  // Every kept index came from `[0, nrows)`, so `gather` cannot fail.
  self.gather(filter_row_indices(self, predicate))
}

///|
/// The row indices `filter` would keep, ascending. Split out for the lazy file
/// sources: a scan that absorbed a predicate builds only its key columns,
/// asks for the surviving rows here, and then materialises the remaining
/// columns for those rows alone — so the dropped rows are never parsed.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn filter_row_indices(
  df : DataFrame,
  predicate : @expr.Expr,
) -> Array[Int] raise @types.DataError {
  let self = df
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  // Stretch a length-1 mask (literal / aggregation) over the frame, down to
  // zero rows on an empty one, and reject an off-frame one — the shared length
  // contract (`expr_eval.mbt`).
  let mask = @kernel.broadcast_series(eval_expr(predicate, self, scope), n)
  // The rows the mask keeps, read on the column's own side of the seam — a
  // null cell is not a keep, alongside `false`. `None` means the predicate
  // evaluated to another dtype, and what *that* means is this verb's call, so
  // the message is raised here rather than at the column seam.
  match mask_true_indices(mask) {
    Some(kept) => kept
    None =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got \{mask.dtype()}",
        ),
      )
  }
}
