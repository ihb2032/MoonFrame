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
  // Validate every requested name up front so a missing column is
  // surfaced before any per-row work runs.
  let series_list : Array[Series] = []
  let seen : Map[String, Unit] = {}
  for n in names {
    if seen.contains(n) {
      continue
    }
    seen[n] = ()
    // `get_column` raises `ColumnNotFound(n)` for an unknown name.
    series_list.push(self.get_column(n))
  }
  // Materialise each gating column's validity mask once; `mask[i]` is then
  // a plain in-bounds read (every mask has `len == nrows`).
  let masks = series_list.map(s => s.storage().validity().to_bools())
  let n = self.nrows()
  let kept : Array[Int] = []
  for i in 0..<n {
    if masks.all(m => m[i]) {
      kept.push(i)
    }
  }
  // Indices were produced by a `[0, nrows)` loop, so `take` cannot
  // fail here.
  self.take(kept)
}
