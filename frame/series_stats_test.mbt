// Blackbox tests for Series reductions in `series_stats.mbt`.

// ── count ────────────────────────────────────────────────────────────

///|
test "count is non-null count" {
  // Mixed.
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None])
  assert_eq(s.count(), 2)
  // No nulls.
  assert_eq(Series::from_ints("x", [1, 2, 3]).count(), 3)
  // All-null.
  assert_eq(Series::from_int_options("x", [None, None]).count(), 0)
  // Empty.
  assert_eq(Series::from_ints("x", []).count(), 0)
}

// ── sum ──────────────────────────────────────────────────────────────

///|
test "sum on Int series ignores nulls" {
  let s = Series::from_int_options("x", [Some(1), None, Some(2), Some(3), None])
  assert_eq(s.sum(), Ok(@types.Scalar::Int(6)))
}

///|
test "sum on Float series ignores nulls" {
  let s = Series::from_float_options("x", [Some(1.5), None, Some(2.5)])
  assert_eq(s.sum(), Ok(@types.Scalar::Float(4.0)))
}

///|
test "sum on empty / all-null numeric is the additive identity" {
  assert_eq(Series::from_ints("x", []).sum(), Ok(@types.Scalar::Int(0)))
  assert_eq(
    Series::from_int_options("x", [None, None]).sum(),
    Ok(@types.Scalar::Int(0)),
  )
  assert_eq(Series::from_floats("x", []).sum(), Ok(@types.Scalar::Float(0.0)))
  assert_eq(
    Series::from_float_options("x", [None]).sum(),
    Ok(@types.Scalar::Float(0.0)),
  )
}

///|
test "sum on Bool / String is TypeMismatch" {
  assert_true(Series::from_bools("x", [true]).sum() is Err(TypeMismatch(_)))
  assert_true(Series::from_strings("x", ["a"]).sum() is Err(TypeMismatch(_)))
}

// ── mean ─────────────────────────────────────────────────────────────

///|
test "mean on Int series promotes to Float" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(s.mean(), Ok((2.0 : Float)))
}

///|
test "mean on Float series ignores nulls" {
  let s = Series::from_float_options("x", [Some(1.0), Some(2.0), None])
  assert_eq(s.mean(), Ok((1.5 : Float)))
}

///|
test "mean on empty / all-null numeric is InvalidOperation" {
  assert_true(Series::from_ints("x", []).mean() is Err(InvalidOperation(_)))
  assert_true(
    Series::from_int_options("x", [None, None]).mean()
    is Err(InvalidOperation(_)),
  )
  assert_true(Series::from_floats("x", []).mean() is Err(InvalidOperation(_)))
  assert_true(
    Series::from_float_options("x", [None]).mean() is Err(InvalidOperation(_)),
  )
}

///|
test "mean on Bool / String is TypeMismatch" {
  assert_true(
    Series::from_bools("x", [true, false]).mean() is Err(TypeMismatch(_)),
  )
  assert_true(Series::from_strings("x", ["a"]).mean() is Err(TypeMismatch(_)))
}

// ── min / max ────────────────────────────────────────────────────────

///|
test "min / max on Int series ignore nulls" {
  let s = Series::from_int_options("x", [Some(3), None, Some(1), Some(2), None])
  assert_eq(s.min(), Ok(@types.Scalar::Int(1)))
  assert_eq(s.max(), Ok(@types.Scalar::Int(3)))
}

///|
test "min / max on Float series ignore nulls" {
  let s = Series::from_float_options("x", [Some(2.5), None, Some(0.5)])
  assert_eq(s.min(), Ok(@types.Scalar::Float(0.5)))
  assert_eq(s.max(), Ok(@types.Scalar::Float(2.5)))
}

///|
test "min / max on Bool series follow false < true" {
  let mixed = Series::from_bools("x", [true, false, true])
  assert_eq(mixed.min(), Ok(@types.Scalar::Bool(false)))
  assert_eq(mixed.max(), Ok(@types.Scalar::Bool(true)))
  // Uniform inputs: best stays at the first cell, no `<` / `>` updates.
  let all_true = Series::from_bools("x", [true, true])
  assert_eq(all_true.min(), Ok(@types.Scalar::Bool(true)))
  assert_eq(all_true.max(), Ok(@types.Scalar::Bool(true)))
  let all_false = Series::from_bools("x", [false, false])
  assert_eq(all_false.min(), Ok(@types.Scalar::Bool(false)))
  assert_eq(all_false.max(), Ok(@types.Scalar::Bool(false)))
}

