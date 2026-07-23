///|
/// Which row of a set of duplicates `DataFrame::unique` keeps — Polars'
/// `keep` parameter. Two rows are duplicates under the same composite
/// `KeyCell` encoding `group_by` / `join` use (a `Float` `NaN` equals `NaN`,
/// `-0.0` folds into `+0.0`, and a **null** cell is an ordinary value).
///
/// - `First` keeps the earliest occurrence of each distinct row;
/// - `Last` keeps the latest;
/// - `None` keeps only rows that have **no** duplicate at all — every row of a
///   duplicated set is dropped (Polars' `keep='none'`).
///
/// The kept rows always come out in ascending original-row order, so the result
/// is deterministic without a sort regardless of strategy.
pub(all) enum KeepStrategy {
  First
  Last
  None
} derive(Eq, Debug)

///|
pub extend KeepStrategy with Eq::{equal, not_equal}

///|
pub extend KeepStrategy with Debug::{to_repr}

///|
/// Drop duplicate rows — Polars' `df.unique(maintain_order=True)`. Two rows are
/// duplicates when every cell is equal under the same composite `KeyCell`
/// encoding `group_by` and `join` use (see `frame/row_key.mbt`): a `Float`
/// `NaN` equals `NaN`, `-0.0` folds into `+0.0`, and — like a `group_by` key — a
/// **null** cell is an ordinary value, so two rows that are null in the same
/// places (and equal elsewhere) are duplicates.
///
/// `keep` selects which occurrence survives (default `First`): `First` / `Last`
/// keep one representative per distinct row, `None` keeps only rows with no
/// duplicate at all. Result rows keep their **first-appearance** order (`First`),
/// their last-occurrence order (`Last`), or their original order among the
/// survivors (`None`) — always ascending by original row index, so the output
/// is deterministic without a sort. When duplicate rows are dropped, a column
/// that becomes all-valid may converge onto the `Numeric` fast-path backend —
/// exactly as `gather` does, since the backend is a function of the
/// gathered content, not the source; the schema, values, and frame invariants
/// are unchanged.
///
/// `subset` picks the columns whose values form the duplicate key (Polars'
/// `subset`); omitted, every column takes part. The output always carries **all**
/// columns either way — a subset narrows what counts as a duplicate, not what
/// is returned. Like `drop` / `drop_nulls`, each `subset` entry is consulted by
/// its **output name** only and never evaluated: pass bare `col(name)`
/// references — a computed key such as `col(a) + col(b)` resolves to its
/// leftmost column name, not the computed value. An explicitly empty `subset`
/// gives every row the same (empty)
/// key, so `First` / `Last` keep one row and `None` keeps none unless the frame
/// has a single row.
///
/// Raises `ColumnNotFound(name)` on the first `subset` name absent from the
/// frame, reported before any per-row work. With no `subset` the resolution
/// cannot fail — the names come straight from the frame — so the all-columns
/// form still never fails on a valid frame. A frame whose kept set is all of
/// `[0, n)` — every row distinct, so no strategy drops anything — is returned
/// unchanged (the gather would be a no-op), as is a 0-row frame.
pub fn DataFrame::unique(
  self : DataFrame,
  subset? : Array[@expr.Expr],
  keep? : KeepStrategy = KeepStrategy::First,
) -> DataFrame raise @types.DataError {
  let n = self.nrows()
  // Column-major cells, so a row's composite key is assembled by plain index
  // reads (`to_scalars` is total — no per-cell bounds-checked `get`). Build each
  // row's key once up front; the strategies below index this rather than
  // recompute it.
  let cells = match subset {
    None => self.to_scalar_matrix()
    // Resolve the key columns first, in `subset` order, so an unknown name
    // surfaces as `ColumnNotFound` before any per-row work runs — the shared
    // name-only resolution `drop` / `drop_nulls` also use.
    Some(keys) => self.resolve_subset_columns(keys).map(s => s.to_scalars())
  }
  let keys = Array::makei(n, i => row_group_key(cells, i))
  let kept : Array[Int] = []
  match keep {
    // First-appearance dedup: keep the first row index of each distinct
    // composite key. Pushing `i` only on first sight keeps the surviving
    // indices ascending and in first-appearance order (the same
    // first-insertion discipline `group_by` relies on).
    KeepStrategy::First => {
      let seen : Map[Array[KeyCell], Unit] = Map([])
      for i in 0..<n {
        if !seen.contains(keys[i]) {
          seen[keys[i]] = ()
          kept.push(i)
        }
      }
    }
    // Keep the last occurrence: record the latest index per key, then walk in
    // order and keep `i` where it *is* that latest index — so survivors stay
    // ascending by original position.
    KeepStrategy::Last => {
      let last : Map[Array[KeyCell], Int] = Map([])
      for i in 0..<n {
        last[keys[i]] = i
      }
      for i in 0..<n {
        if last.get(keys[i]) == Some(i) {
          kept.push(i)
        }
      }
    }
    // Keep only rows whose key occurs exactly once: count occurrences, then keep
    // the rows in a singleton bucket.
    KeepStrategy::None => {
      let count : Map[Array[KeyCell], Int] = Map([])
      for i in 0..<n {
        count[keys[i]] = count.get(keys[i]).unwrap_or(0) + 1
      }
      for i in 0..<n {
        if count.get(keys[i]) == Some(1) {
          kept.push(i)
        }
      }
    }
  }
  // Nothing dropped (every row distinct, or a 0-row frame): return `self`
  // rather than rebuild it, mirroring `gather`'s no-op copy.
  if kept.length() == n {
    return self
  }
  // `kept` is a strict subset of `[0, n)` by construction, so the per-column
  // gather is in-bounds with no bounds check (unlike the public `gather`), and
  // the frame is rebuilt directly — keeping `unique` total.
  let new_cols = self.columns.map(c => gather_series(c, kept))
  self.with_same_schema(new_cols, kept.length())
}
