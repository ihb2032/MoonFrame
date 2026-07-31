///|
/// Evaluate each expression against `self` and add the results as
/// columns. Derived columns are *declared* (`col("a") + col("b")`) rather
/// than pre-materialised (a `lit_series(s)` carries a ready-made `Series`).
/// Every `Expr` the evaluator supports is accepted here — aggregations
/// included, evaluating to length-1 and broadcasting back over the frame —
/// under the dtype / null / NaN rules documented in `expr_eval.mbt`, which is
/// the one place the node set is enumerated.
///
/// Naming and placement:
/// - each result takes its expression's output name — an alias if the tree
///   carries one, else the leftmost column reference, else `"literal"` for a
///   pure-literal tree (`expr_output_name`). The alias clause is what decides
///   replace-vs-append below: `col("a").with_alias("b")` appends `b`, it does
///   not replace `a`;
/// - an output name already present in `self` **replaces** that column in
///   place (original position kept);
/// - a new output name **appends** rightmost, in expression order;
/// - two expressions producing the same output name raise
///   `DuplicateColumn` at the second — nothing silently wins.
///
/// Every result rides the length contract in `expr_eval.mbt`: a frame-tall one
/// becomes the column, a length-1 one (a literal) broadcasts to `nrows` — to
/// zero rows on an empty frame — and any other length raises `LengthMismatch`,
/// which only a `lit_series` or a `map_batches` closure can produce. Errors
/// (unknown columns, dtype mismatches, the unrepresentable `Null` literal, an
/// off-frame length) surface here at evaluation time;
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
    let column = @kernel.broadcast_series(eval_expr(expr, self, scope), n)
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
