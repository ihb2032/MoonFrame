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
/// Raises:
/// - `ColumnNotFound(name)` — a resolved name does not exist. Reported on
///   the first offending key in `columns` order.
///
/// Structural invariants on the returned frame follow from
/// `DataFrame::new` (called with the surviving column subset).
pub fn DataFrame::drop(
  self : DataFrame,
  columns : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  // Resolve-validate-and-collect in one pass: each key's `output_name` names
  // the column to drop, `get_column` raises `ColumnNotFound` on the first
  // unknown name — so a bad name surfaces before any survivor list is built —
  // and `Map::from_array` folds the names into a drop set where duplicate
  // entries collapse (matching the idempotent-drop contract).
  let to_drop : Map[String, Unit] = Map::from_array(
    columns.map(key => {
      let name = expr_output_name(key)
      let _ = self.get_column(name)
      (name, ())
    }),
  )
  let survivors = self.column_series().filter(s => !to_drop.contains(s.name()))
  DataFrame::new(survivors)
}
