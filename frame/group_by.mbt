///|
/// A `DataFrame` partitioned into groups by one or more key expressions,
/// produced by `DataFrame::group_by` and consumed by `agg`. Fields are
/// private outside the package; the only way to build one is `group_by`,
/// which guarantees every stored row index is in `[0, source.nrows())`
/// and every group is non-empty.
///
///   * `source` — the frame being grouped (its columns back every
///     aggregation).
///   * `key_columns` — the materialised key columns, one per key
///     expression in the order passed to `group_by`, each already named by
///     the expression's output name (alias, else leftmost column reference,
///     else `"literal"`) and carrying its evaluated dtype and backend. They
///     head the `agg` output in this order; `agg` gathers one representative
///     cell per group from them.
///   * `groups` — one entry per distinct key tuple, in first-appearance
///     order, each holding that group's row indices in ascending row
///     order.
pub struct GroupedDataFrame {
  source : DataFrame
  key_columns : Array[Series]
  groups : Array[Array[Int]]
} derive(Eq, Debug)

///|
/// Partition `self` into groups by the `keys` expressions — MoonFrame's
/// single `group_by` verb (Polars' `df.group_by(...)`). Rows sharing the
/// same key tuple land in the same group; group order is **first
/// appearance** (equivalent to Polars' `maintain_order=True`), so the
/// result is deterministic and snapshot-stable without a sort.
///
/// Each key is an arbitrary expression, evaluated over the whole frame
/// under the rules in `expr_eval.mbt`, exactly like a `sort` key: a bare
/// `col("region")` groups by an existing column, a derived key such as
/// `(col("a") + col("b"))` groups by the computed value, and a key that
/// reduces to a single cell (a literal, or an aggregation like
/// `col("x").sum()`) broadcasts over the frame — every row shares it, so it
/// collapses the frame into one group. The materialised key columns head
/// the `agg` output, each named by its expression's output name (alias,
/// else leftmost column reference, else `"literal"`) and keeping its
/// evaluated dtype.
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
/// `keys` may hold one expression (`group_by([col("region")])`) or several
/// (`group_by([col("region"), col("product")])`). An empty `keys` list
/// places every row in a single group (a grand-total partition); a 0-row
/// frame yields zero groups regardless of `keys`.
///
/// Raises:
/// - `ColumnNotFound(name)` — a key expression references an absent column.
///   Reported on the first offending key, in `keys` order.
/// - `TypeMismatch(...)` — a key expression's dtypes don't unify. Reported
///   on the first offending key, in `keys` order.
/// - `DuplicateColumn(name)` — two keys produce the same output name (which
///   would otherwise have `agg` emit two identically-named key columns and
///   fail late with a confusing collision). Reported at the second such
///   key, in `keys` order — mirroring `select`'s per-expression seen-check,
///   and after that key's own evaluation, so an evaluation error there wins
///   over the collision.
pub fn DataFrame::group_by(
  self : DataFrame,
  keys : Array[@expr.Expr],
) -> GroupedDataFrame raise @types.DataError {
  // Materialise each key expression into a key column, mirroring `select`:
  // evaluate over the whole frame, broadcast a length-1 (literal /
  // aggregation) key up to frame height, name by the expression's output
  // name, and reject a name produced twice up front — before `agg` could
  // build two same-named key columns. Evaluation raises `ColumnNotFound` /
  // `TypeMismatch` on the first offending key (in `keys` order); the
  // seen-check raises `DuplicateColumn` at the repeat, after that key's own
  // evaluation (so an evaluation error there surfaces first, like `select`).
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  let seen : Map[String, Unit] = {}
  let key_columns = keys.map(key => {
    let column = broadcast_series(eval_expr(key, self, scope), n)
    let name = expr_output_name(key)
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    column.rename(name)
  })
  // `by_key` maps a composite key to that key's row indices, growing each
  // group in place (`Array` is a mutable reference, so the cell fetched by
  // `get` is the stored one). `to_scalars` is total, so per-row key assembly
  // reads by plain index with no bounds-checked `get`. MoonBit's `Map`
  // iterates in first-insertion order, so `.values()` reproduces
  // first-appearance group order (pandas `sort=False`) with no separate
  // slot-tracking array; within a group the indices stay ascending because
  // `i` only grows.
  let key_scalars = key_columns.map(column => column.to_scalars())
  let by_key : Map[Array[KeyCell], Array[Int]] = {}
  for i in 0..<n {
    let id = row_group_key(key_scalars, i)
    match by_key.get(id) {
      Some(g) => g.push(i)
      None => by_key[id] = [i]
    }
  }
  { source: self, key_columns, groups: by_key.values().collect() }
}
