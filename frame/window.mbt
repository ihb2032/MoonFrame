// The row-window verbs: `head` / `tail` / `slice` / `gather` — the transforms
// that keep a frame's schema verbatim and move or trim *rows*, one verb family
// per file like the other verbs (`reverse` for row order,
// `unique` for row identity, `sort` for row arrangement). The row cap
// they share is `clamp_take`, the same saturating limit behind the
// table renderer's visible window.

///|
/// First `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails. Also exposed under its Polars / SQL name
/// `limit` (via `#alias`) — the eager twin of `LazyFrame::limit`, keeping
/// the two surfaces verb-for-verb aligned.
#alias(limit)
pub fn DataFrame::head(self : DataFrame, n : Int) -> DataFrame {
  let m = @order.clamp_take(n, self.nrows)
  // `0 <= m <= nrows == c.len()`, so the contiguous row slice is in-bounds
  // and needs no bounds-checking `Result`.
  let new_cols : Array[Series] = self.columns.map(c => slice_series(c, 0, m))
  // Names and schema are unchanged — reuse the cache verbatim.
  self.with_same_schema(new_cols, m)
}

///|
/// Last `n` rows (or all rows if `n >= nrows`). Negative `n` clamps to
/// `0`. Total — never fails.
pub fn DataFrame::tail(self : DataFrame, n : Int) -> DataFrame {
  let m = @order.clamp_take(n, self.nrows)
  let start = self.nrows - m
  // Same in-bounds argument as `head`: `start + m == nrows == c.len()`.
  let new_cols : Array[Series] = self.columns.map(c => slice_series(c, start, m))
  self.with_same_schema(new_cols, m)
}

///|
/// A length-first row window — Polars' `slice(offset, length)`. The window
/// starts `offset` rows in: a negative `offset` counts from the end
/// (`slice(-1)` is the last row), saturating to the frame's first row when
/// it reaches past it. `length` omitted runs to the frame's end; a given
/// `length` saturates at the end, and a negative one is empty. Total —
/// never fails: every out-of-range argument lands somewhere sensible rather
/// than raising, the same saturating convention `head` / `tail` already
/// follow.
pub fn DataFrame::slice(
  self : DataFrame,
  offset : Int,
  length? : Int,
) -> DataFrame {
  let start = @order.slice_start(offset, self.nrows)
  let len = @order.slice_len(start, self.nrows, length)
  // `0 <= start` and `start + len <= nrows == c.len()` by construction, so
  // the contiguous slice is in-bounds and needs no bounds-checking `Result`.
  let new_cols : Array[Series] = self.columns.map(c => {
    slice_series(c, start, len)
  })
  self.with_same_schema(new_cols, len)
}

///|
/// Gather rows by index. Returns a frame whose i-th row is
/// `self[indices[i]]`. Any out-of-bounds index surfaces as
/// `IndexOutOfBounds(idx)`.
pub fn DataFrame::gather(
  self : DataFrame,
  indices : Array[Int],
) -> DataFrame raise @types.DataError {
  for i in indices {
    if i < 0 || i >= self.nrows {
      raise @types.DataError::IndexOutOfBounds(i)
    }
  }
  // An identity permutation (`indices == [0, nrows)`) gathers every row in
  // place — a no-op rebuild — so return `self`. The check is `O(n)` with an
  // early exit, dwarfed by the gather it can skip; a genuine reorder or a
  // strict subset (a `filter` / `drop_nulls` that drops rows) fails it on the
  // length test or the first out-of-place index.
  if is_identity_perm(indices, self.nrows) {
    return self
  }
  // Indices were just validated against `self.nrows`, so the per-column
  // gather is in-bounds.
  let new_cols = self.columns.map(c => gather_series(c, indices))
  self.with_same_schema(new_cols, indices.length())
}
