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
/// `InvalidOperation`). This is the total form `frame`'s `DataFrame::describe`
/// summarises with, mirroring the total `min` / `max`;
/// `Series::mean` remains the raising public form that distinguishes the two
/// failure causes, and this folds both of them into `None`. A `Float` `NaN` is
/// summed in and propagates to `Some(NaN)`, matching `mean` (Polars — only
/// `Null` is missing). Exercised directly by this package's tests and, across
/// the package boundary, by `DataFrame::describe` (which summarises numeric,
/// non-numeric, and all-null columns, so both arms below are reached).
pub fn Series::mean_opt(self : Series) -> Double? {
  Some(self.mean()) catch {
    _ => None
  }
}

///|
/// Minimum non-null cell as a `Scalar`, by the natural order of the
/// series' dtype (Polars' `Series.min`). Total — every v0.1 dtype has an
/// order, so it never fails (unlike the v0.1 `Result`-wrapped form this
/// replaces).
///
/// - Empty / all-null → `Scalar::Null`.
/// - `Float` NaN is skipped (treated as missing), matching `sort` and
///   Polars' regular `min` / `max`, which ignore `NaN` — distinct from the
///   propagating `nan_min` / `nan_max`. (This differs from `sum` / `mean`,
///   where `NaN` propagates — exactly as in Polars.) A series of only NaN
///   (and/or nulls) → `Scalar::Null`.
/// - `Bool` order: `false < true`.
pub fn Series::min(self : Series) -> @types.Scalar {
  // Numeric fast path: bitmap-free extremum fold (NaN still skipped, empty
  // → `Null`). No validity materialisation.
  if self.storage is @column.ColumnStorage::Numeric(nc) {
    return nc.min()
  }
  // General `Builtin` backend: the shared `reduce_extremum` fold over the
  // whole column — total over every dtype (`Bool` `false < true`, `String`
  // lexicographic), the same kernel the grouped / scoped `min` reduce
  // through, with `NaN` skipped and empty / all-null → `Null`.
  reduce_extremum(self.storage, want_min=true)(self.len(), k => k)
}

///|
/// Maximum non-null cell as a `Scalar` (Polars' `Series.max`). Mirrors
/// `min` with the order reversed; the `Float` NaN and empty-series rules
/// are identical. Total — unlike the v0.1 `Result`-wrapped form this
/// replaces.
pub fn Series::max(self : Series) -> @types.Scalar {
  if self.storage is @column.ColumnStorage::Numeric(nc) {
    return nc.max()
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
pub fn Series::n_unique(self : Series) -> Int {
  // Folds through the same `count_distinct` core the `n_unique` reduction uses
  // (reduce.mbt), keying cells by `key_cell` — the `KeyCell` encoding
  // `group_by` / `join` hash on — so the distinct count agrees with grouping
  // rather than diverging on `Double::to_string`'s `-0.0` rendering. Reading the
  // typed column directly also avoids materialising an `Array[Scalar]`.
  count_distinct(self.storage)(self.len(), k => k)
}
