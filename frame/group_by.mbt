///|
/// A `DataFrame` partitioned into groups by one or more key columns,
/// produced by `DataFrame::group_by` and consumed by `agg`. Fields are
/// private outside the package; the only way to build one is `group_by`,
/// which guarantees every stored row index is in `[0, source.nrows())`
/// and every group is non-empty.
///
///   * `source` — the frame being grouped (its columns back every
///     aggregation).
///   * `keys` — the key column names, in the order passed to `group_by`;
///     they head the `agg` output in this order, keeping their dtype.
///   * `groups` — one entry per distinct key tuple, in first-appearance
///     order, each holding that group's row indices in ascending row
///     order.
pub struct GroupedDataFrame {
  source : DataFrame
  keys : Array[String]
  groups : Array[Array[Int]]
} derive(Eq, Debug)

///|
/// Partition `self` into groups by the `keys` columns. Rows sharing the
/// same key tuple land in the same group; group order is **first
/// appearance** (equivalent to Polars' `maintain_order=True`), so the
/// result is deterministic and snapshot-stable without a sort.
///
/// Group identity is the composite `KeyCell` tuple of the row's key cells
/// (see `frame/row_key.mbt`), hashed on the native cell values, so:
///   * a `Float` `NaN` collapses into one group — matching Polars, where
///     `NaN` compares equal for grouping (the same rule `join` keys on);
///     `-0.0` and `+0.0` likewise share a group;
///   * a **null** key cell forms its **own** group rather than being
///     dropped — the Polars default (pandas drops null keys), and the
///     deliberate semantic difference from `join`, where a null key
///     matches nothing (`null != null`).
///
/// `keys` may name one column (`group_by(["region"])`) or several
/// (`group_by(["region", "product"])`). An empty `keys` list places every
/// row in a single group (a grand-total partition); a 0-row frame yields
/// zero groups regardless of `keys`.
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` is not a column of `self`. Reported
///   on the first offending key, in `keys` order.
/// - `DuplicateColumn(name)` — `name` appears twice in `keys` (which would
///   otherwise have `agg` emit two identically-named key columns and fail
///   late with a confusing collision). Reported at the repeat, in `keys`
///   order; like `select`, a key that is *missing* surfaces as
///   `ColumnNotFound` at its first appearance before any later duplicate is
///   examined.
pub fn DataFrame::group_by(
  self : DataFrame,
  keys : Array[String],
) -> GroupedDataFrame raise @types.DataError {
  // Resolve + materialise each key column's cells once. The running `seen`
  // set makes a key repeated in `keys` raise `DuplicateColumn` at the
  // repeat — before `agg` could build two same-named key columns — matching
  // `select`'s contract; `get_column` raises `ColumnNotFound` on the first
  // unknown name (in `keys` order). `to_scalars` is total, so per-row key
  // assembly below reads by plain index with no bounds-checked `get`.
  let seen : Map[String, Unit] = {}
  let key_scalars = keys.map(k => {
    if seen.contains(k) {
      raise @types.DataError::DuplicateColumn(k)
    }
    seen[k] = ()
    self.get_column(k).to_scalars()
  })
  // `by_key` maps a composite key to that key's row indices, growing each
  // group in place (`Array` is a mutable reference, so the cell fetched by
  // `get` is the stored one). MoonBit's `Map` iterates in first-insertion
  // order, so `.values()` reproduces first-appearance group order (pandas
  // `sort=False`) with no separate slot-tracking array; within a group the
  // indices stay ascending because `i` only grows.
  let by_key : Map[Array[KeyCell], Array[Int]] = {}
  for i in 0..<self.nrows() {
    let id = row_group_key(key_scalars, i)
    match by_key.get(id) {
      Some(g) => g.push(i)
      None => by_key[id] = [i]
    }
  }
  { source: self, keys, groups: by_key.values().collect() }
}
