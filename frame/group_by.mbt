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
/// not a duplication to fold together. `agg` is the fast single-column path
/// — single-pass per-group reducers with no per-group temporaries — while
/// `agg_exprs` evaluates arbitrary reduction-shaped expressions through the
/// general per-group evaluator. Their single-reduction forms agree cell for
/// cell (`AggSpec::sum("r")` ≡ `col("r").sum()`), but they deliberately
/// differ in backend: this path leaves `Mean` / `Min` / `Max` on `Builtin`,
/// where `agg_exprs` converges an all-valid numeric result onto `Numeric`
/// (see `agg_expr.mbt`). Routing `agg` through `agg_exprs` would trade the
/// single-pass reducers for per-group evaluation and flip those backends, so
/// the two are kept distinct.
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
    out_cols.push(
      aggregate_column(col, self.groups, spec.kind, spec.output_name()),
    )
  }
  DataFrame::new(out_cols)
}

///|
/// Dispatch one column's group-wise reduction by `kind`. `Count` / `Min`
/// / `Max` are total; `Sum` / `Mean` raise `TypeMismatch` on a
/// non-numeric column.
fn aggregate_column(
  col : Series,
  groups : Array[Array[Int]],
  kind : AggKind,
  out_name : String,
) -> Series raise @types.DataError {
  match kind {
    Count => count_groups(col, groups, out_name)
    Sum => sum_groups(col, groups, out_name)
    Mean => mean_groups(col, groups, out_name)
    Min => extrema_groups(col, groups, out_name, want_min=true)
    Max => extrema_groups(col, groups, out_name, want_min=false)
  }
}

///|
/// Per-group count of non-null cells — an `Int` column. Dtype-independent
/// (it reads only the validity mask), so there is no per-dtype dispatch.
fn count_groups(
  col : Series,
  groups : Array[Array[Int]],
  out_name : String,
) -> Series {
  let valid = validity_bools(col.storage())
  Series::from_ints(
    out_name,
    groups.map(g => {
      let mut c : Int64 = 0
      for idx in g {
        if valid[idx] {
          c = c + 1
        }
      }
      c
    }),
  )
}

///|
/// Per-group sum, keeping the source numeric dtype. `Int` accumulates in
/// `Int64`, `Float` in `Double` with `NaN` propagated as a value rather
/// than skipped (matching `Series::sum` — Polars treats `NaN` as a value,
/// only `Null` as missing); a non-numeric column raises `TypeMismatch`.
/// Reads the raw buffer + validity directly so no `Scalar` boxing or
/// unreachable match arm is introduced.
fn sum_groups(
  col : Series,
  groups : Array[Array[Int]],
  out_name : String,
) -> Series raise @types.DataError {
  let valid = validity_bools(col.storage())
  match col.storage().data() {
    @column.ColumnData::Int(data) =>
      Series::from_ints(
        out_name,
        groups.map(g => {
          let mut acc : Int64 = 0
          for idx in g {
            if valid[idx] {
              acc = acc + data[idx]
            }
          }
          acc
        }),
      )
    @column.ColumnData::Float(data) =>
      Series::from_floats(
        out_name,
        groups.map(g => {
          let mut acc = 0.0
          for idx in g {
            // NaN is a value, not missing: it participates and propagates
            // to a NaN group total, matching Series::sum (Polars
            // semantics). Only a null cell is skipped.
            if valid[idx] {
              acc = acc + data[idx]
            }
          }
          acc
        }),
      )
    _ =>
      raise @types.DataError::TypeMismatch(
        "sum undefined for " +
        col.dtype().to_string() +
        " column \"" +
        col.name() +
        "\"",
      )
  }
}

