///|
/// Drop every row in which **any** column has a null cell. The schema
/// (column names, dtypes, order) is preserved verbatim; only the row
/// count shrinks.
///
/// A 0-column frame is a special case: there are no columns whose
/// validity could fail, so every row passes the test. With
/// `DataFrame::new`'s convention that a 0-column frame has `nrows = 0`,
/// the output is structurally identical to the input.
///
/// On a well-formed `self`, `drop_nulls` adds no failure of its own —
/// it routes through `drop_nulls_in(self.columns())`, whose only failure
/// (an unknown column name) cannot arise from names taken straight from
/// the frame.
pub fn DataFrame::drop_nulls(
  self : DataFrame,
) -> DataFrame raise @types.DataError {
  // Cover every column by routing through `drop_nulls_in` with the
  // full column list; the implementation already handles the AND-merge
  // and the 0-column edge case.
  self.drop_nulls_in(self.columns())
}

///|
/// Drop every row in which any of the columns named in `names` has a
/// null cell. Columns not listed in `names` are not consulted, even if
/// they happen to carry nulls — this is the knob that distinguishes
/// `drop_nulls_in` from `drop_nulls`.
///
/// Duplicate entries in `names` are tolerated and act idempotently;
/// asking the same column to gate twice is the same as asking once.
///
/// An empty `names` list collapses to a no-op identity: there are no
/// gating columns, so every row passes. The schema is preserved.
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` does not exist in `self`. Reported
///   on the first offending entry in `names`.
pub fn DataFrame::drop_nulls_in(
  self : DataFrame,
  names : Array[String],
) -> DataFrame raise @types.DataError {
  // Materialise each gating column's validity mask, in `names` order;
  // `get_column` raises `ColumnNotFound` on the first unknown name, so a
  // bad name surfaces before any per-row work runs. A name repeated in
  // `names` just contributes its mask twice, which the AND below absorbs —
  // drops stay idempotent, matching the documented contract (and the
  // primary caller `drop_nulls` passes the already-unique `columns()`).
  let masks = names.map(n => self.get_column(n).storage().validity().to_bools())
  // Keep row `i` when every gating mask is valid there — vacuously true
  // when `names` is empty, so an empty gate set is the identity. The kept
  // indices come straight from `[0, nrows)`, so `take` cannot fail.
  let kept = Array::makei(self.nrows(), i => i).filter(i => masks.all(m => m[i]))
  self.take(kept)
}
