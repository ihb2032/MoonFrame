///|
/// Return a copy of `self` with the columns named by `columns` removed.
/// Remaining columns keep their relative order — MoonFrame's single drop
/// verb (Polars' `df.drop(...)`).
///
/// Each entry is an `Expr` resolved to a column name through the §0 naming
/// rule (`Expr::output_name`): a bare `col("x")` names `"x"`, an alias names
/// the alias. The container is `Array[Expr]` so a future column selector
/// (`all` / `exclude` / `starts_with`) can drop the matched set without a
/// signature change; today only `col` / aliased keys are meaningful and the
/// expression is never evaluated — only its output name is consulted.
///
/// Duplicate keys are tolerated and act idempotently — dropping
/// `[col("a"), col("a")]` is the same as dropping `[col("a")]`. This matches
/// pandas / polars behavior and avoids forcing callers to deduplicate
/// upstream when assembling a drop list from multiple sources.
///
/// Dropping nothing (`drop([])`) returns the frame itself — a literal
/// identity, declared schema included. A drop that does remove a column
/// rebuilds through `DataFrame::DataFrame`, whose derived schema declares every
/// surviving field `nullable = true`: the advisory flag is not propagated
/// across the projection, as for `select`.
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
  let survivors = self.column_series().filter(s => !to_drop.contains(s.name()))
  DataFrame::from_parts(survivors, self.nrows)
}
