///|
/// Project the frame down to the *evaluated* expressions — the expression
/// twin of `select(Array[String])`: where `select` can only pick existing
/// columns by name, `select_exprs` builds an entirely new frame whose
/// columns are computed (`col("a") + col("b")`, aggregations, literals, …)
/// under the dtype / null / NaN rules documented in `expr_eval.mbt`.
///
/// Output height (the Polars `select` rule). Evaluation yields columns
/// that are frame-tall or length-1 (literals and aggregations):
/// - any frame-tall result fixes the height at `self.nrows()`, and every
///   length-1 result broadcasts up to it — down to zero rows on an empty
///   frame;
/// - if **every** expression reduces to length 1, the output is a single
///   row: `df.select_exprs([col("a").sum()])` is the one-row summary
///   frame, not `nrows` copies of it.
///
/// Naming follows `with_columns`: each column takes its expression's
/// output name (alias, else leftmost column reference, else `"literal"`),
/// and a name produced twice raises `DuplicateColumn` at the second
/// expression — errors surface in expression order, before later
/// expressions are evaluated. `select_exprs([])` collapses to the 0×0
/// frame, exactly like `select([])`.
///
/// Evaluation errors (unknown columns, dtype mismatches, the
/// unrepresentable `Null` literal) surface here; building the expressions
/// was total.
pub fn DataFrame::select_exprs(
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
