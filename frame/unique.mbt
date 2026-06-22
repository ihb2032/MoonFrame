///|
/// Drop duplicate rows, keeping the first occurrence of each distinct row —
/// Polars' `df.unique(maintain_order=True)`. Two rows are duplicates when
/// every cell is equal under the same composite `KeyCell` encoding `group_by`
/// and `join` use (see `frame/row_key.mbt`): a `Float` `NaN` equals `NaN`,
/// `-0.0` folds into `+0.0`, and — like a `group_by` key — a **null** cell is
/// an ordinary value, so two rows that are null in the same places (and equal
/// elsewhere) are duplicates. Result rows keep their **first-appearance**
/// order, so the output is deterministic without a sort. When duplicate rows
/// are dropped, a column that becomes all-valid may converge onto the
/// `Numeric` fast-path backend — exactly as `take` / `gather` do, since the
/// backend is a function of the gathered content, not the source; the schema,
/// values, and frame invariants are unchanged. (An all-distinct frame is
/// returned unchanged, so its backends are untouched.)
///
/// Total: dropping rows from a valid frame can neither change the schema nor
/// fail. A frame whose rows are already all distinct is returned unchanged
/// (the gather would be a no-op), as is a 0-row frame. (Polars' `subset` /
/// `keep` parameters — dedup on a column subset, or keep the last / drop all
/// duplicates — are deferred to a later release; this is the all-columns,
/// keep-first form.)
pub fn DataFrame::unique(self : DataFrame) -> DataFrame {
  let n = self.nrows()
  // Column-major cells, so a row's composite key is assembled by plain index
  // reads (`to_scalars` is total — no per-cell bounds-checked `get`).
  let cells = self.to_scalar_matrix()
  // First-appearance dedup: keep the first row index of each distinct
  // composite key. A `Map` membership test is the row-identity check, and
  // pushing `i` only on first sight keeps the surviving indices ascending and
  // in first-appearance order (the same `row_group_key` / first-insertion
  // discipline `group_by` relies on).
  let seen : Map[Array[KeyCell], Unit] = {}
  let kept : Array[Int] = []
  for i in 0..<n {
    let id = row_group_key(cells, i)
    if !seen.contains(id) {
      seen[id] = ()
      kept.push(i)
    }
  }
  // Every row distinct: `kept` is the identity `[0, n)`, so there is nothing
  // to drop — return `self` rather than rebuild it, mirroring `take`'s no-op
  // gather (and covering the 0-row frame, whose `kept` is empty).
  if kept.length() == n {
    return self
  }
  // `kept` is a strict subset of `[0, n)` by construction, so the per-column
  // gather is in-bounds with no bounds check (unlike the public `take`), and
  // the frame is rebuilt directly — keeping `unique` total.
  let new_cols = self.columns.map(c => gather_series(c, kept))
  self.with_same_schema(new_cols, kept.length())
}
