// Blackbox tests for the rolling family — the seven windowed statistics
// (`rolling_sum` / `mean` / `min` / `max` / `std` / `variance` / `median`)
// as trailing (default) or centred windows over the operand, evaluated
// through `select`. Pinned: the trailing-window edges null under the
// default `min_samples`, the relaxed / centred variants, the null-skip
// counting, the `NaN` split (propagated by the statistics, skipped by the
// extrema), the dtype rules, and the argument validation.

///|
test "the trailing window computes only where it is full" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3, 4, 5])])
  assert_eq(
    df.select([@expr.col("v").rolling_sum(3)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Int(6),
      @types.Scalar::Int(9),
      @types.Scalar::Int(12),
    ],
  )
  assert_eq(
    df.select([@expr.col("v").rolling_mean(3)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Float(2.0),
      @types.Scalar::Float(3.0),
      @types.Scalar::Float(4.0),
    ],
  )
  // The extrema keep the operand dtype.
  assert_eq(
    df.select([@expr.col("v").rolling_min(3)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Int(1),
      @types.Scalar::Int(2),
      @types.Scalar::Int(3),
    ],
  )
  assert_eq(
    df.select([@expr.col("v").rolling_max(3)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Int(3),
      @types.Scalar::Int(4),
      @types.Scalar::Int(5),
    ],
  )
  // A window of one is the identity (each statistic over the single cell).
  assert_eq(
    df.select([@expr.col("v").rolling_sum(1)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Int(1),
      @types.Scalar::Int(2),
      @types.Scalar::Int(3),
      @types.Scalar::Int(4),
      @types.Scalar::Int(5),
    ],
  )
}

///|
test "min_samples relaxes the full-window requirement from either end" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3, 4, 5])])
  assert_eq(
    df
    .select([@expr.col("v").rolling_sum(3, min_samples=2)])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Int(3),
      @types.Scalar::Int(6),
      @types.Scalar::Int(9),
      @types.Scalar::Int(12),
    ],
  )
  // min_samples = 1 computes from the very first cell, over whatever the
  // truncated window holds.
  assert_eq(
    df
    .select([@expr.col("v").rolling_sum(3, min_samples=1)])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(1),
      @types.Scalar::Int(3),
      @types.Scalar::Int(6),
      @types.Scalar::Int(9),
      @types.Scalar::Int(12),
    ],
  )
}

///|
test "center moves the label to the window's middle" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3, 4, 5])])
  // A 3-wide centred window spans [i-1, i+1]: both edges truncated, null
  // under the default min_samples.
  assert_eq(
    df
    .select([@expr.col("v").rolling_sum(3, center=true)])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Int(6),
      @types.Scalar::Int(9),
      @types.Scalar::Int(12),
      @types.Scalar::Null,
    ],
  )
  // An even 4-wide centred window spans [i-2, i+1] (the pandas / Polars
  // centring): under the default min_samples both truncated edges hold
  // three cells and stay null — only the two full windows compute.
  assert_eq(
    df
    .select([@expr.col("v").rolling_sum(4, center=true)])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Int(10),
      @types.Scalar::Int(14),
      @types.Scalar::Null,
    ],
  )
  // Relaxed, the truncated edges compute over what they hold.
  assert_eq(
    df
    .select([@expr.col("v").rolling_sum(3, min_samples=1, center=true)])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(3),
      @types.Scalar::Int(6),
      @types.Scalar::Int(9),
      @types.Scalar::Int(12),
      @types.Scalar::Int(9),
    ],
  )
}

///|
test "nulls are skipped by the counting and the statistic alike" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(10), None, Some(20), Some(30)]),
  ])
  // Default min_samples = 2: only the last window holds two non-null cells.
  assert_eq(
    df.select([@expr.col("v").rolling_sum(2)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Int(50),
    ],
  )
  // Relaxed to one: each window computes over its single non-null cell.
  assert_eq(
    df
    .select([@expr.col("v").rolling_sum(2, min_samples=1)])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(10),
      @types.Scalar::Int(10),
      @types.Scalar::Int(20),
      @types.Scalar::Int(50),
    ],
  )
}

///|
test "NaN propagates through the statistics and is skipped by the extrema" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::DataFrame([Series::from_floats("f", [1.0, nan, 3.0])])
  let sums = df
    .select([@expr.col("f").rolling_sum(2)])
    .get_column("f")
    .to_scalars()
  assert_true(sums[1] is @types.Scalar::Float(v) && v.is_nan())
  assert_true(sums[2] is @types.Scalar::Float(v) && v.is_nan())
  // min skips the NaN: min(NaN, 1) = 1, min(3, NaN) = 3.
  assert_eq(
    df.select([@expr.col("f").rolling_min(2)]).get_column("f").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Float(1.0), @types.Scalar::Float(3.0)],
  )
  // An all-NaN window leaves the extrema nothing to skip to: null, and the
  // NaN still counted toward min_samples = 1.
  let all_nan = DataFrame::DataFrame([Series::from_floats("f", [nan, nan])])
  assert_eq(
    all_nan
    .select([@expr.col("f").rolling_min(2, min_samples=1)])
    .get_column("f")
    .to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Null],
  )
  // The statistics propagate the NaN even relaxed.
  let mean = all_nan
    .select([@expr.col("f").rolling_mean(2, min_samples=1)])
    .get_column("f")
    .to_scalars()
  assert_true(mean[0] is @types.Scalar::Float(v) && v.is_nan())
}

