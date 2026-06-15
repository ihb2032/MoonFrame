// Cross-surface reduction equivalence.
//
// `Series::sum` / `mean` / `min_value` / `max_value` / `count` (whole column),
// the grouped `agg` (the `AggSpec` path), and the scoped `agg_exprs` (the
// expression evaluator) reduce through one shared index-generic kernel
// (`reduce.mbt`). On a single-group frame all three reduce exactly the same
// cells, so they must agree cell-for-cell. These tests pin that unification —
// the point of folding the three former copies into one kernel — across every
// dtype and the `NaN` rules (`sum` / `mean` propagate, `min` / `max` skip),
// guarding against the surfaces drifting apart again.

///|
/// Wrap `x` (which must be named `"x"`) in a one-group frame: a constant
/// String key `"k"` plus the value column. Grouping by `"k"` yields a single
/// group spanning every row, so a per-group reduction reduces the same cells
/// as the whole-column one.
fn one_group_df(x : Series) -> DataFrame raise @types.DataError {
  DataFrame::new([Series::from_strings("k", Array::make(x.len(), "a")), x])
}

///|
/// The single grouped-`agg` (AggSpec path) result cell, the spec aliased "r".
fn spec_cell(
  df : DataFrame,
  spec : AggSpec,
) -> @types.Scalar raise @types.DataError {
  df.group_by(["k"]).agg([spec.with_alias("r")]).get_column("r").get(0)
}

///|
/// The single scoped-`agg_exprs` (expression path) result cell, aliased "r".
fn expr_cell(
  df : DataFrame,
  e : @expr.Expr,
) -> @types.Scalar raise @types.DataError {
  df.group_by(["k"]).agg_exprs([e.with_alias("r")]).get_column("r").get(0)
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
/// `min` / `max` / `count` (total over every dtype) agree across the three
/// surfaces for the value column `x` of one-group frame `df`.
fn check_min_max_count(x : Series, df : DataFrame) -> Unit raise Error {
  let whole_min = x.min_value()
  assert_true(reductions_agree(whole_min, spec_cell(df, AggSpec::min("x"))))
  assert_true(reductions_agree(whole_min, expr_cell(df, @expr.col("x").min())))
  let whole_max = x.max_value()
  assert_true(reductions_agree(whole_max, spec_cell(df, AggSpec::max("x"))))
  assert_true(reductions_agree(whole_max, expr_cell(df, @expr.col("x").max())))
  let whole_count = @types.Scalar::Int(x.count().to_int64())
  assert_true(reductions_agree(whole_count, spec_cell(df, AggSpec::count("x"))))
  assert_true(
    reductions_agree(whole_count, expr_cell(df, @expr.col("x").count())),
  )
}

///|
/// All five reductions agree across the three surfaces for a numeric column
/// with at least one non-null cell (so `mean` does not hit the all-null edge,
/// pinned separately below).
fn check_numeric_surfaces(x : Series) -> Unit raise Error {
  let df = one_group_df(x)
  let whole_sum = x.sum()
  assert_true(reductions_agree(whole_sum, spec_cell(df, AggSpec::sum("x"))))
  assert_true(reductions_agree(whole_sum, expr_cell(df, @expr.col("x").sum())))
  // `Series::mean` is a `Double`; the grouped / scoped cells are `Float`
  // scalars, so lift the whole-column result to compare.
  let whole_mean = @types.Scalar::Float(x.mean())
  assert_true(reductions_agree(whole_mean, spec_cell(df, AggSpec::mean("x"))))
  assert_true(
    reductions_agree(whole_mean, expr_cell(df, @expr.col("x").mean())),
  )
  check_min_max_count(x, df)
}

///|
test "three surfaces agree: Builtin Int with nulls" {
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
test "three surfaces agree: Numeric Int (all-valid fast path)" {
  // `from_ints` lands on the `Numeric` backend, so `Series::sum` etc. take the
  // bitmap-free fast path while `agg` / `agg_exprs` reduce through the kernel
  // with the constant-true presence predicate — they must still agree.
  check_numeric_surfaces(Series::from_ints("x", [3, 1, 4, 1, 5, 9, 2, 6]))
}

///|
test "three surfaces agree: Float with NaN and nulls (propagate vs skip)" {
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
  assert_eq(x.min_value(), @types.Scalar::Float(1.0))
  assert_eq(x.max_value(), @types.Scalar::Float(4.0))
}

///|
test "three surfaces agree: Numeric Float (all-valid fast path)" {
  check_numeric_surfaces(Series::from_floats("x", [2.5, 1.0, 4.0, 3.5]))
}

///|
test "three surfaces agree: Bool min/max/count" {
  let x = Series::from_bool_options("x", [
    Some(true),
    None,
    Some(false),
    Some(true),
  ])
  check_min_max_count(x, one_group_df(x))
}

///|
test "three surfaces agree: String min/max/count" {
  let x = Series::from_string_options("x", [
    Some("pear"),
    None,
    Some("apple"),
    Some("fig"),
  ])
  check_min_max_count(x, one_group_df(x))
}

///|
test "three surfaces agree: all-null numeric, with the documented mean divergence" {
  let x = Series::from_int_options("x", [None, None, None])
  let df = one_group_df(x)
  // sum → additive identity, min / max → Null, count → 0: all three agree.
  assert_true(reductions_agree(x.sum(), spec_cell(df, AggSpec::sum("x"))))
  assert_true(reductions_agree(x.sum(), expr_cell(df, @expr.col("x").sum())))
  check_min_max_count(x, df)
  // `mean` is the one deliberate divergence: the whole-column form raises
  // `InvalidOperation` (an all-null mean is undefined), while a per-group
  // reduction must yield a value slot — a **null cell** — for an all-null
  // group (Polars semantics). Both grouped / scoped surfaces give that null.
  assert_true((try? x.mean()) is Err(@types.DataError::InvalidOperation(_)))
  assert_eq(spec_cell(df, AggSpec::mean("x")), @types.Scalar::Null)
  assert_eq(expr_cell(df, @expr.col("x").mean()), @types.Scalar::Null)
}
