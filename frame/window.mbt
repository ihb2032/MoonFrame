// The row-selection and row-order verbs: `filter` keeps the rows a
// predicate selects, `head` / `tail` / `slice` / `gather` move or trim rows
// by position, and `reverse` / `with_row_index` reorder and number them —
// the transforms that keep a frame's schema verbatim and act on *rows*
// only (`sort` for row arrangement and `unique` for row identity stay in
// their own files). The row counts they share come from `@order`:
// `window_take` for the Polars head/tail convention, `slice_start` /

///|
/// Keep only the rows where `predicate` evaluates to `true` — MoonFrame's
/// single row-selection verb. The predicate is an `Expr`, not a closure, and
/// that is what the built-in expression algebra buys: it evaluates vectorized
/// (one column pass per node, not one call per row), it can be printed, and a
/// lazy `Filter` node can introspect it for predicate pushdown. A row-wise host
/// predicate is still reachable through the `map_many` escape hatch —
/// `filter(map_many(label~, inputs, f))` reifies the original closure predicate
/// as a `Bool`-returning `Expr` — but a closure buys none of the three: the map
/// node renders as its label with the closure opaque, the optimizer can only
/// treat it as a barrier and sinks no filter across it, and `f` is called once
/// per row (once per batch for `map_batches`).
///
/// The predicate must evaluate to a `Bool` column (`TypeMismatch`
/// otherwise). A row is kept where its cell is `true`; `false` **and
/// null** cells drop the row (the Polars rule — an unknown is not a
/// keep). The mask rides the shared length contract: a length-1
/// result — a literal, or an aggregation comparison like
/// `col("qty").sum().gt(lit_int(0))` — broadcasts over the frame, keeping every
/// row or none, while a mask that is neither frame-tall nor length-1 raises
/// `LengthMismatch` instead of selecting rows by position.
///
/// The returned frame has the same schema as `self` (a
/// rejects-everything predicate leaves a 0-row frame with the original
/// schema). A filter that keeps every row returns `self` unchanged; once
/// any row drops, the surviving cells are re-gathered and each column
/// converges onto the backend its content implies (an all-valid numeric
/// column lands on `Numeric`) — the engine-wide "backend is a function of
/// content" rule, not a verbatim carry-over. Evaluation errors (unknown
/// columns, dtype mismatches, an off-frame mask length) surface here; building
/// the predicate was total.
pub fn DataFrame::filter(
  self : DataFrame,
  predicate : @expr.Expr,
) -> DataFrame raise @types.DataError {
  // Every kept index came from `[0, nrows)`, so `gather` cannot fail.
  self.gather(self.filter_row_indices(predicate))
}

///|
/// The row indices `filter` would keep, ascending. Split out for the lazy file
/// sources: a scan that absorbed a predicate builds only its key columns,
/// asks for the surviving rows here, and then materialises the remaining
/// columns for those rows alone — so the dropped rows are never parsed.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::filter_row_indices(
  self : DataFrame,
  predicate : @expr.Expr,
) -> Array[Int] raise @types.DataError {
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  // Stretch a length-1 mask (literal / aggregation) over the frame, down to
  // zero rows on an empty one, and reject an off-frame one — the shared length
  // contract.
  let mask = @kernel.broadcast_series(eval_expr(predicate, self, scope), n)
  // The rows the mask keeps, read on the column's own side of the seam — a
  // null cell is not a keep, alongside `false`. `None` means the predicate
  // evaluated to another dtype, and what *that* means is this verb's call, so
  // the message is raised here rather than at the column seam.
  match mask.mask_true_indices() {
    Some(kept) => kept
    None =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got \{mask.dtype()}",
        ),
      )
  }
}

// `slice_len` for the saturating window.

///|
/// First `n` rows (or all rows if `n >= nrows`) — Polars' `head`. A negative
/// `n` keeps every row but the last `|n|` (`head(-2)` drops the final two
/// rows), saturating to the whole frame when `|n|` reaches past it. Total —
/// never fails. Also exposed under its Polars / SQL name
/// `limit` (via `#alias`) — the eager twin of `LazyFrame::limit`, keeping
/// the two surfaces verb-for-verb aligned.
#alias(limit)
pub fn DataFrame::head(self : DataFrame, n : Int) -> DataFrame {
  let m = @order.window_take(n, self.nrows)
  // `0 <= m <= nrows == c.len()`, so the contiguous row slice is in-bounds
  // and needs no bounds-checking `Result`.
  let new_cols : Array[Series] = self.columns.map(c => c.slice_series(0, m))
  // Names and schema are unchanged — reuse the cache verbatim.
  self.with_same_schema(new_cols, m)
}

