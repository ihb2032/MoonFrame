///|
/// Blackbox tests for the expression aggregation family added on the shared
/// reduction kernel — `std` / `variance` / `median` / `n_unique` / `first` /
/// `last` — driven through both reduction surfaces: a whole-frame `select`
/// (the per-scope evaluator) and a grouped `agg` (the single-pass fast path).
/// Covers each op's value, output dtype, and null / NaN rule: `std` / `var`
/// propagate NaN and reduce a `< 2`-cell scope to null, `median` skips NaN,
/// `n_unique` buckets NaN as one and excludes nulls, and `first` / `last` are
/// positional (a null leading / trailing cell, or an empty scope, is null).
/// Non-numeric `std` / `var` / `median` raise `TypeMismatch`. Construction and
/// rendering live in `expr`'s tests; this pins evaluation.

///|
/// The single cell of the whole-frame reduction `e` over `df`, via `select`:
/// `select([agg])` collapses to one row, so cell `(0, "r")` is the reduction.
fn whole(
  df : DataFrame,
  e : @expr.Expr,
) -> @types.Scalar raise @types.DataError {
  df.select([e.with_alias("r")]).item(0, "r")
}

// ── std / variance: value, dtype, NaN propagation, < 2 cells ───────────

///|
test "std and variance reduce a whole frame to the sample statistics" {
  // [2, 4, 6]: mean 4, squared deviations 4 + 0 + 4 = 8, sample variance
  // (ddof = 1) 8 / 2 = 4.0, standard deviation its root, 2.0. Both are Float
  // even though the source is Int.
  let df = DataFrame::new([Series::from_ints("x", [2, 4, 6])])
  assert_eq(whole(df, @expr.col("x").std()), @types.Scalar::Float(2.0))
  assert_eq(whole(df, @expr.col("x").variance()), @types.Scalar::Float(4.0))
}

///|
test "std over a Float column keeps Float and propagates NaN" {
  let df = DataFrame::new([Series::from_floats("x", [1.0, 2.0, 3.0])])
  // [1, 2, 3]: variance 1.0, std 1.0.
  assert_eq(whole(df, @expr.col("x").std()), @types.Scalar::Float(1.0))
  // A non-null NaN is a value: it flows through the mean, so std / var
  // propagate it (matching sum / mean), unlike min / max / median.
  let nan = @double.not_a_number
  let dfn = DataFrame::new([Series::from_floats("x", [1.0, 2.0, nan])])
  assert_true(whole(dfn, @expr.col("x").std()).as_float().is_nan())
  assert_true(whole(dfn, @expr.col("x").variance()).as_float().is_nan())
}

///|
test "variance and std of equal large-magnitude values are 0, not +inf" {
  // Two equal cells near Double-max: the true variance is 0. A two-pass mean
  // would sum them to +inf and report +inf; Welford never forms the raw sum, so
  // the finite variance survives.
  let df = DataFrame::new([Series::from_floats("x", [1.0e308, 1.0e308])])
  assert_eq(whole(df, @expr.col("x").variance()), @types.Scalar::Float(0.0))
  assert_eq(whole(df, @expr.col("x").std()), @types.Scalar::Float(0.0))
}

