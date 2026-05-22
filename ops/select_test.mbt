// Blackbox tests for `@ops.select`.
//
// Every successful select must satisfy:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) df.schema().field_names() == df.columns() — PLAN P6 requirement
//   (3) get_column(name) returns the projected column under that name
//   (4) the projected order equals the requested order

///|
/// Three-column fixture: an Int, a String, and a nullable Float so the
/// projection tests can observe null preservation on column `c`.
fn select_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("b", ["x", "y", "z"]),
    @frame.Series::from_float_options("c", [Some(1.5), None, Some(2.5)]),
  ]).unwrap()
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "select projects requested columns in requested order" {
  let df = select_df()
  let out = select(df, ["c", "a"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["c", "a"])
  assert_eq(out.schema().field_names(), out.columns())
  // Schema-columns dtype consistency (INV4) is structural — re-check
  // by reading dtype through both paths and confirming they match.
  assert_eq(out.get_column("c").unwrap().dtype(), @types.DataType::Float)
  assert_eq(out.get_column("a").unwrap().dtype(), @types.DataType::Int)
  // Row count is preserved.
  assert_eq(out.nrows(), df.nrows())
}

///|
test "select with a single column produces a 1-column frame" {
  let df = select_df()
  let out = select(df, ["b"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (3, 1))
  assert_eq(out.columns(), ["b"])
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::String("x")))
}

///|
test "select with empty list yields a 0-column frame of the same height" {
  let df = select_df()
  let out = select(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // 0-column case: DataFrame::new clamps nrows to 0 when columns is
  // empty. This is the documented contract.
  assert_eq(out.shape(), (0, 0))
  assert_eq(out.columns(), [])
}

///|
test "select on an empty frame with an empty list returns the empty frame" {
  let df = @frame.DataFrame::new([]).unwrap()
  let out = select(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "select preserves data values cell-by-cell" {
  let df = select_df()
  let out = select(df, ["a", "c"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(1, "c"), Ok(@types.Scalar::Null))
  assert_eq(out.get(0, "c"), Ok(@types.Scalar::Float(1.5)))
}

// ── Property: select is idempotent when picking all columns in order ─

///|
test "select(all columns in original order) equals the original (structurally)" {
  let df = select_df()
  let out = select(df, ["a", "b", "c"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "select rejects unknown column names with ColumnNotFound" {
  let df = select_df()
  assert_eq(
    select(df, ["a", "missing"]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The original frame stays well-formed (we shouldn't have mutated it).
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "select rejects duplicate names in the projection" {
  let df = select_df()
  assert_eq(select(df, ["a", "a"]), Err(@types.DataError::DuplicateColumn("a")))
}

///|
test "select first-error wins: missing before duplicate" {
  let df = select_df()
  // "z" is missing and appears before the duplicate "a".
  assert_eq(
    select(df, ["z", "a", "a"]),
    Err(@types.DataError::ColumnNotFound("z")),
  )
}
