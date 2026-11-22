// Blackbox tests for the `ewm_*` family — the exponentially-weighted
// recurrence, evaluated through `select`. Pinned: the adjust and
// non-adjust blends, the span/alpha handshake, `min_samples` gating, both
// null policies, the variance/std relation, the always-Float dtype, and
// the parameter-envelope refusals.

///|
test "ewm_mean with alpha 1 is the identity, and span decodes to alpha" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  assert_eq(
    df
    .select([@expr.col("v").ewm_mean(alpha=1.0).with_alias("m")])
    .get_column("m")
    .to_scalars(),
    [
      @types.Scalar::Float(1.0),
      @types.Scalar::Float(2.0),
      @types.Scalar::Float(3.0),
    ],
  )
  // span 3 decodes to alpha 0.5; the non-adjust blend has clean values.
  assert_eq(
    df
    .select([@expr.col("v").ewm_mean(span=3.0, adjust=false).with_alias("m")])
    .get_column("m")
    .to_scalars(),
    [
      @types.Scalar::Float(1.0),
      @types.Scalar::Float(1.5),
      @types.Scalar::Float(2.25),
    ],
  )
}

///|
test "ewm_mean keeps the earlier samples' full weight under adjust" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  // alpha 0.5: the weighted mean divides by the running weight sum, so
  // the expected cells are exact quotients both sides compute the same
  // way.
  let out = df.select([@expr.col("v").ewm_mean(alpha=0.5).with_alias("m")])
  assert_eq(out.get_column("m").dtype(), @types.DataType::Float)
  assert_eq(out.item(0, "m"), @types.Scalar::Float(1.0))
  assert_eq(out.item(1, "m"), @types.Scalar::Float(2.5 / 1.5))
  assert_eq(out.item(2, "m"), @types.Scalar::Float(4.25 / 1.75))
}

///|
test "min_samples gates the leading cells to null" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  assert_eq(
    df
    .select([@expr.col("v").ewm_mean(alpha=1.0, min_samples=2).with_alias("m")])
    .get_column("m")
    .to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Float(2.0), @types.Scalar::Float(3.0)],
  )
}

///|
test "nulls skip or decay per ignore_nulls" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1), None, Some(3)]),
  ])
  // Skipping the null entirely: the third cell blends against the state
  // the first left.
  let skip = df.select([
    @expr.col("v").ewm_mean(alpha=0.5, ignore_nulls=true).with_alias("m"),
  ])
  assert_eq(skip.item(0, "m"), @types.Scalar::Float(1.0))
  assert_true(skip.item(1, "m") is @types.Scalar::Null)
  assert_eq(skip.item(2, "m"), @types.Scalar::Float(3.5 / 1.5))
  // The default lets the null's weight decay as if a value had passed:
  // the weight sum itself decayed over the null, so the third cell's
  // quotient divides 3.25 by 1.25.
  let decay = df.select([@expr.col("v").ewm_mean(alpha=0.5).with_alias("m")])
  assert_eq(decay.item(2, "m"), @types.Scalar::Float(3.25 / 1.25))
}

///|
test "the variance and deviation read the running second moment" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  let out = df.select([
    @expr.col("v").ewm_variance(alpha=0.5).with_alias("var"),
    @expr.col("v").ewm_std(alpha=0.5).with_alias("sd"),
  ])
  // At the second cell: m2 = 0.5·1 + 4 = 4.5, w = 1.5, mean = 5/3, so the
  // biased variance is 4.5/1.5 − (5/3)² = 2/9.
  let v2 = 4.5 / 1.5 - 5.0 / 3.0 * (5.0 / 3.0)
  assert_eq(out.item(1, "var"), @types.Scalar::Float(v2))
  assert_eq(out.item(1, "sd"), @types.Scalar::Float(v2.sqrt()))
  // alpha 1 collapses each window to its own value: zero variance.
  let flat = df.select([
    @expr.col("v").ewm_variance(alpha=1.0).with_alias("var"),
  ])
  assert_eq(flat.get_column("var").to_scalars(), [
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(0.0),
  ])
}