///|
test "variance and std of opposite-sign extremes saturate to +inf, never negative" {
  // Finite cells more than Double-max apart: Welford's running `delta`
  // overflows and used to poison `m2` to -inf — a mathematically impossible
  // NEGATIVE variance, and sqrt(-inf) = NaN for std. The true variance
  // (~2e616) exceeds Double's range, so the statistic saturates to +inf,
  // as numpy (ddof=1) and Polars report.
  let two = DataFrame::new([Series::from_floats("x", [-1.0e308, 1.0e308])])
  assert_eq(
    whole(two, @expr.col("x").variance()),
    @types.Scalar::Float(@double.infinity),
  )
  assert_eq(
    whole(two, @expr.col("x").std()),
    @types.Scalar::Float(@double.infinity),
  )
  // A longer alternating window drives the artefact to NaN instead of -inf;
  // the finite-input rescue covers it the same way.
  let three = DataFrame::new([
    Series::from_floats("x", [1.0e308, -1.0e308, 1.0e308]),
  ])
  assert_eq(
    whole(three, @expr.col("x").variance()),
    @types.Scalar::Float(@double.infinity),
  )
  // A genuine ±inf INPUT is not rescued: it propagates through the mean
  // like sum / mean, so the statistic is NaN (inf - inf), not +inf.
  let inf_in = DataFrame::new([
    Series::from_floats("x", [@double.infinity, 1.0]),
  ])
  assert_true(whole(inf_in, @expr.col("x").variance()).as_float().is_nan())
  assert_true(whole(inf_in, @expr.col("x").std()).as_float().is_nan())
}

///|
test "std and variance are null for fewer than two non-null cells" {
  // Sample statistics need ddof = 1 < cnt: one value, or none, has no
  // sample variance, so the cell is null rather than 0.0.
  let one = DataFrame::new([Series::from_ints("x", [5])])
  assert_eq(whole(one, @expr.col("x").std()), @types.Scalar::Null)
  assert_eq(whole(one, @expr.col("x").variance()), @types.Scalar::Null)
  let empty = DataFrame::new([Series::from_ints("x", [])])
  assert_eq(whole(empty, @expr.col("x").std()), @types.Scalar::Null)
  // Nulls are skipped, so a lone non-null cell beside nulls is still < 2.
  let sparse = DataFrame::new([
    Series::from_int_options("x", [Some(5), None, None]),
  ])
  assert_eq(whole(sparse, @expr.col("x").variance()), @types.Scalar::Null)
}

// ── median: value, even/odd, dtype, NaN skipped ───────────────────────

///|
test "median is the middle of the sorted non-null cells, always Float" {
  // Odd count: the middle. Int widens, so the result is Float.
  let odd = DataFrame::new([Series::from_ints("x", [3, 1, 2])])
  assert_eq(whole(odd, @expr.col("x").median()), @types.Scalar::Float(2.0))
  // Even count: the mean of the two middles.
  let even = DataFrame::new([Series::from_ints("x", [1, 2, 3, 4])])
  assert_eq(whole(even, @expr.col("x").median()), @types.Scalar::Float(2.5))
}

///|
test "median skips NaN and nulls, all-missing is null" {
  let nan = @double.not_a_number
  // NaN is ordered as missing (the min / max / sort rule, not propagation):
  // the median of [1, 2, NaN] is the median of [1, 2], i.e. 1.5.
  let df = DataFrame::new([Series::from_floats("x", [1.0, 2.0, nan])])
  assert_eq(whole(df, @expr.col("x").median()), @types.Scalar::Float(1.5))
  // Nulls drop out the same way; [10, null, 20, null, 30] medians to 20.0.
  let sparse = DataFrame::new([
    Series::from_float_options("x", [
      Some(10.0),
      None,
      Some(20.0),
      None,
      Some(30.0),
    ]),
  ])
  assert_eq(whole(sparse, @expr.col("x").median()), @types.Scalar::Float(20.0))
  // Every cell missing → null.
  let allnull = DataFrame::new([Series::from_float_options("x", [None, None])])
  assert_eq(whole(allnull, @expr.col("x").median()), @types.Scalar::Null)
}

///|
test "median of two near-Double-max middles stays finite (no overflow to Inf)" {
  // The sum of the two middle cells overflows Double before the halving, yet the
  // median lies between them and is finite. Regression guard: the naive
  // `(lo + hi) / 2` returned +Inf here.
  let big = DataFrame::new([Series::from_floats("x", [1.6e308, 1.7e308])])
  assert_eq(
    whole(big, @expr.col("x").median()),
    @types.Scalar::Float(1.6e308 / 2.0 + 1.7e308 / 2.0),
  )
}

