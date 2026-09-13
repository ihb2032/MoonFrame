// The scaffolding the verbs rebuild a frame through — the package-private
// constructors and the expression classifier shared by the verb files, which
// is why they live apart from the type core (`dataframe.mbt` keeps the type,
// its public constructors, and the accessors; `window.mbt` keeps the one verb
// family that needed no scaffolding beyond `with_same_schema`). Consumers:
//
//   - `from_parts_with_fields` ← select / drop / with_columns / reverse
//     (and, through it, the `from_parts` seam io builds frames from)
//   - `with_same_schema`       ← the row-window verbs (head / tail / slice /
//     gather), fill_null, reverse, unique
//   - `carried_field`          ← select / with_columns
//   - `with_renamed_fields`    ← rename / rename_with
//   - `resolve_subset_columns` ← drop / drop_nulls / unique
//
// A new verb starts here: pick the rebuild path that matches what it changes
// (rows only, an edited field vector, renamed fields) instead of
// reconstructing one.

///|
/// `from_parts` under a caller-supplied field vector — the constructor behind
/// the projections that *carry* metadata rather than re-derive it (`select`,
/// `drop`, `with_columns`). `fields` is index-aligned with `columns` and
/// agrees with each column's name and dtype; what it can differ in is the
/// declared `nullable`, which a derived field would reset to the `Field`
/// constructor default. Re-validated through `Schema::Schema`, so a repeated
/// name still raises `DuplicateColumn`.
fn DataFrame::from_parts_with_fields(
  columns : Array[Series],
  fields : Array[@types.Field],
  nrows : Int,
) -> DataFrame raise @types.DataError {
  let columns = columns.copy()
  // INV7, closed here rather than asked of the caller. For a frame with
  // columns the length check below already forces a non-negative height (no
  // `Series` is shorter than empty), but it is vacuous at zero columns —
  // exactly the shape this constructor exists to build — so `N×0` is the one
  // case where a stray negative would reach a `DataFrame` and stay there.
  if nrows < 0 {
    raise @types.DataError::InvalidOperation(
      "a frame's row count cannot be negative: \{nrows}",
    )
  }
  if !columns.all(c => c.len() == nrows) {
    raise @types.DataError::LengthMismatch
  }
  let schema = @types.Schema::Schema(fields)
  { schema, columns, nrows, name_to_index: index_by_name(columns), }
}

///|
/// Rebuild the frame from `new_cols` and `nrows`, reusing this frame's schema
/// and `O(1)` name→index cache verbatim. The schema-preserving constructor
/// behind the row-only transforms (`head` / `tail` / `slice` / `gather` /
/// `fill_null` / `reverse` / `unique`): the column values or backing change but the names
/// and dtypes do not, so the cache stays valid and these never pay to rebuild it through
/// `DataFrame::DataFrame` (`O(n)`, and able to raise). Total — the caller guarantees
/// `new_cols` still matches the schema and carries `nrows` rows each.
///
/// Spelt as a struct update so that a field added to `DataFrame` later is
/// carried over by default — only what a row transform actually changes is
/// named here.
fn DataFrame::with_same_schema(
  self : DataFrame,
  new_cols : Array[Series],
  nrows : Int,
) -> DataFrame {
  { ..self, columns: new_cols, nrows, }
}

