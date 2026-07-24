///|
/// Evaluate each expression against `self` and add the results as
/// columns. Derived columns are *declared* (`col("a") + col("b")`) rather
/// than pre-materialised (a `lit_series(s)` carries a ready-made `Series`).
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
/// building the expressions was total. `with_columns([])` adds nothing and
/// returns the frame itself — a literal identity, declared schema included.
/// A call that adds or replaces a column leaves the schema of every *other*
/// column alone: each keeps the field it arrived with, declared `nullable`
/// included. The column an expression writes takes a carried field when the
/// expression only renames one (a bare `col("x")`, or an aliased one — so a
/// replacement inherits from whichever column now supplies the cells) and a
/// freshly derived one, `nullable = true`, when it computes.
pub fn DataFrame::with_columns(
  self : DataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  // Nothing to evaluate and nothing to add: return `self` rather than
  // rebuilding an equal frame.
  if exprs.is_empty() {
    return self
  }
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  // `column_series` returns a fresh, owned array, so in-place replacement
  // can't perturb `self`.
  let out = self.column_series()
  // The field vector travels beside the column vector: an untouched column
  // keeps the field it arrived with, and a replaced or added one takes the
  // field its expression carries. `fields` is mutated in step with `out`, so
  // the source lookup reads its own copy.
  let fields = self.schema.fields()
  let source_fields = self.schema.fields()
  let seen : Map[String, Unit] = Map([])
  for expr in exprs {
    let column = broadcast_series(eval_expr(expr, self, scope), n)
    let name = expr_output_name(expr)
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    let field = self.carried_field(source_fields, expr, column, name)
    let renamed = column.rename(name)
    match self.name_to_index.get(name) {
      Some(i) => {
        out[i] = renamed
        fields[i] = field
      }
      None => {
        out.push(renamed)
        fields.push(field)
      }
    }
  }
  DataFrame::from_parts_with_fields(out, fields, n)
}