// ── n_unique: distinct non-null across every dtype ─────────────────────

///|
test "n_unique counts distinct non-null values, an Int over any dtype" {
  let ints = DataFrame::new([Series::from_ints("x", [1, 1, 2, 3, 3, 3])])
  assert_eq(whole(ints, @expr.col("x").n_unique()), @types.Scalar::Int(3))
  let bools = DataFrame::new([Series::from_bools("x", [true, true, false])])
  assert_eq(whole(bools, @expr.col("x").n_unique()), @types.Scalar::Int(2))
  let strs = DataFrame::new([Series::from_strings("x", ["a", "a", "b"])])
  assert_eq(whole(strs, @expr.col("x").n_unique()), @types.Scalar::Int(2))
  // Empty scope → zero distinct values (never null).
  let empty = DataFrame::new([Series::from_ints("x", [])])
  assert_eq(whole(empty, @expr.col("x").n_unique()), @types.Scalar::Int(0))
}

///|
test "n_unique buckets every NaN as one value and excludes nulls" {
  let nan = @double.not_a_number
  // Two distinct values — the finite 1.0 and the single NaN bucket — even
  // though two NaN cells appear (NaN is one value, the n_unique / group rule).
  let floats = DataFrame::new([Series::from_floats("x", [1.0, nan, 1.0, nan])])
  assert_eq(whole(floats, @expr.col("x").n_unique()), @types.Scalar::Int(2))
  // Nulls are not a value here: [1, null, 1, 2] has two distinct values.
  let sparse = DataFrame::new([
    Series::from_int_options("x", [Some(1), None, Some(1), Some(2)]),
  ])
  assert_eq(whole(sparse, @expr.col("x").n_unique()), @types.Scalar::Int(2))
}

///|
test "n_unique agrees with the whole-column Series statistic" {
  // The kernel reducer and `Series::n_unique` are separate implementations of
  // the same count; pin that they agree so neither drifts.
  let x = Series::from_int_options("x", [
    Some(1),
    None,
    Some(1),
    Some(2),
    Some(2),
  ])
  let df = DataFrame::new([x])
  assert_eq(
    whole(df, @expr.col("x").n_unique()),
    @types.Scalar::Int(x.n_unique().to_int64()),
  )
}

// ── first / last: positional, every dtype, null / empty ───────────────

///|
test "first and last take the positional cell, keeping the source dtype" {
  let ints = DataFrame::new([Series::from_ints("x", [10, 20, 30])])
  assert_eq(whole(ints, @expr.col("x").first()), @types.Scalar::Int(10))
  assert_eq(whole(ints, @expr.col("x").last()), @types.Scalar::Int(30))
  let floats = DataFrame::new([Series::from_floats("x", [1.5, 2.5, 3.5])])
  assert_eq(whole(floats, @expr.col("x").last()), @types.Scalar::Float(3.5))
  let bools = DataFrame::new([Series::from_bools("x", [true, false, true])])
  assert_eq(whole(bools, @expr.col("x").first()), @types.Scalar::Bool(true))
  let strs = DataFrame::new([Series::from_strings("x", ["a", "b", "c"])])
  assert_eq(whole(strs, @expr.col("x").first()), @types.Scalar::String("a"))
}

///|
test "first and last are null on a null leading or trailing cell, or empty" {
  // Positional: a null first / last cell is null, not the first / last
  // *present* value.
  let headnull = DataFrame::new([
    Series::from_int_options("x", [None, Some(2), Some(3)]),
  ])
  assert_eq(whole(headnull, @expr.col("x").first()), @types.Scalar::Null)
  let tailnull = DataFrame::new([
    Series::from_int_options("x", [Some(1), Some(2), None]),
  ])
  assert_eq(whole(tailnull, @expr.col("x").last()), @types.Scalar::Null)
  // An empty scope has no first / last cell → null.
  let empty = DataFrame::new([Series::from_ints("x", [])])
  assert_eq(whole(empty, @expr.col("x").first()), @types.Scalar::Null)
  assert_eq(whole(empty, @expr.col("x").last()), @types.Scalar::Null)
}

