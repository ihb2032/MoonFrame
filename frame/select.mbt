// The projection verbs: `select` keeps exactly the evaluated expressions,
// `drop` removes the named columns — the two halves of choosing what a
// frame's columns are.

///|
/// Project the frame to exactly the evaluated expressions — MoonFrame's
/// single `select` verb (Polars' `df.select(...)`). Each expression is
/// evaluated over the whole frame under the evaluator's shared dtype / null /
/// NaN rules, so a projection can pick an existing column
/// (`col("a")`), compute a new one (`col("a") + col("b")`), aggregate
/// (`col("a").sum()`), or inject a literal. The plain names-only projection
/// of earlier versions is `select([col("a"), col("b")])` — or, equivalently,
/// `select(cols(["a", "b"]))` — and behaves identically: a list of bare
/// `col` references projects those columns in that order.
///
/// Output height (the Polars `select` rule), under the shared length
/// contract:
/// - any frame-tall result fixes the height at `self.nrows()`, and every
///   length-1 result broadcasts up to it — down to zero rows on an empty
///   frame;
/// - if **every** expression reduces to length 1, the output is a single
///   row: `df.select([col("a").sum()])` is the one-row summary frame, not
///   `nrows` copies of it;
/// - a result of any other length — only a `lit_series` or a `map_batches`
///   closure can produce one — raises `LengthMismatch` rather than dictating
///   an off-frame height.
///
/// Column metadata follows the cells: an entry that only renames a column (a
/// bare `col("x")`, or an aliased one) carries that column's `Field`, declared
/// `nullable` included, while a computed entry gets a field derived from the
/// result.
///
/// Naming follows `with_columns`: each column takes its expression's
/// output name (alias, else leftmost column reference, else `"literal"`),
/// and a name produced twice raises `DuplicateColumn` at the second
/// expression — errors surface in expression order, before later
/// expressions are evaluated. `select([])` is the projection to zero
/// columns, and like any projection it keeps the frame's height: the result
/// is `self.nrows() × 0`.
///
/// Evaluation errors (unknown columns, dtype mismatches, the
/// unrepresentable `Null` literal, an off-frame result length) surface here;
/// building the expressions was total.
pub fn DataFrame::select(
  self : DataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  let scope = Array::makei(self.nrows(), i => i)
  let evaluated : Array[Series] = []
  let fields : Array[@types.Field] = []
  let source_fields = self.schema.fields()
  let seen : Map[String, Unit] = Map([])
  for expr in exprs {
    let column = eval_expr(expr, self, scope)
    let name = expr.output_name()
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    fields.push(self.carried_field(source_fields, expr, column, name))
    evaluated.push(column.rename(name))
  }
  // The output height is the frame's own row count when any result is
  // frame-tall, otherwise 1 — every result is then a length-1 literal or
  // aggregation, which collapses to a single summary row. A result of neither
  // length is off-frame rather than height-setting, and `broadcast_series`
  // below rejects it under the shared length contract.
  //
  // Projecting to *no* columns is the one case with no result to read a height
  // from. It keeps the frame's own: a projection that drops every column is
  // still a projection, so `select([])` is `nrows × 0` rather than a summary
  // row of nothing.
  let n = self.nrows()
  let mut height = if evaluated.is_empty() { n } else { 1 }
  for column in evaluated {
    if column.len() == n {
      height = n
    }
  }
  DataFrame::from_parts_with_fields(
    evaluated.map(column => @kernel.broadcast_series(column, height)),
    fields,
    height,
  )
}

///|
/// Return a copy of `self` with the columns named by `columns` removed.
/// Remaining columns keep their relative order — MoonFrame's single drop
/// verb (Polars' `df.drop(...)`).
///
/// Each entry is an `Expr` resolved to a column name through
/// `Expr::output_name`: a bare `col("x")` names `"x"`, an alias names
/// the alias. The container is `Array[Expr]` so a future column selector
/// (`all` / `exclude`) can drop the matched set without a signature change;
/// today only `col` / aliased keys are meaningful and the expression is never
/// evaluated — only its output name is consulted. The name-pattern selectors
/// that do exist (`cols_starts_with` / `cols_ends_with` / `cols_contains` /
/// `cols_matching`) need no support here: each expands to a plain `col` list
/// against a frame before the call.
///
/// Duplicate keys are tolerated and act idempotently — dropping
/// `[col("a"), col("a")]` is the same as dropping `[col("a")]`. This matches
/// pandas / polars behavior and avoids forcing callers to deduplicate
/// upstream when assembling a drop list from multiple sources.
///
/// Dropping nothing (`drop([])`) returns the frame itself — a literal
/// identity, declared schema included. A drop that does remove a column
/// filters the field vector alongside the column vector, so every surviving
/// column keeps the field it arrived with, its declared `nullable` included.
///
/// Raises:
/// - `ColumnNotFound(name)` — a resolved name does not exist. Reported on
///   the first offending key in `columns` order.
///
/// Dropping *every* column keeps the height, like any other projection to
/// zero columns: the result is `self.nrows() × 0`, not `0×0`.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::from_parts` (called with the surviving column subset and the
/// frame's own row count, which removing columns never changes).
pub fn DataFrame::drop(
  self : DataFrame,
  columns : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  // No keys, nothing to resolve and nothing to remove: return `self` rather
  // than rebuilding an equal frame, so the no-op keeps the schema it was
  // handed (a rebuild through `DataFrame::DataFrame` re-derives it and resets a
  // declared `nullable = false`).
  if columns.is_empty() {
    return self
  }
  // Resolve each key's `output_name` to its column (`resolve_subset_columns`
  // raises `ColumnNotFound` on the first unknown name, so a bad name surfaces
  // before any survivor list is built), then fold the names into a drop set —
  // `Map::from_array` collapses duplicate entries, matching the idempotent-drop
  // contract.
  let to_drop : Map[String, Unit] = Map::from_array(
    self.resolve_subset_columns(columns).map(s => (s.name(), ())),
  )
  // Columns and fields are index-aligned and name-for-name equal (INV3), so the
  // same predicate filters both: a survivor keeps the field it arrived with,
  // declared `nullable` included, rather than one re-derived from its dtype.
  let survivors = self.column_series().filter(s => !to_drop.contains(s.name()))
  let fields = self.schema.fields().filter(f => !to_drop.contains(f.name()))
  DataFrame::from_parts_with_fields(survivors, fields, self.nrows)
}
