///|
/// Project the frame to exactly the evaluated expressions — MoonFrame's
/// single `select` verb (Polars' `df.select(...)`). Each expression is
/// evaluated over the whole frame under the dtype / null / NaN rules in
/// `expr_eval.mbt`, so a projection can pick an existing column
/// (`col("a")`), compute a new one (`col("a") + col("b")`), aggregate
/// (`col("a").sum()`), or inject a literal. The plain names-only projection
/// of earlier versions is `select([col("a"), col("b")])` — or, equivalently,
/// `select(cols(["a", "b"]))` — and behaves identically: a list of bare
/// `col` references projects those columns in that order.
///
/// Output height (the Polars `select` rule). Evaluation yields columns
/// that are frame-tall or length-1 (literals and aggregations):
/// - any frame-tall result fixes the height at `self.nrows()`, and every
///   length-1 result broadcasts up to it — down to zero rows on an empty
///   frame;
/// - if **every** expression reduces to length 1, the output is a single
///   row: `df.select([col("a").sum()])` is the one-row summary frame, not
///   `nrows` copies of it.
///
/// Naming follows `with_columns`: each column takes its expression's
/// output name (alias, else leftmost column reference, else `"literal"`),
/// and a name produced twice raises `DuplicateColumn` at the second
/// expression — errors surface in expression order, before later
/// expressions are evaluated. `select([])` collapses to the 0×0 frame.
///
/// Evaluation errors (unknown columns, dtype mismatches, the
/// unrepresentable `Null` literal) surface here; building the expressions
/// was total.
pub fn DataFrame::select(
  self : DataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  let scope = Array::makei(self.nrows(), i => i)
  let evaluated : Array[Series] = []
  let seen : Map[String, Unit] = Map([])
  for expr in exprs {
    let column = eval_expr(expr, self, scope)
    let name = expr_output_name(expr)
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    evaluated.push(column.rename(name))
  }
  // The output height is the frame's own row count when any result is
  // frame-tall, otherwise 1 — every result is then a length-1 literal or
  // aggregation, which collapses to a single summary row. Most results are
  // drawn from {1, nrows} (evaluated under the whole-frame scope), but a
  // `lit_series` carries its OWN length: one that is neither 1 nor `nrows` is
  // not frame-tall and is rejected by `broadcast_series` below with the same
  // `LengthMismatch` `with_columns` raises, rather than silently dictating an
  // off-frame output height.
  let n = self.nrows()
  let mut height = 1
  for column in evaluated {
    if column.len() == n {
      height = n
    }
  }
  DataFrame::new(evaluated.map(column => broadcast_series(column, height)))
}
