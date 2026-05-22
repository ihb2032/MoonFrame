///|
/// Return a copy of `df` with one or more columns renamed. Renames
/// are applied in input order: each step's `new_name` becomes
/// visible to subsequent renames, which is what makes the three-step
/// swap `[(a, _t), (b, a), (_t, b)]` work.
///
/// Errors:
/// - `Err(ColumnNotFound(old_name))` — `old_name` doesn't exist (or
///   was already renamed away by an earlier step).
/// - `Err(DuplicateColumn(new_name))` — `new_name` collides with
///   another column that still bears that name at this step.
///
/// An empty mapping is a structural no-op. A `(name, name)` mapping
/// is a no-op that still validates the source name's existence.
///
/// All structural invariants follow from re-running `DataFrame::new`
/// at the end, which catches any residual duplicate.
pub fn rename(
  df : @frame.DataFrame,
  mapping : Array[(String, String)],
) -> Result[@frame.DataFrame, @types.DataError] {
  // Work on a mutable name vector aligned with the column vector, so
  // each step sees the result of earlier renames.
  let names : Array[String] = df.columns()
  for pair in mapping {
    let (old_name, new_name) = pair
    // Find the position of old_name in the current name vector.
    let mut idx = -1
    for i, n in names {
      if n == old_name {
        idx = i
        break
      }
    }
    if idx < 0 {
      return Err(@types.DataError::ColumnNotFound(old_name))
    }
    if old_name != new_name {
      // Reject collisions with any *other* current name.
      for i, n in names {
        if i != idx && n == new_name {
          return Err(@types.DataError::DuplicateColumn(new_name))
        }
      }
    }
    names[idx] = new_name
  }
  // Rebuild the column list with the final names. The original column
  // ordering and identity are preserved; only the per-column `name` is
  // refreshed via `Series::rename`.
  let new_cols : Array[@frame.Series] = []
  let originals = df.columns()
  for i, _ in originals {
    // `get_column_at` cannot fail in [0, ncols).
    let original = df.get_column_at(i).unwrap()
    new_cols.push(original.rename(names[i]))
  }
  @frame.DataFrame::new(new_cols)
}