///|
/// Per-group arithmetic mean — a nullable `Float` column. Rejects a
/// non-numeric column up front with one `TypeMismatch` (rather than per
/// group). Within each group, `Series::mean`'s `InvalidOperation` on an
/// all-null group is caught and surfaced as a null cell, so a single
/// all-null group never fails the whole aggregation. A group that holds a
/// `NaN` (alongside any non-null cell) means `NaN` — `NaN` propagates
/// rather than being skipped, matching `Series::mean`.
fn mean_groups(
  col : Series,
  groups : Array[Array[Int]],
  out_name : String,
) -> Series raise @types.DataError {
  // Hoist the validity mask once (O(n)) and fold each group over its own
  // indices, so the reduction is linear in the column length rather than
  // O(groups × n) — the per-group `gather_series(col, g).mean()` it replaced
  // re-materialised the whole-column mask on every group. The semantics are
  // unchanged from `Series::mean`: a null cell is skipped; a `Float` `NaN` is
  // a present value that is summed in and propagates to a `NaN` mean (Polars
  // rule — only `Null` is missing); an all-null / empty group has no present
  // cell and yields a null mean rather than failing the whole aggregation.
  // The non-numeric `_` arm raises one `TypeMismatch` (reached before any
  // group work, like `sum_groups`).
  let valid = validity_bools(col.storage())
  match col.storage().data() {
    @column.ColumnData::Int(data) =>
      Series::from_float_options(
        out_name,
        groups.map(g => {
          let mut acc : Int64 = 0
          let mut cnt = 0
          for idx in g {
            if valid[idx] {
              acc = acc + data[idx]
              cnt = cnt + 1
            }
          }
          if cnt == 0 {
            None
          } else {
            Some(acc.to_double() / cnt.to_double())
          }
        }),
      )
    @column.ColumnData::Float(data) =>
      Series::from_float_options(
        out_name,
        groups.map(g => {
          let mut acc = 0.0
          let mut cnt = 0
          for idx in g {
            // NaN is a value, not missing: summed in, propagating to a NaN
            // mean (matching Series::mean). Only a null cell is skipped.
            if valid[idx] {
              acc = acc + data[idx]
              cnt = cnt + 1
            }
          }
          if cnt == 0 {
            None
          } else {
            Some(acc / cnt.to_double())
          }
        }),
      )
    _ =>
      raise @types.DataError::TypeMismatch(
        "mean undefined for " +
        col.dtype().to_string() +
        " column \"" +
        col.name() +
        "\"",
      )
  }
}

///|
/// Per-group extremum (`min`/`max` chosen by `reduce`), keeping the source
/// dtype. `Series::min_value` / `max_value` are total (`Scalar::Null` for
/// an empty / all-null group, `NaN` skipped), and every dtype is ordered,
/// so this never raises. Dispatch on the source dtype picks the matching
/// option constructor and the `Scalar -> typed cell` extraction (`Null ->
/// None`), mirroring `describe`'s `push_extrema`.
fn extrema_groups(
  col : Series,
  groups : Array[Array[Int]],
  out_name : String,
  want_min~ : Bool,
) -> Series {
  // Hoist the validity mask once (O(n)); each group then folds over its own
  // indices, so the reduction is linear in the column length rather than
  // O(groups × n) — the per-group `gather_series` it replaced re-materialised
  // the whole-column mask every time. `min_value` / `max_value` semantics are
  // preserved: a null cell is skipped, a `Float` `NaN` is treated as missing
  // (so an all-NaN / all-null group yields a null cell), and every dtype is
  // ordered (`Bool` `false < true`, `String` lexicographic), so this is total.
  let valid = validity_bools(col.storage())
  match col.storage().data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(
        out_name,
        groups.map(g => {
          group_extremum(g, idx => valid[idx], idx => a[idx], (x, y) => {
            if want_min {
              x < y
            } else {
              x > y
            }
          })
        }),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        out_name,
        groups.map(g => {
          group_extremum(
            g,
            // NaN is treated as missing (skipped), matching Series::min_value /
            // max_value and sort_by.
            idx => valid[idx] && !a[idx].is_nan(),
            idx => a[idx],
            (x, y) => if want_min { x < y } else { x > y },
          )
        }),
      )
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(
        out_name,
        groups.map(g => {
          group_extremum(
            g,
            idx => valid[idx],
            idx => a[idx],
            // false < true: under min `false` beats `true`; under max the reverse.
            (x, y) => if want_min { !x && y } else { x && !y },
          )
        }),
      )
    @column.ColumnData::String(a) =>
      Series::from_string_options(
        out_name,
        groups.map(g => {
          group_extremum(g, idx => valid[idx], idx => a[idx], (x, y) => {
            if want_min {
              @types.compare_string_lex(x, y) < 0
            } else {
              @types.compare_string_lex(x, y) > 0
            }
          })
        }),
      )
  }
}

///|
/// Fold one group's cells to an extremum option. `present(idx)` gates the
/// non-missing cells, `get(idx)` reads the raw value, and `better(cand, best)`
/// is `true` when `cand` should replace the running best. Returns `None` when
/// every cell in the group is missing. Shared by the four `extrema_groups`
/// dtype arms so each supplies only its presence test, reader, and comparator
/// — the group analog of `series_stats.mbt`'s `fold_extremum`.
fn[T] group_extremum(
  g : Array[Int],
  present : (Int) -> Bool,
  get : (Int) -> T,
  better : (T, T) -> Bool,
) -> T? {
  let mut best : T? = None
  for idx in g {
    if present(idx) {
      // Bind the cell once: the `Some` arm would otherwise evaluate `get(idx)`
      // up to twice per present element.
      let v = get(idx)
      best = match best {
        None => Some(v)
        Some(b) => if better(v, b) { Some(v) } else { Some(b) }
      }
    }
  }
  best
}
