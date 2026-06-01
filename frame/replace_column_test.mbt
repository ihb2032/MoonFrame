// Blackbox tests for `DataFrame::replace_column`.
//
// Invariants asserted on every successful replace:
//   (1) check_invariants() == Ok(())
//   (2) result.ncols() == original.ncols() (in-place replacement)
//   (3) result.columns() == original.columns() (positional + name order
//       preserved, because the target name wins over the series name)
//   (4) the replaced column carries the new data and (possibly new)
//       dtype

///|
/// Two-column, three-row base frame. Each test then builds its own
/// replacement series — that's the actual subject under test.
fn replace_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "replace_column swaps in a same-dtype column without changing position" {
  let df = replace_df()
  let fresh = Series::from_ints("a", [10, 20, 30])
  let out = df.replace_column("a", fresh)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), df.columns())
  assert_eq(out.ncols(), df.ncols())
  assert_eq(out.get(0, "a"), @types.Scalar::Int(10))
  assert_eq(out.get(2, "a"), @types.Scalar::Int(30))
}

///|
test "replace_column allows cross-dtype replacement (Int → Float)" {
  let df = replace_df()
  let fresh = Series::from_floats("ignored", [
    (0.5 : Double),
    (1.5 : Double),
    (2.5 : Double),
  ])
  let out = df.replace_column("a", fresh)
  assert_eq(out.check_invariants(), Ok(()))
  // Target name "a" wins over the series's own name "ignored".
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.get_column("a").name(), "a")
  // Dtype now follows the new data.
  assert_eq(out.get_column("a").dtype(), @types.DataType::Float)
  assert_eq(out.get(1, "a"), @types.Scalar::Float(1.5))
  // The schema's field at position 0 now also has dtype Float.
  assert_eq(out.schema().field_at(0).dtype(), @types.DataType::Float)
}

///|
test "replace_column on a non-first position works the same" {
  let df = replace_df()
  let fresh = Series::from_bools("b", [true, false, true])
  let out = df.replace_column("b", fresh)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(out.get(0, "b"), @types.Scalar::Bool(true))
}

///|
test "replace_column preserves nulls in the new series" {
  let df = replace_df()
  let fresh = Series::from_int_options("a", [Some(1), None, Some(3)])
  let out = df.replace_column("a", fresh)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("a").null_count(), 1)
  assert_eq(out.get(1, "a"), @types.Scalar::Null)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "replace_column on an unknown name returns ColumnNotFound" {
  let df = replace_df()
  let fresh = Series::from_ints("z", [1, 2, 3])
  assert_eq(
    try? df.replace_column("z", fresh),
    Err(@types.DataError::ColumnNotFound("z")),
  )
}

///|
test "replace_column with a length-mismatched series returns LengthMismatch" {
  let df = replace_df() // nrows = 3
  let too_short = Series::from_ints("a", [1, 2])
  assert_eq(
    try? df.replace_column("a", too_short),
    Err(@types.DataError::LengthMismatch),
  )
}
