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

///|
/// Reduce each group to a row, producing a `DataFrame` whose columns are
/// the key columns (in `keys` order, keeping their source dtype) followed
/// by one column per `AggSpec` (in `specs` order). The output has one row
/// per group, in the group order fixed by `group_by`.
///
/// Each spec's reduction reuses the matching `Series` statistic, so the
/// null / `NaN` / dtype rules are inherited verbatim:
///   * `Count` → `Int`, non-null cells only (like `Series::count`);
///   * `Sum` → source numeric dtype (`Int`/`Float`), additive identity
///     for an empty / all-null group; a `NaN` cell propagates to a `NaN`
///     total (`NaN` is a value, not missing);
///   * `Mean` → nullable `Float`, a null cell for an all-null group; a
///     `NaN` cell propagates to a `NaN` mean;
///   * `Min` / `Max` → source dtype, a null cell for an empty / all-null
///     group, `NaN` skipped (every dtype is ordered, so they apply to all
///     four).
///
/// An empty `specs` list degenerates to a **distinct** over the key
/// columns: the output is just the unique key tuples (zero specs ⇒ zero
/// agg columns). The result routes through `DataFrame::new`, so every
/// output satisfies `check_invariants()`.
///
/// `agg` and `GroupedDataFrame::agg_exprs` are deliberately separate twins,
/// not a duplication to fold together. Both reduce a bare single-column
/// aggregation through the same single-pass kernel — `reducer_for` hoists one
/// validity mask over one linear pass with no per-group temporaries — so
/// `AggSpec::sum("r")` and `col("r").sum()` agree cell for cell *and* backend
/// (both converge an all-valid numeric result onto the `Numeric` fast path,
/// the expression-engine convention; see `agg_expr.mbt`), while `agg_exprs`
/// additionally states the derived / compound reductions no `AggSpec` can
/// (`(col("a") - col("b")).sum()`).
///
/// Raises:
/// - `TypeMismatch(...)` — a `Sum` / `Mean` spec targets a non-numeric
///   (`Bool` / `String`) column.
/// - `ColumnNotFound(name)` — a spec names a column absent from the source
///   frame.
/// - `DuplicateColumn(name)` — two output columns collide (e.g. two specs
///   with the same default name, or an alias that shadows a key column).
pub fn GroupedDataFrame::agg(
  self : GroupedDataFrame,
  specs : Array[AggSpec],
) -> DataFrame raise @types.DataError {
  let out_cols : Array[Series] = []
  // Key columns: gather one representative cell per group. Every row in a
  // group shares the key tuple, so the first row (`g[0]`, in-bounds since
  // `group_by` never stores an empty group) is representative; `take` /
  // `gather_series` keep the source dtype.
  let reps = self.groups.map(g => g[0])
  for key in self.keys {
    // `key` came from `group_by`, which already validated it, so the
    // `ColumnNotFound` raise is forwarded but never taken.
    out_cols.push(gather_series(self.source.get_column(key), reps))
  }
  // One aggregated column per spec, in spec order.
  for spec in specs {
    let col = self.source.get_column(spec.column)
    out_cols.push(agg_groups(col, self.groups, spec.kind, spec.output_name()))
  }
  DataFrame::new(out_cols)
}

///|
/// Reduce one source column over every group to a result column, keeping the
/// per-`AggKind` output dtype and backend. The single group-wise reducer
/// behind `GroupedDataFrame::agg`, replacing the previous per-kind
/// `count_groups` / `sum_groups` / `mean_groups` / `extrema_groups`: it
/// resolves the reducer plus output-dtype probe once through the shared
/// `reducer_for` (so `Sum` / `Mean` reject a non-numeric column up front with
/// one `TypeMismatch`, before any group is folded — even for zero groups),
/// then folds each group's row indices through that reducer. The reducer
/// hoists its validity mask once, so the whole aggregation is a single linear
/// pass over the column rather than `O(groups × n)`.
///
/// Null / `NaN` / dtype rules come from the shared kernel, so they match
/// `Series::sum` / `mean` / `min_value` / `max_value` and `eval_agg` cell for
/// cell: `Count` counts non-null cells; `Sum` keeps the source numeric dtype
/// with `NaN` propagated and the additive identity for an empty / all-null
/// group; `Mean` is a nullable `Float` (null cell for an all-null group, `NaN`
/// propagated); `Min` / `Max` keep the source dtype (null cell for an empty /
/// all-null group, `NaN` skipped). Every reduction converges an all-valid
/// numeric result onto the `Numeric` fast path, exactly as `agg_exprs` and
/// `eval_agg` do; a `Mean` / `Min` / `Max` that yields a null cell (an empty /
/// all-null group) or a `Bool` / `String` extremum stays on `Builtin`. So the
/// two paths agree on backend as well as on every cell value (see
/// `agg_expr.mbt`).
fn agg_groups(
  col : Series,
  groups : Array[Array[Int]],
  kind : AggKind,
  out_name : String,
) -> Series raise @types.DataError {
  let op = match kind {
    Count => ReduceOp::Count
    Sum => ReduceOp::Sum
    Mean => ReduceOp::Mean
    Min => ReduceOp::Min
    Max => ReduceOp::Max
  }
  // `Sum` / `Mean` over a non-numeric column raise here, before any group work.
  let (reducer, probe) = reducer_for(col.storage(), op)
  let cells = groups.map(g => reducer(g.length(), k => g[k]))
  scalars_to_series(probe, out_name, cells)
}
