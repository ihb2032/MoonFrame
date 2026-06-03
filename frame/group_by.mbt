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
/// appearance** (pandas `sort=False`), so the result is deterministic and
/// snapshot-stable without a sort.
///
/// Group identity is the composite of each key cell's `Scalar::to_string`
/// (the same canonical value form `unique_count` keys on), so:
///   * a `Float` `NaN` renders `"NaN"` and all NaNs collapse into one
///     group, matching `unique_count` / pandas;
///   * a **null** key cell forms its **own** group rather than being
///     dropped — this is the deliberate semantic difference from `join`,
///     where a null key matches nothing (`null != null`).
///
/// `keys` may name one column (`group_by(["region"])`) or several
/// (`group_by(["region", "product"])`). An empty `keys` list places every
/// row in a single group (a grand-total partition); a 0-row frame yields
/// zero groups regardless of `keys`.
///
/// Raises:
/// - `ColumnNotFound(name)` — `name` is not a column of `self`. Reported
///   on the first offending key, in `keys` order.
pub fn DataFrame::group_by(
  self : DataFrame,
  keys : Array[String],
) -> GroupedDataFrame raise @types.DataError {
  // Resolve + materialise each key column's cells once. `get_column`
  // raises `ColumnNotFound` on the first unknown name (in `keys` order);
  // `to_scalars` is total, so per-row key assembly below reads by plain
  // index with no bounds-checked `get`.
  let key_scalars = keys.map(k => self.get_column(k).to_scalars())
  // `index_of` maps a composite key to its group's slot in `groups`;
  // `groups` grows in first-appearance order. A row whose key is already
  // present appends to that group, otherwise it opens a new one.
  let index_of : Map[String, Int] = {}
  let groups : Array[Array[Int]] = []
  for i in 0..<self.nrows() {
    let id = row_group_key(key_scalars, i)
    match index_of.get(id) {
      Some(g) => groups[g].push(i)
      None => {
        index_of[id] = groups.length()
        groups.push([i])
      }
    }
  }
  { source: self, keys, groups }
}

///|
/// Build row `i`'s composite group key from the pre-materialised key
/// columns. Each key cell contributes a self-delimiting token so the
/// encoding is injective — distinct key tuples never collide:
///   * a null cell → `"N;"` (a tag that no value token can produce), so a
///     null is distinct from an empty string and forms its own group;
///   * a value cell → `"V" + len + ":" + Scalar::to_string`, length-
///     prefixed so a `String` cell containing the delimiter can't be
///     confused with a field boundary.
fn row_group_key(key_scalars : Array[Array[@types.Scalar]], i : Int) -> String {
  let buf = StringBuilder::new()
  for col in key_scalars {
    // `col` has `nrows` cells and `i` ranges over `[0, nrows)`, so the
    // read is in-bounds.
    let sc = col[i]
    if sc.is_null() {
      buf.write_string("N;")
    } else {
      let s = sc.to_string()
      buf.write_string("V")
      buf.write_string(s.length().to_string())
      buf.write_string(":")
      buf.write_string(s)
    }
  }
  buf.to_string()
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
///     for an empty / all-null group;
///   * `Mean` → nullable `Float`, a null cell for an all-null / all-`NaN`
///     group;
///   * `Min` / `Max` → source dtype, a null cell for an empty / all-null
///     group (every dtype is ordered, so they apply to all four).
///
/// An empty `specs` list degenerates to a **distinct** over the key
/// columns: the output is just the unique key tuples (zero specs ⇒ zero
/// agg columns). The result routes through `DataFrame::new`, so every
/// output satisfies `check_invariants()`.
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
    Min => extrema_groups(col, groups, out_name, s => s.min_value())
    Max => extrema_groups(col, groups, out_name, s => s.max_value())
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
  let valid = col.storage().validity().to_bools()
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
/// `Int64`, `Float` in `Double` with `NaN` skipped (treated as missing,
/// matching `Series::sum` / `sort_by`); a non-numeric column raises
/// `TypeMismatch`. Reads the raw buffer + validity directly so no `Scalar`
/// boxing or unreachable match arm is introduced.
fn sum_groups(
  col : Series,
  groups : Array[Array[Int]],
  out_name : String,
) -> Series raise @types.DataError {
  let valid = col.storage().validity().to_bools()
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
            // NaN is skipped, matching Series::sum.
            if valid[idx] && !data[idx].is_nan() {
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
/// all-null / all-`NaN` group is caught and surfaced as a null cell, so a
/// single empty group never fails the whole aggregation.
fn mean_groups(
  col : Series,
  groups : Array[Array[Int]],
  out_name : String,
) -> Series raise @types.DataError {
  if !col.dtype().is_numeric() {
    raise @types.DataError::TypeMismatch(
      "mean undefined for " +
      col.dtype().to_string() +
      " column \"" +
      col.name() +
      "\"",
    )
  }
  // TypeMismatch cannot fire below (numeric guaranteed above); the only
  // catchable failure is the all-null / all-NaN `InvalidOperation`, which
  // becomes a null cell.
  Series::from_float_options(
    out_name,
    groups.map(g => {
      try gather_series(col, g).mean() catch {
        _ => None
      } noraise {
        v => Some(v)
      }
    }),
  )
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
  reduce : (Series) -> @types.Scalar,
) -> Series {
  let scalars = groups.map(g => reduce(gather_series(col, g)))
  match col.storage().data() {
    @column.ColumnData::Int(_) =>
      Series::from_int_options(
        out_name,
        scalars.map(sc => {
          match sc {
            @types.Scalar::Int(v) => Some(v)
            _ => None
          }
        }),
      )
    @column.ColumnData::Float(_) =>
      Series::from_float_options(
        out_name,
        scalars.map(sc => {
          match sc {
            @types.Scalar::Float(v) => Some(v)
            _ => None
          }
        }),
      )
    @column.ColumnData::Bool(_) =>
      Series::from_bool_options(
        out_name,
        scalars.map(sc => {
          match sc {
            @types.Scalar::Bool(v) => Some(v)
            _ => None
          }
        }),
      )
    @column.ColumnData::String(_) =>
      Series::from_string_options(
        out_name,
        scalars.map(sc => {
          match sc {
            @types.Scalar::String(v) => Some(v)
            _ => None
          }
        }),
      )
  }
}
