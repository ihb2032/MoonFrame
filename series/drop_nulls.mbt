// The null-trimming verb: `drop_nulls` gathers the valid cells in order. A
// null-free source is returned unchanged, so an all-valid `Numeric` column
// stays on the fast path; a trimmed numeric result — now necessarily
// all-valid — canonicalises onto it.

///|
/// Drop every null cell. The returned series has `len = original.len -
/// original.null_count` and no null cells left. A source that already has no
/// nulls is returned unchanged — so an all-valid `Numeric` column stays on the
/// fast path (no bitmap to carry); otherwise the kept cells are gathered, and a
/// numeric result — now necessarily all-valid — canonicalises onto `Numeric`
/// (`gather_series`), so dropping nulls cannot leave a numeric column off the
/// fast path.
pub fn Series::drop_nulls(self : Series) -> Series {
  // No nulls → nothing to drop; return `self` instead of gathering every row
  // into an identical rebuild. `null_count` is O(1) for a `Numeric` column
  // (always 0, so it short-circuits here and stays on the fast path) and a
  // bitmap popcount for `Builtin`. Past this guard the column carries a null,
  // so it is necessarily `Builtin` — the mask read below sees a real bitmap.
  if self.storage.null_count() == 0 {
    return self
  }
  // Keep the indices of the valid cells, in order, then gather them —
  // `gather_series` rebuilds the series with a fully-valid bitmap.
  let valid = self.storage.validity().to_bools()
  let kept = Array::makei(valid.length(), i => i).filter(i => valid[i])
  self.gather_series(kept)
}
