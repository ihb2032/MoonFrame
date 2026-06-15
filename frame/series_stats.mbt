// Statistics on a `Series`. Split from `series.mbt` so the structural
// surface stays narrow; everything here is a pure reduction over the
// underlying column.

///|
/// Count of non-null cells.
pub fn Series::count(self : Series) -> Int {
  self.len() - self.null_count()
}

///|
/// Sum of non-null cells.
///
/// - `Int` series → `Scalar::Int(sum)`, accumulated in 64-bit `Int64`
///   (so only sums past 2^63 overflow, not the old 32-bit ceiling).
/// - `Float` series → `Scalar::Float(sum)`, accumulated in 64-bit
///   `Double`. A `NaN` cell is a valid value, not missing, so it
///   participates and **propagates**: any non-null `NaN` makes the sum
///   `NaN` (Polars semantics; only `Null` is skipped).
/// - Empty / all-null numeric series → `Scalar::Int(0)` or
///   `Scalar::Float(0.0)` (additive identity). An all-`NaN` `Float` series
///   sums to `NaN`, not the identity — every cell is a present value.
/// - Non-numeric series (`Bool`, `String`) → `raise TypeMismatch`.
pub fn Series::sum(self : Series) -> @types.Scalar raise @types.DataError {
  // Numeric fast path: a bitmap-free tight fold over the raw array — no
  // `validity().to_bools()` materialisation and no per-slot `if valid[i]`
  // branch (the `NumericColumn` reduction win, S1). Total there: every dtype
  // a `NumericColumn` holds is numeric, so it never raises.
  if self.storage is @column.ColumnStorage::Numeric(nc) {
    return nc.sum()
  }
  // General `Builtin` backend: the shared `reduce_arith` fold over the whole
  // column (`0 ..< len`) — `Int` / `Float` reduce over the validity mask,
  // every other dtype raises `TypeMismatch`, all from the one kernel `agg`
  // and `eval_agg` also reduce through.
  reduce_arith(self.storage, want_mean=false)(self.len(), k => k)
}

///|
/// Arithmetic mean of non-null cells, returned as `Double`.
///
/// Reductions run in 64-bit — an `Int64` sum for `Int` columns, `Double`
/// accumulation for `Float` columns — and the division is performed in
/// `Double`, so a long column does not lose precision the way a 32-bit
/// accumulation would.
///
/// The denominator is the **non-null** count (`Series::count`), so a
/// `Float` `NaN` is a present value that both counts toward the divisor
/// and **propagates**: any non-null `NaN` makes the mean `NaN` (Polars
/// semantics; only `Null` is skipped).
///
/// - Empty / all-null numeric series → `raise InvalidOperation(...)`.
/// - Non-numeric series → `raise TypeMismatch(...)`.
pub fn Series::mean(self : Series) -> Double raise @types.DataError {
  // Numeric fast path: bitmap-free fold with an all-valid denominator
  // (`len`), raising `InvalidOperation` on an empty column exactly as the
  // `Builtin` path below does. No validity materialisation.
  if self.storage is @column.ColumnStorage::Numeric(nc) {
    return nc.mean()
  }
  // General `Builtin` backend: the shared `reduce_arith` mean reduces the
  // whole column to a `Scalar`, raising `TypeMismatch` for a non-numeric
  // dtype (before producing a value) and returning `Scalar::Null` for an
  // empty / all-null column — which this surface translates to
  // `InvalidOperation`, the distinction `mean_opt` / the grouped reducer
  // resolve differently.
  match reduce_arith(self.storage, want_mean=true)(self.len(), k => k) {
    @types.Scalar::Float(m) => m
    _ =>
      raise @types.DataError::InvalidOperation("mean of empty/all-null series")
  }
}

///|
/// Total arithmetic mean: `Some(mean)` for a numeric series with at least
/// one non-null cell, `None` for a non-numeric, empty, or all-null series —
/// i.e. `None` exactly where `Series::mean` raises (`TypeMismatch` /
/// `InvalidOperation`). This is the total form `describe` summarises with,
/// mirroring the total `min_value` / `max_value`; `Series::mean` remains the
/// raising public form that distinguishes the two failure causes, and this
/// folds both of them into `None`. A `Float` `NaN` is summed in and
/// propagates to `Some(NaN)`, matching `mean` (Polars — only `Null` is
/// missing). Package-private: exercised to full coverage through the
/// `describe` tests (which summarise numeric, non-numeric, and all-null
/// columns, so both arms below are reached).
fn Series::mean_opt(self : Series) -> Double? {
  Some(self.mean()) catch {
    _ => None
  }
}

///|
/// Minimum non-null cell as a `Scalar`, by the natural order of the
/// series' dtype. Total — every v0.1 dtype has an order, so it never
/// fails (the v0.1 `Result`-wrapped `min` has been dropped in v0.2).
///
/// - Empty / all-null → `Scalar::Null`.
/// - `Float` NaN is skipped (treated as missing), matching `sort_by` and
///   Polars' regular `min` / `max`, which ignore `NaN` — distinct from the
///   propagating `nan_min` / `nan_max`. (This differs from `sum` / `mean`,
///   where `NaN` propagates — exactly as in Polars.) A series of only NaN
///   (and/or nulls) → `Scalar::Null`.
/// - `Bool` order: `false < true`.
pub fn Series::min_value(self : Series) -> @types.Scalar {
  // Numeric fast path: bitmap-free extremum fold (NaN still skipped, empty
  // → `Null`). No validity materialisation.
  if self.storage is @column.ColumnStorage::Numeric(nc) {
    return nc.min_value()
  }
  // General `Builtin` backend: the shared `reduce_extremum` fold over the
  // whole column — total over every dtype (`Bool` `false < true`, `String`
  // lexicographic), the same kernel the grouped / scoped `min` reduce
  // through, with `NaN` skipped and empty / all-null → `Null`.
  reduce_extremum(self.storage, want_min=true)(self.len(), k => k)
}

