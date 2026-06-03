///|
/// Return a copy of `self` with one or more columns renamed. Renames
/// are applied in input order: each step's `new_name` becomes
/// visible to subsequent renames, which is what makes the three-step
/// swap `[(a, _t), (b, a), (_t, b)]` work.
///
/// Raises:
/// - `ColumnNotFound(old_name)` — `old_name` doesn't exist (or was
///   already renamed away by an earlier step).
/// - `DuplicateColumn(new_name)` — `new_name` collides with another
///   column that still bears that name at this step.
///
/// An empty mapping is a structural no-op. A `(name, name)` mapping
/// is a no-op that still validates the source name's existence.
///
/// All structural invariants follow from re-running `DataFrame::new`
/// at the end, which catches any residual duplicate.
pub fn DataFrame::rename(
  self : DataFrame,
  mapping : Array[(String, String)],
) -> DataFrame raise @types.DataError {
  // Work on a mutable name vector aligned with the column vector, so
  // each step sees the result of earlier renames.
  let names : Array[String] = self.columns()
  for pair in mapping {
    let (old_name, new_name) = pair
    // Locate old_name in the current name vector.
    let idx = match names.search(old_name) {
      Some(i) => i
      None => raise @types.DataError::ColumnNotFound(old_name)
    }
    // Reject a collision with any *other* current name. `names[idx]` is
    // still `old_name` here (≠ `new_name` in this branch), so any
    // occurrence of `new_name` must sit at a different slot — a plain
    // membership test is therefore equivalent to "exists at some i ≠ idx".
    if old_name != new_name && names.contains(new_name) {
      raise @types.DataError::DuplicateColumn(new_name)
    }
    names[idx] = new_name
  }
  // Rebuild the column list with the final names. The original column
  // ordering and identity are preserved; only the per-column `name` is
  // refreshed via `Series::rename`. `names` is index-aligned with the
  // column vector, so `cols[i]` is in-bounds.
  let cols = self.column_series()
  let new_cols = names.mapi((i, name) => cols[i].rename(name))
  DataFrame::new(new_cols)
}