// ── Non-numeric std / variance / median raise ─────────────────────────

///|
test "std, variance, and median reject non-numeric columns" {
  let strs = DataFrame::new([Series::from_strings("x", ["a", "b"])])
  assert_true(
    (Ok(whole(strs, @expr.col("x").std())) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  assert_true(
    (Ok(whole(strs, @expr.col("x").variance())) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  let bools = DataFrame::new([Series::from_bools("x", [true, false])])
  assert_true(
    (Ok(whole(bools, @expr.col("x").median())) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

// ── Grouped agg: per-group reductions over the fast path ───────────────

///|
/// Five-row sales fixture grouped by `region`: `east` = rows 0, 2, 3
/// (quantity 10, 2, 6), `west` = rows 1, 4 (quantity 5, 4); `east` first.
fn grouped_sales() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_strings("region", ["east", "west", "east", "east", "west"]),
    Series::from_ints("quantity", [10, 5, 2, 6, 4]),
  ])
}

///|
test "grouped agg reduces each group with the new family" {
  let out = grouped_sales()
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("quantity").std().with_alias("q_std"),
      @expr.col("quantity").variance().with_alias("q_var"),
      @expr.col("quantity").median().with_alias("q_med"),
      @expr.col("quantity").n_unique().with_alias("q_nu"),
      @expr.col("quantity").first().with_alias("q_first"),
      @expr.col("quantity").last().with_alias("q_last"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), [
    "region", "q_std", "q_var", "q_med", "q_nu", "q_first", "q_last",
  ])
  // east quantity = [10, 2, 6]: mean 6, var (16 + 16 + 0) / 2 = 16.0,
  // std 4.0, median (sorted 2, 6, 10) 6.0, 3 distinct, first 10, last 6.
  assert_eq(out.item(0, "q_std"), @types.Scalar::Float(4.0))
  assert_eq(out.item(0, "q_var"), @types.Scalar::Float(16.0))
  assert_eq(out.item(0, "q_med"), @types.Scalar::Float(6.0))
  assert_eq(out.item(0, "q_nu"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "q_first"), @types.Scalar::Int(10))
  assert_eq(out.item(0, "q_last"), @types.Scalar::Int(6))
  // west quantity = [5, 4]: mean 4.5, var (0.25 + 0.25) / 1 = 0.5, std its
  // root, median (sorted 4, 5) 4.5, 2 distinct, first 5, last 4.
  assert_eq(out.item(1, "q_std"), @types.Scalar::Float(0.5.sqrt()))
  assert_eq(out.item(1, "q_var"), @types.Scalar::Float(0.5))
  assert_eq(out.item(1, "q_med"), @types.Scalar::Float(4.5))
  assert_eq(out.item(1, "q_nu"), @types.Scalar::Int(2))
  assert_eq(out.item(1, "q_first"), @types.Scalar::Int(5))
  assert_eq(out.item(1, "q_last"), @types.Scalar::Int(4))
}

///|
test "grouped agg reduces a derived operand through the general path" {
  // A non-bare operand bypasses the single-pass fast path and reduces through
  // the general per-group evaluator — the same kernel, reached the other way.
  let out = grouped_sales()
    .group_by([@expr.col("region")])
    .agg([(@expr.col("quantity") + @expr.lit_int(0)).median().with_alias("m")])
  assert_eq(out.check_invariants(), Ok(()))
  // east [10, 2, 6] → 6.0, west [5, 4] → 4.5, unchanged by the `+ 0`.
  assert_eq(out.item(0, "m"), @types.Scalar::Float(6.0))
  assert_eq(out.item(1, "m"), @types.Scalar::Float(4.5))
}