///|
/// Maximum non-null cell as a `Scalar`. Mirrors `min_value` with the order
/// reversed; the `Float` NaN and empty-series rules are identical.
/// Total — the v0.1 `Result`-wrapped `max` has been dropped in v0.2.
pub fn Series::max_value(self : Series) -> @types.Scalar {
  if self.storage is @column.ColumnStorage::Numeric(nc) {
    return nc.max_value()
  }
  reduce_extremum(self.storage, want_min=false)(self.len(), k => k)
}

///|
/// Number of distinct non-null values. Cells are keyed by the same
/// composite-key normalisation `group_by` / `join` use (`key_cell`), so the
/// distinct count agrees with grouping cell-for-cell: two cells collide
/// exactly when they would share a `group_by` group. Two `Float`
/// normalisations follow from that shared key — every `NaN` collapses into
/// one bucket (it is a value, not missing, so it is one distinct value, the
/// rule that also puts every `NaN` key in one `group_by` group), and `-0.0`
/// folds into `+0.0` (they are IEEE-equal and share a group, hence one
/// distinct value). Keying by `Scalar::to_string` would instead let the
/// `-0.0` rendering split them, diverging from `group_by`.
pub fn Series::unique_count(self : Series) -> Int {
  // Key the non-null cells by `key_cell` — the same `KeyCell` encoding
  // `group_by` / `join` hash on (frame/row_key.mbt) — so "distinct value"
  // means exactly "distinct group": `NaN` collapses to one `KNaN` and `-0.0`
  // folds into `+0.0`, matching the grouping semantics rather than diverging
  // on `Double::to_string`'s `-0.0` rendering. `Map::from_array` folds the
  // keys into a set; its size is the distinct count.
  Map::from_array(
    self.to_scalars().filter(sc => !sc.is_null()).map(sc => (key_cell(sc), ())),
  ).length()
}

///|
/// One-row summary `DataFrame`.
///
/// Every series produces the same six columns in the same order, so the
/// summary shape is uniform across dtypes: `count`, `null_count`,
/// `unique_count` (`Int`), then `mean` (`Double`, `Null` for non-numeric
/// or empty / all-null numeric), then `min` and `max` in the source
/// dtype (`Null` cells when the reduction has no value). Non-numeric
/// series still carry the `mean` column (always `Null`) so callers can
/// rely on a fixed layout regardless of dtype.
///
/// The dtype dispatch matches on the concrete backing array via
/// `storage.data()` — `ColumnData`'s four variants are exhaustive, so
/// there's no `Null`-dtype arm and no fallback branch to keep in sync.
///
/// Raises only because the summary frame is built through the fallible
/// `DataFrame::new`. The columns are hardcoded-unique and equal length, so
/// the constructor always succeeds — the raise is forwarded rather than
/// caught, so no panic path crosses the public API.
pub fn Series::describe(self : Series) -> DataFrame raise @types.DataError {
  let cols : Array[Series] = []
  cols.push(Series::from_ints("count", [self.count().to_int64()]))
  cols.push(Series::from_ints("null_count", [self.null_count().to_int64()]))
  cols.push(Series::from_ints("unique_count", [self.unique_count().to_int64()]))
  // `mean` is always present (Null for non-numeric / empty / all-null), so
  // the summary shape is uniform across dtypes. `mean_opt` is the total form
  // of `Series::mean` — `None` exactly where `mean` would raise (non-numeric
  // or empty / all-null) — so the summary reads it directly and needs no
  // error catch, mirroring the total `min_value` / `max_value` used below.
  cols.push(Series::from_float_options("mean", [self.mean_opt()]))
  // `min` / `max` keep the source dtype, so dispatch on the concrete
  // backing array.
  match self.storage.data() {
    @column.ColumnData::Int(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::Int(x) => Some(x)
            _ => None
          }
        },
        Series::from_int_options,
      )
    @column.ColumnData::Float(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::Float(x) => Some(x)
            _ => None
          }
        },
        Series::from_float_options,
      )
    @column.ColumnData::Bool(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::Bool(x) => Some(x)
            _ => None
          }
        },
        Series::from_bool_options,
      )
    @column.ColumnData::String(_) =>
      push_extrema(
        self,
        cols,
        fn(sc) {
          match sc {
            @types.Scalar::String(x) => Some(x)
            _ => None
          }
        },
        Series::from_string_options,
      )
  }
  DataFrame::new(cols)
}

///|
/// Push the source-dtype `min` / `max` summary columns for `describe`.
/// `extract` projects a `min_value` / `max_value` `Scalar` into the typed
/// cell (`None` for the no-value / wrong-variant case), and `build` is the
/// matching option constructor — so the four dtype arms share one body
/// instead of four near-identical helpers.
fn[T] push_extrema(
  s : Series,
  cols : Array[Series],
  extract : (@types.Scalar) -> T?,
  build : (String, Array[T?]) -> Series,
) -> Unit {
  cols.push(build("min", [extract(s.min_value())]))
  cols.push(build("max", [extract(s.max_value())]))
}
