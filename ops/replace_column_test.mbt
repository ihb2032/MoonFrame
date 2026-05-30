// Blackbox tests for `@ops.replace_column`.
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
fn replace_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("b", ["x", "y", "z"]),
  ]).unwrap()
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "replace_column swaps in a same-dtype column without changing position" {
  let df = replace_df()
  let fresh = @frame.Series::from_ints("a", [10, 20, 30])
  let out = replace_column(df, "a", fresh).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), df.columns())
  assert_eq(out.ncols(), df.ncols())
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(10)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(30)))
}

///|
test "replace_column allows cross-dtype replacement (Int → Float)" {
  let df = replace_df()
  let fresh = @frame.Series::from_floats("ignored", [
    (0.5 : Double),
    (1.5 : Double),
    (2.5 : Double),
  ])
  let out = replace_column(df, "a", fresh).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Target name "a" wins over the series's own name "ignored".
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.get_column("a").unwrap().name(), "a")
  // Dtype now follows the new data.
  assert_eq(out.get_column("a").unwrap().dtype(), @types.DataType::Float)
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Float(1.5)))
  // The schema's field at position 0 now also has dtype Float.
  assert_eq(out.schema().field_at(0).unwrap().dtype(), @types.DataType::Float)
}

///|
test "replace_column on a non-first position works the same" {
  let df = replace_df()
  let fresh = @frame.Series::from_bools("b", [true, false, true])
  let out = replace_column(df, "b", fresh).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.get_column("b").unwrap().dtype(), @types.DataType::Bool)
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Bool(true)))
}

///|
test "replace_column preserves nulls in the new series" {
  let df = replace_df()
  let fresh = @frame.Series::from_int_options("a", [Some(1), None, Some(3)])
  let out = replace_column(df, "a", fresh).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("a").unwrap().null_count(), 1)
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Null))
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "replace_column on an unknown name returns ColumnNotFound" {
  let df = replace_df()
  let fresh = @frame.Series::from_ints("z", [1, 2, 3])
  assert_eq(
    replace_column(df, "z", fresh),
    Err(@types.DataError::ColumnNotFound("z")),
  )
}

///|
test "replace_column with a length-mismatched series returns LengthMismatch" {
  let df = replace_df() // nrows = 3
  let too_short = @frame.Series::from_ints("a", [1, 2])
  assert_eq(
    replace_column(df, "a", too_short),
    Err(@types.DataError::LengthMismatch),
  )
}