///|
/// Last `n` rows (or all rows if `n >= nrows`) — Polars' `tail`. A negative
/// `n` keeps every row but the first `|n|` (`tail(-2)` drops the leading two
/// rows), saturating to the whole frame when `|n|` reaches past it. Total —
/// never fails.
pub fn DataFrame::tail(self : DataFrame, n : Int) -> DataFrame {
  let m = @order.window_take(n, self.nrows)
  let start = self.nrows - m
  // Same in-bounds argument as `head`: `start + m == nrows == c.len()`.
  let new_cols : Array[Series] = self.columns.map(c => c.slice_series(start, m))
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
    c.slice_series(start, len)
  })
  self.with_same_schema(new_cols, len)
}

///|
/// The bracket-slice sugar — Polars' `df[1:3]` / `df[2:]` / `df[:-1]`: a
/// half-open `[start, end)` row window where an omitted bound runs to that
/// end and a negative one counts from it, saturating like every window verb,
/// with crossed bounds an empty frame. Sugar in Polars' own sense: the
/// bounds normalize (`between_bounds`) into the one `(offset, length)`
/// window kernel `slice` runs, so the two spellings cannot disagree. Total —
/// never fails. Reached as `df[a:b]`.
#alias("_[_:_]")
pub fn DataFrame::slice_between(
  self : DataFrame,
  start? : Int,
  end? : Int,
) -> DataFrame {
  let (s, l) = @order.between_bounds(start, end, self.nrows)
  self.slice(s, length=l)
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
  let new_cols = self.columns.map(c => c.gather_series(indices))
  self.with_same_schema(new_cols, indices.length())
}

// frame already carries, and a counter that would run past `Int64::MAX`.

///|
/// Reverse the row order, keeping every column and its dtype — Polars'
/// `df.reverse()`. The schema is untouched, so a reversed frame is a frame
/// with the same columns in the same order, read bottom-up.
///
/// Total: the permutation is `[n-1, …, 0]`, in bounds by construction. A
/// 0-row or 1-row frame is returned unchanged rather than gathered into an
/// identical copy.
pub fn DataFrame::reverse(self : DataFrame) -> DataFrame {
  let n = self.nrows()
  if n <= 1 {
    return self
  }
  // Every index comes from `[0, n)`, so the gather cannot fail.
  let perm = Array::makei(n, i => n - 1 - i)
  let columns = self.column_series().map(c => c.gather_series(perm))
  self.with_same_schema(columns, n)
}

///|
/// Prepend a row-number column — Polars' `df.with_row_index(name, offset)`.
/// The counter is an `Int` column named `name` (default `"index"`) holding
/// `offset`, `offset + 1`, … in row order, and it lands **first**, ahead of
/// the frame's own columns, as in Polars.
///
/// Raises `DuplicateColumn(name)` when the frame already has a column of that
/// name — the frame's own invariant, surfaced by the `Schema` the rebuild
/// derives (`DataFrame::from_parts_with_fields`). The
/// counter is dense and always non-null, so it never changes any other
/// column's dtype or nullability.
///
/// Raises `InvalidOperation` when the last number would not fit: the counter
/// runs `offset ..= offset + nrows - 1`, and past `Int64::MAX` MoonBit's
/// wrapping addition would carry it round to `Int64::MIN`, leaving a column
/// that is neither increasing nor dense. Polars refuses the same overflow
/// against its own index type.
pub fn DataFrame::with_row_index(
  self : DataFrame,
  name? : String = "index",
  offset? : Int64 = 0,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  // Rearranged to `offset > MAX - (n - 1)` so the check itself cannot overflow:
  // `n - 1` is at most `Int::MAX`, far inside the subtraction's range. Only the
  // top end can run out — every counter step is upward, so a negative `offset`
  // moves away from `Int64::MIN`, never toward it.
  if n > 0 && offset > 9223372036854775807L - (n - 1).to_int64() {
    raise @types.DataError::InvalidOperation(
      "row index overflows Int64: offset \{offset} with \{n} rows",
    )
  }
  let index = @series.Series::from_ints(
    name,
    Array::makei(n, i => offset + i.to_int64()),
  )
  let columns = [index]
  for column in self.column_series() {
    columns.push(column)
  }
  // Prepending a column leaves every existing one exactly where it was, so
  // each keeps the field it arrived with rather than a re-derived one.
  let fields = [@types.Field::Field(name, @types.DataType::Int)]
  for field in self.schema.fields() {
    fields.push(field)
  }
  DataFrame::from_parts_with_fields(columns, fields, n)
}
