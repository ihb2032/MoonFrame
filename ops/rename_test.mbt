// Blackbox tests for `@ops.rename`.
//
// Invariants asserted on every successful rename:
//   (1) check_invariants() == Ok(())
//   (2) result.columns().length() == original.ncols() (no col added/lost)
//   (3) renamed columns hold the same data (no permutation)
//   (4) the renamed column's series.name() matches the new name (so the
//       schema, the columns vector, and the series-level name agree)

///|
/// Two-column fixture: rename never needs to observe nulls, so a
/// concise Int + String pair keeps the diff small.
fn rename_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("b", ["x", "y", "z"]),
  ]).unwrap()
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "rename renames a single column without changing position" {
  let df = rename_df()
  let out = rename(df, [("a", "alpha")]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["alpha", "b"])
  assert_eq(out.ncols(), df.ncols())
  // Data and dtype follow the new name.
  assert_eq(out.get(0, "alpha"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get_column("alpha").unwrap().dtype(), @types.DataType::Int)
  // The renamed series also reports the new name.
  assert_eq(out.get_column("alpha").unwrap().name(), "alpha")
}

///|
test "rename applies multiple mappings in input order" {
  let df = rename_df()
  let out = rename(df, [("a", "A"), ("b", "B")]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["A", "B"])
}

///|
test "rename with empty mapping is a structural identity" {
  let df = rename_df()
  let out = rename(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "rename allows swapping two column names via a temporary" {
  // "a" <-> "b": stage to a fresh name, then rename pieces back.
  // This proves the impl correctly threads sequential renames.
  let df = rename_df()
  let out = rename(df, [("a", "_tmp"), ("b", "a"), ("_tmp", "b")]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["b", "a"])
  // Underlying data did NOT permute — only names did.
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::String("x")))
}

///|
test "rename to the same name is a no-op that still validates existence" {
  let df = rename_df()
  let out = rename(df, [("a", "a")]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

// ── Property: rename then rename-back is identity ────────────────────

///|
test "rename then rename-back recovers the original frame" {
  let df = rename_df()
  let forward = rename(df, [("a", "alpha")]).unwrap()
  let back = rename(forward, [("alpha", "a")]).unwrap()
  assert_eq(back.check_invariants(), Ok(()))
  assert_eq(back, df)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "rename rejects unknown source columns with ColumnNotFound" {
  let df = rename_df()
  assert_eq(
    rename(df, [("missing", "x")]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "rename rejects collisions with another existing column" {
  let df = rename_df()
  // Renaming "a" to "b" would collide with the existing "b".
  assert_eq(
    rename(df, [("a", "b")]),
    Err(@types.DataError::DuplicateColumn("b")),
  )
}

///|
test "rename rejects a mapping that introduces a duplicate among new names" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1]),
    @frame.Series::from_ints("b", [2]),
    @frame.Series::from_ints("c", [3]),
  ]).unwrap()
  // Both "a" and "b" map to "z" — second mapping collides with the
  // freshly-renamed first column.
  assert_eq(
    rename(df, [("a", "z"), ("b", "z")]),
    Err(@types.DataError::DuplicateColumn("z")),
  )
}