///|
test "min / max on String series use lexicographic order" {
  let s = Series::from_string_options("x", [
    Some("banana"),
    None,
    Some("apple"),
    Some("cherry"),
  ])
  assert_eq(s.min(), Ok(@types.Scalar::String("apple")))
  assert_eq(s.max(), Ok(@types.Scalar::String("cherry")))
}

///|
test "min / max on empty / all-null return Null across every dtype" {
  // Every (op, dtype) pair must hit its dedicated `None` branch.
  // Int.
  assert_eq(Series::from_ints("x", []).min(), Ok(@types.Scalar::Null))
  assert_eq(Series::from_ints("x", []).max(), Ok(@types.Scalar::Null))
  assert_eq(
    Series::from_int_options("x", [None, None]).min(),
    Ok(@types.Scalar::Null),
  )
  assert_eq(
    Series::from_int_options("x", [None, None]).max(),
    Ok(@types.Scalar::Null),
  )
  // Float.
  assert_eq(Series::from_floats("x", []).min(), Ok(@types.Scalar::Null))
  assert_eq(Series::from_floats("x", []).max(), Ok(@types.Scalar::Null))
  assert_eq(
    Series::from_float_options("x", [None]).min(),
    Ok(@types.Scalar::Null),
  )
  assert_eq(
    Series::from_float_options("x", [None]).max(),
    Ok(@types.Scalar::Null),
  )
  // Bool.
  assert_eq(Series::from_bools("x", []).min(), Ok(@types.Scalar::Null))
  assert_eq(Series::from_bools("x", []).max(), Ok(@types.Scalar::Null))
  assert_eq(
    Series::from_bool_options("x", [None]).min(),
    Ok(@types.Scalar::Null),
  )
  assert_eq(
    Series::from_bool_options("x", [None]).max(),
    Ok(@types.Scalar::Null),
  )
  // String.
  assert_eq(Series::from_strings("x", []).min(), Ok(@types.Scalar::Null))
  assert_eq(Series::from_strings("x", []).max(), Ok(@types.Scalar::Null))
  assert_eq(
    Series::from_string_options("x", [None]).min(),
    Ok(@types.Scalar::Null),
  )
  assert_eq(
    Series::from_string_options("x", [None]).max(),
    Ok(@types.Scalar::Null),
  )
}

///|
test "min on Float NaN does not displace a non-NaN best" {
  let nan : Float = @float.not_a_number
  // First cell is NaN — best initialises to NaN, then 1.0 < NaN is false
  // (IEEE 754), so best stays NaN. Document the corner via behaviour.
  let nan_first = Series::from_floats("x", [nan, 1.0])
  // `<` against NaN is `false`, so 1.0 cannot displace NaN as the
  // current best; the function returns the first NaN encountered.
  assert_true(
    match nan_first.min().unwrap() {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  // Non-NaN first → NaN cells cannot displace it (NaN < x is false).
  let nan_later = Series::from_floats("x", [1.0, nan, 0.5])
  assert_eq(nan_later.min(), Ok(@types.Scalar::Float(0.5)))
  assert_eq(nan_later.max(), Ok(@types.Scalar::Float(1.0)))
}

// ── unique_count ─────────────────────────────────────────────────────

///|
test "unique_count counts distinct non-null values" {
  let s = Series::from_int_options("x", [
    Some(1),
    None,
    Some(2),
    Some(1),
    Some(3),
    None,
  ])
  assert_eq(s.unique_count(), 3)
}

///|
test "unique_count is 0 for empty / all-null series" {
  assert_eq(Series::from_ints("x", []).unique_count(), 0)
  assert_eq(Series::from_int_options("x", [None, None, None]).unique_count(), 0)
}

///|
test "unique_count works on every dtype" {
  assert_eq(Series::from_floats("x", [1.0, 1.0, 2.0]).unique_count(), 2)
  assert_eq(
    Series::from_bools("x", [true, false, true, false]).unique_count(),
    2,
  )
  assert_eq(Series::from_strings("x", ["a", "b", "a", "c"]).unique_count(), 3)
}

///|
test "unique_count collapses all NaN Float cells into a single bucket" {
  let nan : Float = @float.not_a_number
  let s = Series::from_floats("x", [nan, nan, 1.0])
  assert_eq(s.unique_count(), 2)
}

// ── describe ─────────────────────────────────────────────────────────

///|
test "describe on Int series exposes count/null_count/unique_count/mean/min/max" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), Some(5), None])
  let df = s.describe()
  // Schema: 6 columns in fixed order.
  assert_eq(df.columns(), [
    "count", "null_count", "unique_count", "mean", "min", "max",
  ])
  assert_eq(df.shape(), (1, 6))
  // count/null_count/unique_count.
  assert_eq(df.get(0, "count"), Ok(@types.Scalar::Int(3)))
  assert_eq(df.get(0, "null_count"), Ok(@types.Scalar::Int(2)))
  assert_eq(df.get(0, "unique_count"), Ok(@types.Scalar::Int(3)))
  // mean = (1+3+5)/3 = 3.0 (promoted to Float).
  assert_eq(df.get(0, "mean"), Ok(@types.Scalar::Float(3.0)))
  // min/max preserve the source dtype.
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Int(1)))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Int(5)))
  // min/max columns are Int, not Float.
  assert_eq(df.get_column("min").unwrap().dtype(), @types.DataType::Int)
}

