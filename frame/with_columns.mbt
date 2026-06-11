///|
/// Evaluate each expression against `self` and add the results as
/// columns — the expression twin of `with_column(Series)`: derived columns
/// are *declared* (`col("a") + col("b")`) rather than pre-materialised.
/// The full construction surface evaluates — arithmetic, comparisons,
/// Kleene logic, `not` / null probes, aggregations (length-1, broadcast
/// back over the frame), `cast`, `with_alias`, `when/then/otherwise` —
/// under the dtype / null / NaN rules documented in `expr_eval.mbt`.
///
/// Naming and placement:
/// - each result takes its expression's output name — the leftmost column
///   reference, or `"literal"` for a pure-literal tree (`expr_output_name`);
/// - an output name already present in `self` **replaces** that column in
///   place (original position kept);
/// - a new output name **appends** rightmost, in expression order;
/// - two expressions producing the same output name raise
///   `DuplicateColumn` at the second — nothing silently wins.
///
/// Length-1 results (literals) broadcast to `nrows` — to zero rows on an
/// empty frame. Errors (unknown columns, dtype mismatches, the
/// unrepresentable `Null` literal) surface here at evaluation time;
/// building the expressions was total. `with_columns([])` returns an equal
/// frame.
pub fn DataFrame::with_columns(
  self : DataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  // `column_series` returns a fresh, owned array (the same guarantee
  // `with_column` relies on), so in-place replacement can't perturb `self`.
  let out = self.column_series()
  let seen : Map[String, Unit] = {}
  for expr in exprs {
    let evaluated = eval_expr(expr, self, scope)
    let column = if evaluated.len() == n {
      evaluated
    } else {
      // Evaluation yields |scope| or 1 — anything shorter than the frame
      // is a length-1 literal / aggregate, broadcast to every row.
      gather_series(evaluated, Array::make(n, 0))
    }
    let name = expr_output_name(expr)
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    let renamed = column.rename(name)
    match self.name_to_index.get(name) {
      Some(i) => out[i] = renamed
      None => out.push(renamed)
    }
  }
  DataFrame::new(out)
}
