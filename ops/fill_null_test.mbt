// Blackbox tests for `@ops.fill_null`.
//
// Invariants asserted on every successful fill:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) result.schema() == df.schema() — fill is in-place at the cell
//       level; dtypes / nullability declarations are preserved
//   (3) result.columns() == df.columns() — column order + names stable
//   (4) result.shape() == df.shape() — fill is a per-cell rewrite,
//       not a row or column transform
//   (5) the target column has zero nulls after the fill

///|
/// Three-column fixture: each dtype contributes a null-bearing column
/// so the type-specific fill paths can each be exercised against a
/// realistic frame.
fn fill_null_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None, Some(3), None]),
    @frame.Series::from_float_options("b", [
      Some((1.5 : Float)),
      Some((2.5 : Float)),
      None,
      None,
    ]),
    @frame.Series::from_string_options("s", [
      Some("w"),
      None,
      Some("y"),
      Some("z"),
    ]),
  ]).unwrap()
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "fill_null on an Int column replaces nulls and leaves other columns untouched" {
  let df = fill_null_df()
  let out = fill_null(df, "a", @types.Scalar::Int(0)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.shape(), df.shape())
  // Target column is now null-free.
  assert_eq(out.get_column("a").unwrap().null_count(), 0)
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(3, "a"), Ok(@types.Scalar::Int(0)))
  // Other columns are byte-for-byte identical (nulls in "b" and "s"
  // must still be null).
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::Null))
}

///|
test "fill_null on a Float column replaces nulls with the given Float" {
  let df = fill_null_df()
  let out = fill_null(df, "b", @types.Scalar::Float(0.0)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("b").unwrap().null_count(), 0)
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Float(2.5)))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Float(0.0)))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Float(0.0)))
  // "a" untouched.
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Null))
}

///|
test "fill_null on a String column replaces nulls with the given String" {
  let df = fill_null_df()
  let out = fill_null(df, "s", @types.Scalar::String("?")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("s").unwrap().null_count(), 0)
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("w")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("?")))
  assert_eq(out.get(2, "s"), Ok(@types.Scalar::String("y")))
  assert_eq(out.get(3, "s"), Ok(@types.Scalar::String("z")))
}

///|
test "fill_null on a Bool column replaces nulls with the given Bool" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_bool_options("flag", [Some(true), None, None]),
  ]).unwrap()
  let out = fill_null(df, "flag", @types.Scalar::Bool(false)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("flag").unwrap().null_count(), 0)
  assert_eq(out.get(0, "flag"), Ok(@types.Scalar::Bool(true)))
  assert_eq(out.get(1, "flag"), Ok(@types.Scalar::Bool(false)))
  assert_eq(out.get(2, "flag"), Ok(@types.Scalar::Bool(false)))
}

///|
test "fill_null on a column with no nulls is a no-op identity" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ]).unwrap()
  let out = fill_null(df, "a", @types.Scalar::Int(99)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Same shape, same values, structurally equal to the input.
  assert_eq(out, df)
}

///|
test "fill_null on a 0-row frame leaves it as a 0-row frame" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::String),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = fill_null(df, "a", @types.Scalar::Int(0)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "fill_null rejects an unknown column with ColumnNotFound" {
  let df = fill_null_df()
  assert_eq(
    fill_null(df, "missing", @types.Scalar::Int(0)),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The input is unchanged and still well-formed.
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "fill_null rejects a Null fill value with TypeMismatch" {
  let df = fill_null_df()
  // The diagnostic comes from Series::fill_null; pattern-match on the
  // variant rather than pinning the message text.
  assert_true(fill_null(df, "a", @types.Scalar::Null) is Err(TypeMismatch(_)))
}

///|
test "fill_null rejects dtype-mismatched fill on an Int column" {
  let df = fill_null_df()
  // Int column "a" — Float fill must fail with TypeMismatch.
  assert_true(
    fill_null(df, "a", @types.Scalar::Float(0.0)) is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched fill on a Float column" {
  let df = fill_null_df()
  // Float column "b" — Int fill must fail (no implicit promotion at
  // the DataFrame layer).
  assert_true(fill_null(df, "b", @types.Scalar::Int(0)) is Err(TypeMismatch(_)))
}

///|
test "fill_null rejects dtype-mismatched fill on a String column" {
  let df = fill_null_df()
  // String column "s" — Bool fill must fail.
  assert_true(
    fill_null(df, "s", @types.Scalar::Bool(true)) is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null missing-column error takes precedence over a type mismatch" {
  let df = fill_null_df()
  // Even though the value would be a dtype mismatch on every column,
  // the column-lookup check runs first.
  assert_eq(
    fill_null(df, "missing", @types.Scalar::Bool(true)),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

// ── Cross-API equivalence with Series::fill_null ─────────────────────

///|
test "fill_null on a single column matches Series::fill_null cell-by-cell" {
  let df = fill_null_df()
  let by_op = fill_null(df, "a", @types.Scalar::Int(7)).unwrap()
  let by_series = df
    .get_column("a")
    .unwrap()
    .fill_null(@types.Scalar::Int(7))
    .unwrap()
  for i in 0..<df.nrows() {
    assert_eq(by_op.get(i, "a"), by_series.get(i))
  }
}