///|
test "std / variance are exact on a whole-middle pair; one value is null" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  // Windows [1,2] and [2,3]: variance 0.5, std its square root.
  assert_eq(
    df.select([@expr.col("v").rolling_variance(2)]).get_column("v").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Float(0.5), @types.Scalar::Float(0.5)],
  )
  assert_eq(
    df.select([@expr.col("v").rolling_std(2)]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Float(0.5.sqrt()),
      @types.Scalar::Float(0.5.sqrt()),
    ],
  )
  // A one-cell window has no sample denominator — null, not NaN.
  assert_eq(
    df.select([@expr.col("v").rolling_std(1)]).get_column("v").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Null, @types.Scalar::Null],
  )
}

///|
test "median averages the two middles, overflowing halves first" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 4])])
  assert_eq(
    df.select([@expr.col("v").rolling_median(2)]).get_column("v").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Float(1.5), @types.Scalar::Float(3.0)],
  )
  // Two near-Double-max middles overflow their sum; the median halves
  // first and stays finite.
  let huge = 1.7e308
  let big = DataFrame::DataFrame([Series::from_floats("f", [huge, huge])])
  assert_eq(
    big.select([@expr.col("f").rolling_median(2)]).get_column("f").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Float(huge)],
  )
}

///|
test "the extrema fold non-monotonic windows, Int and Float" {
  // Down-and-up so every comparison branch runs: a later smaller cell (the
  // min's `v < b`), a later larger one (the max's `v > b`), and the
  // keep-the-accumulator arms.
  let df = DataFrame::DataFrame([Series::from_ints("v", [5, 1, 3])])
  assert_eq(
    df
    .select([@expr.col("v").rolling_min(2, min_samples=1)])
    .get_column("v")
    .to_scalars(),
    [@types.Scalar::Int(5), @types.Scalar::Int(1), @types.Scalar::Int(1)],
  )
  assert_eq(
    df
    .select([@expr.col("v").rolling_max(2, min_samples=1)])
    .get_column("v")
    .to_scalars(),
    [@types.Scalar::Int(5), @types.Scalar::Int(5), @types.Scalar::Int(3)],
  )
  let f = DataFrame::DataFrame([Series::from_floats("f", [4.0, 2.0, 3.0])])
  assert_eq(
    f
    .select([@expr.col("f").rolling_min(2, min_samples=1)])
    .get_column("f")
    .to_scalars(),
    [
      @types.Scalar::Float(4.0),
      @types.Scalar::Float(2.0),
      @types.Scalar::Float(2.0),
    ],
  )
  assert_eq(
    f
    .select([@expr.col("f").rolling_max(2, min_samples=1)])
    .get_column("f")
    .to_scalars(),
    [
      @types.Scalar::Float(4.0),
      @types.Scalar::Float(4.0),
      @types.Scalar::Float(3.0),
    ],
  )
}

///|
test "the Float statistics over clean and odd windows" {
  // A clean sum (no NaN anywhere), an odd-width median (the middle cell,
  // not the two-middles average), and the NaN propagation through std and
  // median.
  let f = DataFrame::DataFrame([Series::from_floats("f", [1.0, 2.0, 3.0])])
  assert_eq(
    f
    .select([@expr.col("f").rolling_sum(3, min_samples=1)])
    .get_column("f")
    .to_scalars(),
    [
      @types.Scalar::Float(1.0),
      @types.Scalar::Float(3.0),
      @types.Scalar::Float(6.0),
    ],
  )
  assert_eq(
    f
    .select([@expr.col("f").rolling_median(3, min_samples=1)])
    .get_column("f")
    .to_scalars(),
    [
      @types.Scalar::Float(1.0),
      @types.Scalar::Float(1.5),
      @types.Scalar::Float(2.0),
    ],
  )
  let nan : Double = @double.not_a_number
  let with_nan = DataFrame::DataFrame([
    Series::from_floats("f", [1.0, nan, 3.0]),
  ])
  let std = with_nan
    .select([@expr.col("f").rolling_std(3, min_samples=1)])
    .get_column("f")
    .to_scalars()
  assert_true(std[1] is @types.Scalar::Float(v) && v.is_nan())
  let med = with_nan
    .select([@expr.col("f").rolling_median(3, min_samples=1)])
    .get_column("f")
    .to_scalars()
  assert_true(med[1] is @types.Scalar::Float(v) && v.is_nan())
}

///|
test "the family is numeric-only, each member raising with its name" {
  let df = DataFrame::DataFrame([Series::from_strings("s", ["a", "b"])])
  let verbs : Array[@expr.Expr] = [
    @expr.col("s").rolling_sum(2),
    @expr.col("s").rolling_mean(2),
    @expr.col("s").rolling_min(2),
    @expr.col("s").rolling_max(2),
    @expr.col("s").rolling_std(2),
    @expr.col("s").rolling_variance(2),
    @expr.col("s").rolling_median(2),
  ]
  for e in verbs {
    assert_true(
      (Ok(df.select([e.with_alias("x")])) catch { e2 => Err(e2) })
      is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
    )
  }
}

///|
test "window and min_samples are validated at evaluation" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [1, 2, 3])])
  assert_true(
    (Ok(df.select([@expr.col("v").rolling_sum(0)])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(df.select([@expr.col("v").rolling_sum(3, min_samples=0)])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(df.select([@expr.col("v").rolling_sum(3, min_samples=4)])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