///|
test "the parameter envelope refuses at evaluation" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  // Neither span nor alpha; alpha outside (0, 1]; min_samples
  // below 1 — each is an InvalidOperation, the builder stays total.
  for
    e in [
      @expr.col("v").ewm_mean(),
      @expr.col("v").ewm_mean(alpha=0.0),
      @expr.col("v").ewm_mean(alpha=1.5),
      @expr.col("v").ewm_mean(alpha=0.5, min_samples=0),
      @expr.col("v").ewm_mean(span=1.0),
      @expr.col("v").ewm_mean(span=0.5),
    ] {
    let result : Result[DataFrame, @types.DataError] = Ok(
      df.select([e.with_alias("m")]),
    ) catch {
      err => Err(err)
    }
    assert_true(result is Err(@types.DataError::InvalidOperation(_)))
  }
  // A double-set build is no longer a refusal: span wins and the alpha is
  // ignored, so it evaluates exactly as the span-only tree does.
  let both = df.select([
    @expr.col("v").ewm_mean(span=3.0, alpha=0.5).with_alias("m"),
  ])
  let span_only = df.select([@expr.col("v").ewm_mean(span=3.0).with_alias("m")])
  assert_eq(
    both.get_column("m").to_scalars(),
    span_only.get_column("m").to_scalars(),
  )
  // A span of 1 would decode to alpha 1; the span envelope is `> 1`, so
  // it refuses with the rest. A span below 1 does too.
  assert_true(
    (Ok(ignore(df.select([@expr.col("v").ewm_mean(span=0.5).with_alias("m")]))) catch {
      err => Err(err)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a non-numeric operand is a TypeMismatch" {
  let df = DataFrame::DataFrame([Series::from_strings("s", ["a"])])
  assert_true(
    (Ok(ignore(df.select([@expr.col("s").ewm_mean(alpha=0.5).with_alias("m")]))) catch {
      err => Err(err)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a Float operand blends through its own cells" {
  let df = DataFrame::DataFrame([
    Series::from_float_options("v", [Some(1.5), None, Some(3.0)]),
  ])
  let out = df.select([
    @expr.col("v").ewm_mean(alpha=0.5, ignore_nulls=true).with_alias("m"),
  ])
  assert_eq(out.item(0, "m"), @types.Scalar::Float(1.5))
  assert_eq(out.item(2, "m"), @types.Scalar::Float((0.75 + 3.0) / 1.5))
}

///|
test "a constant column's variance saturates at zero, never below" {
  // The variance is a difference of two raw moments, whose cancellation
  // error grows with the square of the magnitude: a constant column at
  // 1e9 lands each cell a hair below zero unsaturated (the adversarial
  // review measured -128 at alpha 0.3), and the std a NaN. A true
  // variance is never negative, so every cell saturates at zero.
  let df = DataFrame::DataFrame([
    Series::from_ints("v", Array::makei(16, _ => 1_000_000_000)),
  ])
  for
    expr in [
      @expr.col("v").ewm_variance(alpha=0.3),
      @expr.col("v").ewm_std(alpha=0.3),
      @expr.col("v").ewm_variance(alpha=0.9, adjust=false),
    ] {
    let out = df.select([expr.with_alias("s")]).get_column("s")
    for cell in out.to_scalars() {
      assert_true(cell is @types.Scalar::Float(v) && v >= 0.0 && !v.is_nan())
    }
  }
}

///|
test "adjust=false variance follows the recursive second moment" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1L, 2L, 3L])])
  let out = df.select([
    @expr.col("v").ewm_variance(alpha=0.5, adjust=false).with_alias("var"),
    @expr.col("v").ewm_std(alpha=0.5, adjust=false).with_alias("sd"),
  ])
  // y: 1, 1.5, 2.25; q: 1, 2.5, 5.75; q - y^2: 0, 0.25, 0.6875.
  assert_eq(out.get_column("var").to_scalars(), [
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(0.25),
    @types.Scalar::Float(0.6875),
  ])
  assert_eq(out.get_column("sd").to_scalars(), [
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(0.5),
    @types.Scalar::Float(0.6875.sqrt()),
  ])
}

///|
test "adjust=false variance decays through a null unless nulls are ignored" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1L), None, Some(3L)]),
  ])
  let decayed = df
    .select([
      @expr.col("v").ewm_variance(alpha=0.5, adjust=false).with_alias("var"),
    ])
    .get_column("var")
    .to_scalars()
  // 1 seeds y=1/q=1; the null halves both; 3 gives y=1.75, q=4.75.
  assert_eq(decayed, [
    @types.Scalar::Float(0.0),
    @types.Scalar::Null,
    @types.Scalar::Float(1.6875),
  ])
  let skipped = df
    .select([
      @expr.col("v")
      .ewm_variance(alpha=0.5, adjust=false, ignore_nulls=true)
      .with_alias("var"),
    ])
    .get_column("var")
    .to_scalars()
  // The null leaves the state untouched: y=2, q=5.
  assert_eq(skipped, [
    @types.Scalar::Float(0.0),
    @types.Scalar::Null,
    @types.Scalar::Float(1.0),
  ])
}
