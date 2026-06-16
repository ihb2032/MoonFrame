// Blackbox tests for `DataFrame::rename`.
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
fn rename_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "rename renames a single column without changing position" {
  let df = rename_df()
  let out = df.rename([("a", "alpha")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["alpha", "b"])
  assert_eq(out.ncols(), df.ncols())
  // Data and dtype follow the new name.
  assert_eq(out.item(0, "alpha"), @types.Scalar::Int(1))
  assert_eq(out.get_column("alpha").dtype(), @types.DataType::Int)
  // The renamed series also reports the new name.
  assert_eq(out.get_column("alpha").name(), "alpha")
}

///|
test "rename applies multiple mappings in input order" {
  let df = rename_df()
  let out = df.rename([("a", "A"), ("b", "B")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["A", "B"])
}

///|
test "rename with empty mapping is a structural identity" {
  let df = rename_df()
  let out = df.rename([])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "rename allows swapping two column names via a temporary" {
  // "a" <-> "b": stage to a fresh name, then rename pieces back.
  // This proves the impl correctly threads sequential renames.
  let df = rename_df()
  let out = df.rename([("a", "_tmp"), ("b", "a"), ("_tmp", "b")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["b", "a"])
  // Underlying data did NOT permute — only names did.
  assert_eq(out.item(0, "b"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "a"), @types.Scalar::String("x"))
}

///|
test "rename to the same name is a no-op that still validates existence" {
  let df = rename_df()
  let out = df.rename([("a", "a")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

// ── Property: rename then rename-back is identity ────────────────────

///|
test "rename then rename-back recovers the original frame" {
  let df = rename_df()
  let forward = df.rename([("a", "alpha")])
  let back = forward.rename([("alpha", "a")])
  assert_eq(back.check_invariants(), Ok(()))
  assert_eq(back, df)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "rename rejects unknown source columns with ColumnNotFound" {
  let df = rename_df()
  assert_eq(
    try? df.rename([("missing", "x")]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "rename rejects collisions with another existing column" {
  let df = rename_df()
  // Renaming "a" to "b" would collide with the existing "b".
  assert_eq(
    try? df.rename([("a", "b")]),
    Err(@types.DataError::DuplicateColumn("b")),
  )
}

///|
test "rename rejects a mapping that introduces a duplicate among new names" {
  let df = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_ints("b", [2]),
    Series::from_ints("c", [3]),
  ])
  // Both "a" and "b" map to "z" — second mapping collides with the
  // freshly-renamed first column.
  assert_eq(
    try? df.rename([("a", "z"), ("b", "z")]),
    Err(@types.DataError::DuplicateColumn("z")),
  )
}
