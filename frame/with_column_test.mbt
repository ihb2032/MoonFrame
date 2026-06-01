// Blackbox tests for `DataFrame::with_column`.
//
// Invariants asserted on every successful append:
//   (1) check_invariants() == Ok(())
//   (2) result.ncols() == original.ncols() + 1
//   (3) the new column lives at the rightmost position
//   (4) the new column's data and dtype are preserved verbatim

///|
/// Two-column, three-row base frame. Tests build their own extra
/// series inline since the whole point of with_column is what gets
/// appended.
fn with_col_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "with_column appends a new column on the right" {
  let df = with_col_df()
  let extra = Series::from_floats("c", [
    (1.5 : Double),
    (2.5 : Double),
    (3.5 : Double),
  ])
  let out = df.with_column(extra)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "b", "c"])
  assert_eq(out.ncols(), df.ncols() + 1)
  // The appended column is reachable and untouched.
  assert_eq(out.get_column("c").dtype(), @types.DataType::Float)
  assert_eq(out.get(0, "c"), @types.Scalar::Float(1.5))
  assert_eq(out.get(2, "c"), @types.Scalar::Float(3.5))
}

///|
test "with_column preserves the nulls on the appended series" {
  let df = with_col_df()
  let extra = Series::from_int_options("d", [Some(7), None, Some(9)])
  let out = df.with_column(extra)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("d").null_count(), 1)
  assert_eq(out.get(1, "d"), @types.Scalar::Null)
}

///|
test "with_column on a 0×0 frame accepts a 0-length column" {
  let df = DataFrame::new([])
  let extra = Series::from_ints("x", [])
  let out = df.with_column(extra)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 1))
  assert_eq(out.columns(), ["x"])
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "with_column rejects a name collision with DuplicateColumn" {
  let df = with_col_df()
  let dup = Series::from_ints("a", [9, 8, 7])
  assert_eq(
    try? df.with_column(dup),
    Err(@types.DataError::DuplicateColumn("a")),
  )
}

///|
test "with_column rejects a length mismatch" {
  let df = with_col_df() // nrows = 3
  let too_long = Series::from_ints("c", [1, 2, 3, 4])
  let too_short = Series::from_ints("d", [1, 2])
  assert_eq(
    try? df.with_column(too_long),
    Err(@types.DataError::LengthMismatch),
  )
  assert_eq(
    try? df.with_column(too_short),
    Err(@types.DataError::LengthMismatch),
  )
}

///|
test "with_column on a 0×0 frame rejects a non-empty column with LengthMismatch" {
  let df = DataFrame::new([])
  let nonempty = Series::from_ints("x", [1, 2])
  assert_eq(
    try? df.with_column(nonempty),
    Err(@types.DataError::LengthMismatch),
  )
}
