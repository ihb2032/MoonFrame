// The row-window verbs: `head` / `tail` / `slice` / `gather` — the transforms
// that keep a frame's schema verbatim and move or trim *rows*. Split from
// `dataframe.mbt` (which keeps the type, its constructors, and the accessors)
// so the type core and the row family read apart — the one-family-per-file
// shape every other verb file follows (`reverse.mbt` for row order,
// `unique.mbt` for row identity, `sort.mbt` for row arrangement). The row cap
// they share is `@order.clamp_take`, the same saturating limit behind the
// visible window in `table_render.mbt`.

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
/// Half-open `[start, end)` row slice. Bounds checks mirror
/// `Series::slice` (and `BuiltinColumn::slice`): an index outside the frame
/// surfaces as `IndexOutOfBounds` — `start < 0`, or an `end` outside
/// `[0, nrows]` — and only two individually valid indices in the wrong order
/// are `InvalidOperation`.
pub fn DataFrame::slice(
  self : DataFrame,
  start : Int,
  end : Int,
) -> DataFrame raise @types.DataError {
  // Validate against `nrows` — the frame's own height, which every column
  // agrees with (INV2) and which a column-less frame still carries. Same order
  // and the same range test on both ends as `validate_slice_bounds`, the
  // per-column validator this stands in for.
  if start < 0 {
    raise @types.DataError::IndexOutOfBounds(start)
  }
  if end < 0 || end > self.nrows {
    raise @types.DataError::IndexOutOfBounds(end)
  }
  if start > end {
    raise @types.DataError::InvalidOperation(
      "slice start > end: \{start} > \{end}",
    )
  }
  // Bounds were already validated against `self.nrows`, which equals every
  // column's length, so the contiguous slice is in-bounds.
  let new_cols : Array[Series] = self.columns.map(c => {
    slice_series(c, start, end - start)
  })
  self.with_same_schema(new_cols, end - start)
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

///|
/// Whether `indices` is the identity permutation `[0, 1, ..., nrows - 1]` —
/// the case where a gather reproduces the frame unchanged. Lets `gather`
/// short-circuit a no-op copy (an already-ordered `sort`, a `filter`
/// that keeps every row). Fails fast: a length mismatch or the first
/// out-of-place index returns `false` before the rest is scanned. The
/// expression evaluator reuses it to detect a whole-frame scope.
fn is_identity_perm(indices : Array[Int], nrows : Int) -> Bool {
  if indices.length() != nrows {
    return false
  }
  for i in 0..<indices.length() {
    if indices[i] != i {
      return false
    }
  }
  true
}
