// The row-window verbs: `head` / `tail` / `slice` / `gather` — the
// transforms that keep a series' name and dtype verbatim and move or trim
// *cells*, the `Series` twin of the frame row-window family. The saturating
// cap `head` / `tail` share is `clamp_take`, the same limit behind
// `DataFrame::head` / `tail`; `gather` re-converges an all-valid numeric
// result onto the unboxed fast path.

///|
/// A length-first cell window — the `Series` twin of `DataFrame::slice`,
/// Polars' `Series.slice(offset, length)`. A negative `offset` counts from
/// the end, saturating at the first cell; an omitted `length` runs to the
/// end; a given one saturates at what remains, a negative one is empty.
/// Total — never fails.
pub fn Series::slice(self : Series, offset : Int, length? : Int) -> Series {
  let start = @order.slice_start(offset, self.len())
  slice_series(self, start, @order.slice_len(start, self.len(), length))
}

///|
/// Gather: produce a new series whose i-th entry is `self[indices[i]]`.
/// Out-of-bounds indices surface as `IndexOutOfBounds(idx)`. The result is
/// canonicalised onto the `Numeric` fast path when the gathered rows leave an
/// Int / Float column all-valid (the same invariant `gather_series` keeps), so
/// the backend is a function of the gathered content, not the source.
pub fn Series::gather(
  self : Series,
  indices : Array[Int],
) -> Series raise @types.DataError {
  try_column_to_numeric({
    name: self.name,
    storage: self.storage.take(indices),
  })
}

///|
/// The first `n` cells, or every cell when `n` exceeds the length — the
/// `Series` twin of `DataFrame::head`. A negative `n` keeps every cell but
/// the last `|n|`, as Polars' `head` does. Total.
pub fn Series::head(self : Series, n : Int) -> Series {
  slice_series(self, 0, @order.window_take(n, self.len()))
}

///|
/// The last `n` cells, or every cell when `n` exceeds the length — the
/// `Series` twin of `DataFrame::tail`. A negative `n` keeps every cell but
/// the first `|n|`, as Polars' `tail` does. Total.
pub fn Series::tail(self : Series, n : Int) -> Series {
  let len = self.len()
  let take = @order.window_take(n, len)
  // `slice_series`' third argument is the window *length*, not the end index —
  // pass `take` (as `DataFrame::tail` does), so `start + take == len` stays in
  // bounds. Passing `len` here relied on the slice clamping an over-large end
  // back down, and `start + len` overflows `Int` for a column past ~2^30 rows,
  // wrapping negative and yielding an empty result.
  slice_series(self, len - take, take)
}