///|
/// The column an expression only *renames*, if any. `col("x")` reads column
/// `x` and changes nothing about its cells; `col("x").with_alias("y")` changes
/// nothing but the name. Every other expression computes — including `cast`,
/// which keeps the cells but not the dtype — so it has no source column whose
/// metadata the result could inherit.
///
/// Written without a wildcard so a new `ExprNode` variant has to state whether it
/// is a pure rename rather than defaulting to "no".
///
/// Aliases are peeled with a cursor rather than the call stack: `with_alias`
/// stacks without bound, so a recursive peel would overflow on a deep one — the
/// same reason every other expression walk in the engine is iterative. Only
/// `Alias` advances the cursor; every other variant is an answer, so the loop
/// runs once per alias and stops.
fn projection_source(expr : @ir.ExprNode) -> String? {
  let mut node = expr
  for ;; {
    match node {
      @ir.ExprNode::Alias(inner, _) => node = inner
      @ir.ExprNode::Col(name) => return Some(name)
      @ir.ExprNode::Lit(_)
      | @ir.ExprNode::LitSeries(_)
      | @ir.ExprNode::Binary(_, _, _)
      | @ir.ExprNode::Unary(_, _)
      | @ir.ExprNode::Agg(_, _)
      | @ir.ExprNode::Str(_, _)
      | @ir.ExprNode::Cast(_, _)
      | @ir.ExprNode::Ternary(_, _, _)
      | @ir.ExprNode::FillNull(_, _)
      | @ir.ExprNode::FillNan(_, _)
      | @ir.ExprNode::IsIn(_, _)
      | @ir.ExprNode::IsBetween(_, _, _, _)
      | @ir.ExprNode::Map(_, _, _)
      | @ir.ExprNode::MapBatches(_, _, _, _) => return None
    }
  }
}

///|
/// The `Field` a projected column carries. An expression that only renames a
/// column leaves its cells untouched, so the result keeps that column's
/// declared `nullable` under the output name; a computed one gets a field
/// derived from the result, whose flag is the `Field` constructor default.
///
/// `source_fields` is the frame's own field vector, materialised once by the
/// caller rather than per expression. A named source column is always present:
/// the expression was evaluated against this frame first, and a name the frame
/// lacks raised `ColumnNotFound` there.
fn DataFrame::carried_field(
  self : DataFrame,
  source_fields : Array[@types.Field],
  expr : @expr.Expr,
  column : Series,
  name : String,
) -> @types.Field {
  let carried = match projection_source(expr.node()) {
    Some(src) => self.name_to_index.get(src).map(i => source_fields[i])
    None => None
  }
  match carried {
    Some(field) => field.rename(name)
    None => @types.Field::Field(name, column.dtype())
  }
}

///|
/// Rebuild the frame under an edited field vector — the rename verbs' sibling
/// of `with_same_schema`. `fields` is index-aligned with the column vector and
/// differs from `self.schema`'s only in the field *names* (`rename` /
/// `rename_with` map each through `Field::rename`), so this re-validates it
/// through `Schema::Schema` — `raise DuplicateColumn(name)` on the first repeat —
/// retitles each column to its field's name, and rebuilds the `O(1)`
/// name→index cache, which unlike `with_same_schema` cannot be reused because
/// the names moved. Row count and column order are untouched.
///
/// Carrying the fields rather than re-deriving them through `DataFrame::DataFrame` is
/// what keeps a renamed column's metadata: that constructor names every field
/// with the `Field` constructor default, resetting a declared `nullable = false`,
/// while a rename by contract changes nothing but the name.
fn DataFrame::with_renamed_fields(
  self : DataFrame,
  fields : Array[@types.Field],
) -> DataFrame raise @types.DataError {
  let schema = @types.Schema::Schema(fields)
  // `fields` is index-aligned with the column vector, so `columns[i]` is
  // in-bounds and the rebuilt schema mirrors the columns name-for-name.
  let new_cols = fields.mapi((i, f) => self.columns[i].rename(f.name()))
  {
    schema,
    columns: new_cols,
    nrows: self.nrows,
    name_to_index: index_by_name(new_cols),
  }
}

///|
/// Resolve a `subset` selector — an `Array[Expr]` of column keys — to the named
/// columns, validating in order. Each key names a column through
/// `Expr::output_name` (a bare `col("x")` names `"x"`, an alias names the
/// alias), and `get_column` raises `ColumnNotFound` on the first name absent
/// from the frame, before any per-row work runs. The key expression is **never
/// evaluated** — only its output name is consulted — the shared "name-only"
/// contract behind the `subset` of `drop`, `drop_nulls`, and `unique`. A
/// repeated key resolves the same column twice; each caller absorbs that (a
/// collapsing drop set, an AND of validity masks, a repeated group-key cell).
fn DataFrame::resolve_subset_columns(
  self : DataFrame,
  keys : Array[@expr.Expr],
) -> Array[Series] raise @types.DataError {
  keys.map(key => self.get_column(expr_output_name(key)))
}
