// The ranking selections — Polars' `top_k` / `bottom_k`: the `k` rows at one
// end of a `by` ordering, taken through the sort kernel rather than a
// partial-selection algorithm. Each is literally `sort` under the ranking
// direction with nulls pinned last, then `head(k)` — so the result order is
// deterministic (the sorted order, ties stable in input order) where Polars
// leaves `top_k`'s output order unspecified, and every rule the sort kernel
// documents (expression keys evaluated over the frame, dtype unification,
// `NaN` by the total order) applies verbatim.
//
// Nulls always rank last, at both ends and under `reverse` — Polars' rule
// that non-null elements are always preferred. A `k` past the row count
// saturates (the whole frame in sorted order, `head`'s clamp); `k = 0` is
// the empty frame; a negative `k` or an empty `by` `raise`s
// `InvalidOperation`, the one place the composition would otherwise be
// nonsense (`head(-n)`'s drop-from-the-far-end reading).

///|
/// The shared ranking window: the first `k` rows of `self` sorted by `by`
/// under `descending`, nulls pinned last.
fn DataFrame::rank_window(
  self : DataFrame,
  k : Int,
  by : Array[@expr.Expr],
  descending : Bool,
) -> DataFrame raise @types.DataError {
  if k < 0 {
    raise @types.DataError::InvalidOperation(
      "top_k / bottom_k need a non-negative k",
    )
  }
  if by.is_empty() {
    raise @types.DataError::InvalidOperation(
      "top_k / bottom_k need at least one ranking key",
    )
  }
  // Nulls last on every key, both ends: the ranking prefers non-null rows
  // regardless of direction, so the placement is not caller's choice here.
  self.sort(by.map(e => (e, descending, true))).head(k)
}

///|
/// The `k` rows largest under `by` (Polars' `df.top_k(k, by)`), in sorted
/// order — largest first. `reverse~` flips which end "top" names: the `k`
/// smallest, smallest first. Null-containing rows rank last at either end
/// and only surface when `k` reaches past the non-null rows.
pub fn DataFrame::top_k(
  self : DataFrame,
  k : Int,
  by~ : Array[@expr.Expr],
  reverse? : Bool = false,
) -> DataFrame raise @types.DataError {
  self.rank_window(k, by, !reverse)
}

///|
/// The `k` rows smallest under `by` (Polars' `df.bottom_k(k, by)`), in
/// sorted order — smallest first. `reverse~` flips the end: the `k` largest,
/// largest first. The null and saturation rules mirror `top_k`.
pub fn DataFrame::bottom_k(
  self : DataFrame,
  k : Int,
  by~ : Array[@expr.Expr],
  reverse? : Bool = false,
) -> DataFrame raise @types.DataError {
  self.rank_window(k, by, reverse)
}
