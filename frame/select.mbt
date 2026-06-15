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
  let seen : Map[String, Unit] = {}
  for expr in exprs {
    let column = eval_expr(expr, self, scope)
    let name = expr_output_name(expr)
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    evaluated.push(column.rename(name))
  }
  // Lengths are drawn from {1, nrows} (every expression evaluated under
  // the same whole-frame scope), so any non-1 length *is* the frame
  // height; only when every expression reduced to a scalar does the
  // output collapse to one row.
  let mut height = 1
  for column in evaluated {
    if column.len() != 1 {
      height = column.len()
    }
  }
  let broadcasted : Array[Series] = []
  for column in evaluated {
    broadcasted.push(broadcast_series(column, height))
  }
  DataFrame::new(broadcasted)
}
