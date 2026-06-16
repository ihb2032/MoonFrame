// Cross-surface reduction equivalence.
//
// `Series::sum` / `mean` / `min` / `max` / `count` (whole column)
// and the grouped `agg` (the expression evaluator) reduce through one shared
// index-generic kernel (`reduce.mbt`). On a single-group frame both reduce
// exactly the same cells, so they must agree cell-for-cell. These tests pin
// that unification — the point of folding the former copies into one kernel —
// across every dtype and the `NaN` rules (`sum` / `mean` propagate, `min` /
// `max` skip), guarding against the surfaces drifting apart again.

///|
/// Wrap `x` (which must be named `"x"`) in a one-group frame: a constant
/// String key `"k"` plus the value column. Grouping by `"k"` yields a single
/// group spanning every row, so a per-group reduction reduces the same cells
/// as the whole-column one.
fn one_group_df(x : Series) -> DataFrame raise @types.DataError {
  DataFrame::new([Series::from_strings("k", Array::make(x.len(), "a")), x])
}

///|
/// The single grouped-`agg` result cell for reduction `e`, aliased "r".
fn group_cell(
  df : DataFrame,
  e : @expr.Expr,
) -> @types.Scalar raise @types.DataError {
  df.group_by([@expr.col("k")]).agg([e.with_alias("r")]).get_column("r").get(0)
}

///|
/// `true` when two reduction `Scalar`s agree, treating two `Float` `NaN`s as
/// equal: derived `Eq` makes `NaN != NaN`, but "both surfaces produced `NaN`"
/// is exactly the agreement `sum` / `mean` propagation should assert.
fn reductions_agree(a : @types.Scalar, b : @types.Scalar) -> Bool {
  match (a, b) {
    (@types.Scalar::Float(x), @types.Scalar::Float(y)) =>
      (x.is_nan() && y.is_nan()) || x == y
    _ => a == b
  }
}

///|
/// `min` / `max` / `count` (total over every dtype) agree across both surfaces
/// for the value column `x` of one-group frame `df`.
fn check_min_max_count(x : Series, df : DataFrame) -> Unit raise Error {
  let whole_min = x.min()
  assert_true(reductions_agree(whole_min, group_cell(df, @expr.col("x").min())))
  let whole_max = x.max()
  assert_true(reductions_agree(whole_max, group_cell(df, @expr.col("x").max())))
  let whole_count = @types.Scalar::Int(x.count().to_int64())
  assert_true(
    reductions_agree(whole_count, group_cell(df, @expr.col("x").count())),
  )
}

///|
/// All five reductions agree across both surfaces for a numeric column with at
/// least one non-null cell (so `mean` does not hit the all-null edge, pinned
/// separately below).
fn check_numeric_surfaces(x : Series) -> Unit raise Error {
  let df = one_group_df(x)
  let whole_sum = x.sum()
  assert_true(reductions_agree(whole_sum, group_cell(df, @expr.col("x").sum())))
  // `Series::mean` is a `Double`; the grouped cell is a `Float` scalar, so lift
  // the whole-column result to compare.
  let whole_mean = @types.Scalar::Float(x.mean())
  assert_true(
    reductions_agree(whole_mean, group_cell(df, @expr.col("x").mean())),
  )
  check_min_max_count(x, df)
}

///|
test "two surfaces agree: Builtin Int with nulls" {
  check_numeric_surfaces(
    Series::from_int_options("x", [
      Some(3),
      None,
      Some(7),
      Some(1),
      None,
      Some(5),
    ]),
  )
}

///|
test "two surfaces agree: Numeric Int (all-valid fast path)" {
  // `from_ints` lands on the `Numeric` backend, so `Series::sum` etc. take the
  // bitmap-free fast path while the grouped `agg` reduces through the kernel
  // with the constant-true presence predicate — they must still agree.
  check_numeric_surfaces(Series::from_ints("x", [3, 1, 4, 1, 5, 9, 2, 6]))
}

///|
test "two surfaces agree: Float with NaN and nulls (propagate vs skip)" {
  let nan = @double.not_a_number
  let x = Series::from_float_options("x", [
    Some(2.5),
    Some(nan),
    None,
    Some(1.0),
    Some(4.0),
  ])
  check_numeric_surfaces(x)
  // Pin the `NaN` rules explicitly: `sum` / `mean` propagate `NaN`, `min` /
  // `max` skip it (so they return the finite extrema).
  assert_true(x.sum().as_float().is_nan())
  assert_eq(x.min(), @types.Scalar::Float(1.0))
  assert_eq(x.max(), @types.Scalar::Float(4.0))
}

///|
test "two surfaces agree: Numeric Float (all-valid fast path)" {
  check_numeric_surfaces(Series::from_floats("x", [2.5, 1.0, 4.0, 3.5]))
}

///|
test "two surfaces agree: Bool min/max/count" {
  let x = Series::from_bool_options("x", [
    Some(true),
    None,
    Some(false),
    Some(true),
  ])
  check_min_max_count(x, one_group_df(x))
}

///|
test "two surfaces agree: String min/max/count" {
  let x = Series::from_string_options("x", [
    Some("pear"),
    None,
    Some("apple"),
    Some("fig"),
  ])
  check_min_max_count(x, one_group_df(x))
}

///|
test "two surfaces agree: all-null numeric, with the documented mean divergence" {
  let x = Series::from_int_options("x", [None, None, None])
  let df = one_group_df(x)
  // sum → additive identity, min / max → Null, count → 0: both surfaces agree.
  assert_true(reductions_agree(x.sum(), group_cell(df, @expr.col("x").sum())))
  check_min_max_count(x, df)
  // `mean` is the one deliberate divergence: the whole-column form raises
  // `InvalidOperation` (an all-null mean is undefined), while a per-group
  // reduction must yield a value slot — a **null cell** — for an all-null
  // group (Polars semantics).
  assert_true((try? x.mean()) is Err(@types.DataError::InvalidOperation(_)))
  assert_eq(group_cell(df, @expr.col("x").mean()), @types.Scalar::Null)
}
