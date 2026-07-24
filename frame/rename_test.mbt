// Blackbox tests for `DataFrame::rename` and its callable form `rename_with`.
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
  DataFrame::DataFrame([
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
    Ok(df.rename([("missing", "x")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "rename rejects collisions with another existing column" {
  let df = rename_df()
  // Renaming "a" to "b" would collide with the existing "b".
  assert_eq(
    Ok(df.rename([("a", "b")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("b")),
  )
}

///|
test "rename rejects a mapping that introduces a duplicate among new names" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1]),
    Series::from_ints("b", [2]),
    Series::from_ints("c", [3]),
  ])
  // Both "a" and "b" map to "z" — second mapping collides with the
  // freshly-renamed first column.
  assert_eq(
    Ok(df.rename([("a", "z"), ("b", "z")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("z")),
  )
}

// ── Callable form: rename_with ───────────────────────────────────────

///|
test "rename_with renames every column through the function" {
  let df = rename_df()
  let out = df.rename_with(name => "col_\{name}")
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["col_a", "col_b"])
  assert_eq(out.ncols(), df.ncols())
  // Data and dtype follow the new names; only the names changed.
  assert_eq(out.item(0, "col_a"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "col_b"), @types.Scalar::String("x"))
  assert_eq(out.get_column("col_a").name(), "col_a")
}

///|
test "rename_with the identity function is a structural no-op" {
  let df = rename_df()
  let out = df.rename_with(name => name)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "rename_with rejects a function that collapses two columns to one name" {
  let df = rename_df()
  // Every column maps to "same" — the rebuilding `Schema::Schema` rejects the
  // duplicate.
  assert_eq(
    Ok(df.rename_with(_ => "same")) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("same")),
  )
}

// ── Declared schema metadata rides along ─────────────────────────────

///|
/// The same two columns as `rename_df`, but built through `from_rows` under a
/// caller-supplied schema that declares `a` non-nullable. A `DataFrame::DataFrame`
/// fixture cannot carry such a flag — its derived schema names every field
/// with the `Field` constructor default (`nullable = true`) — so the
/// metadata-preservation tests need this second fixture.
fn rename_declared_df() -> DataFrame raise @types.DataError {
  DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int, nullable=false),
      @types.Field::Field("b", @types.DataType::String),
    ]),
    [
      [@types.Scalar::Int(1), @types.Scalar::String("x")],
      [@types.Scalar::Int(2), @types.Scalar::String("y")],
    ],
  )
}

///|
test "rename carries the renamed field's metadata onto the new name" {
  let df = rename_declared_df()
  let out = df.rename([("a", "alpha")])
  assert_eq(out.check_invariants(), Ok(()))
  // Only the name changed: the dtype and the declared `nullable = false`
  // rode along through `Field::rename`.
  assert_eq(
    out.schema().field("alpha"),
    @types.Field::Field("alpha", @types.DataType::Int, nullable=false),
  )
  // The untouched column keeps its own (defaulted) flag.
  assert_true(out.schema().field("b").nullable())
}

///|
test "rename with an empty mapping preserves a declared schema" {
  let df = rename_declared_df()
  let out = df.rename([])
  assert_eq(out.check_invariants(), Ok(()))
  // `DataFrame`'s derived `Eq` includes the schema, so this pins the no-op
  // as a *full* identity, metadata included.
  assert_eq(out, df)
  assert_false(out.schema().field("a").nullable())
}

///|
test "rename to the same name preserves a declared schema" {
  let df = rename_declared_df()
  let out = df.rename([("a", "a")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
  assert_false(out.schema().field("a").nullable())
}

///|
test "rename_with carries every field's metadata through the transform" {
  let df = rename_declared_df()
  let out = df.rename_with(name => "col_\{name}")
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["col_a", "col_b"])
  assert_false(out.schema().field("col_a").nullable())
  assert_true(out.schema().field("col_b").nullable())
}

///|
test "rename_with the identity function preserves a declared schema" {
  let df = rename_declared_df()
  let out = df.rename_with(name => name)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
  assert_false(out.schema().field("a").nullable())
}