///|
test "describe on Float series uses Float for mean, min, max" {
  let s = Series::from_float_options("x", [
    Some(1.0),
    None,
    Some(2.0),
    Some(3.0),
  ])
  let df = s.describe()
  assert_eq(df.columns(), [
    "count", "null_count", "unique_count", "mean", "min", "max",
  ])
  assert_eq(df.get(0, "count"), Ok(@types.Scalar::Int(3)))
  assert_eq(df.get(0, "mean"), Ok(@types.Scalar::Float(2.0)))
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Float(1.0)))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Float(3.0)))
}

///|
test "describe on empty Int series sets stats / mean / min / max to Null" {
  let s = Series::from_ints("x", [])
  let df = s.describe()
  assert_eq(df.get(0, "count"), Ok(@types.Scalar::Int(0)))
  assert_eq(df.get(0, "null_count"), Ok(@types.Scalar::Int(0)))
  assert_eq(df.get(0, "unique_count"), Ok(@types.Scalar::Int(0)))
  // mean errors on empty → encoded as a null cell.
  assert_eq(df.get(0, "mean"), Ok(@types.Scalar::Null))
  // min/max on empty return Scalar::Null → null cells with the source dtype.
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Null))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Null))
  assert_eq(df.get_column("min").unwrap().dtype(), @types.DataType::Int)
}

///|
test "describe on all-null Float series mirrors the empty path" {
  let s = Series::from_float_options("x", [None, None])
  let df = s.describe()
  assert_eq(df.get(0, "count"), Ok(@types.Scalar::Int(0)))
  assert_eq(df.get(0, "null_count"), Ok(@types.Scalar::Int(2)))
  assert_eq(df.get(0, "mean"), Ok(@types.Scalar::Null))
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Null))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Null))
  // Null cell still typed as Float at the column level.
  assert_eq(df.get_column("min").unwrap().dtype(), @types.DataType::Float)
}

///|
test "describe on Bool series omits mean and uses Bool min/max" {
  let s = Series::from_bool_options("x", [
    Some(true),
    None,
    Some(false),
    Some(true),
  ])
  let df = s.describe()
  assert_eq(df.columns(), ["count", "null_count", "unique_count", "min", "max"])
  assert_eq(df.shape(), (1, 5))
  assert_eq(df.get(0, "count"), Ok(@types.Scalar::Int(3)))
  assert_eq(df.get(0, "null_count"), Ok(@types.Scalar::Int(1)))
  assert_eq(df.get(0, "unique_count"), Ok(@types.Scalar::Int(2)))
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Bool(false)))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Bool(true)))
}

///|
test "describe on all-null Bool series produces typed-null min/max" {
  let s = Series::from_bool_options("x", [None, None])
  let df = s.describe()
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Null))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Null))
  assert_eq(df.get_column("min").unwrap().dtype(), @types.DataType::Bool)
}

///|
test "describe on String series omits mean and uses String min/max" {
  let s = Series::from_string_options("x", [
    Some("banana"),
    None,
    Some("apple"),
    Some("cherry"),
  ])
  let df = s.describe()
  assert_eq(df.columns(), ["count", "null_count", "unique_count", "min", "max"])
  assert_eq(df.get(0, "count"), Ok(@types.Scalar::Int(3)))
  assert_eq(df.get(0, "unique_count"), Ok(@types.Scalar::Int(3)))
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::String("apple")))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::String("cherry")))
}

///|
test "describe on all-null String series produces typed-null min/max" {
  let s = Series::from_string_options("x", [None])
  let df = s.describe()
  assert_eq(df.get(0, "min"), Ok(@types.Scalar::Null))
  assert_eq(df.get(0, "max"), Ok(@types.Scalar::Null))
  assert_eq(df.get_column("min").unwrap().dtype(), @types.DataType::String)
}
