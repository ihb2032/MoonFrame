// Blackbox tests for `@ops.drop`.
//
// Invariants asserted on every successful drop:
//   (1) check_invariants() == Ok(())
//   (2) result.columns() preserves the original relative order
//   (3) duplicates in the input list are idempotent (dropping "a" twice
//       is the same as dropping it once)

///|
fn drop_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("b", ["x", "y", "z"]),
    @frame.Series::from_floats("c", [
      (1.5 : Float),
      (2.5 : Float),
      (3.5 : Float),
    ]),
  ]).unwrap()
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "drop removes a single column, preserving the remaining order" {
  let df = drop_df()
  let out = drop(df, ["b"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "c"])
  assert_eq(out.shape(), (3, 2))
  // Data survives in the kept columns.
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(2, "c"), Ok(@types.Scalar::Float(3.5)))
}

///|
test "drop removes multiple columns at once" {
  let df = drop_df()
  let out = drop(df, ["a", "c"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["b"])
}

///|
test "drop with an empty list is a structural identity" {
  let df = drop_df()
  let out = drop(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "drop of every column yields a 0-column frame" {
  let df = drop_df()
  let out = drop(df, ["a", "b", "c"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // 0-column case: DataFrame::new clamps nrows to 0 per the v0.1
  // contract.
  assert_eq(out.shape(), (0, 0))
}

// ── Idempotency property ─────────────────────────────────────────────

///|
test "drop is idempotent under duplicate names in input" {
  let df = drop_df()
  let once = drop(df, ["b"]).unwrap()
  let twice = drop(df, ["b", "b"]).unwrap()
  assert_eq(twice.check_invariants(), Ok(()))
  assert_eq(once, twice)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "drop rejects unknown columns with ColumnNotFound" {
  let df = drop_df()
  assert_eq(
    drop(df, ["missing"]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  assert_eq(drop(df, ["a", "z"]), Err(@types.DataError::ColumnNotFound("z")))
}
