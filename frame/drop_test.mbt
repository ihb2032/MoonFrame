// Blackbox tests for `DataFrame::drop`.
//
// `drop` takes `Array[Expr]` keys, each resolved to a column name via the
// §0 naming rule (`Expr::output_name`); the `col(name)` keys here also pin
// the historical name-keyed drop behavior, and the aliased key pins the
// output-name resolution that keeps the container open for future selectors.
//
// Invariants asserted on every successful drop:
//   (1) check_invariants() == Ok(())
//   (2) result.columns() preserves the original relative order
//   (3) duplicates in the input list are idempotent (dropping "a" twice
//       is the same as dropping it once)

///|
fn drop_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
    Series::from_floats("c", [(1.5 : Double), (2.5 : Double), (3.5 : Double)]),
  ])
}

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "drop removes a single column, preserving the remaining order" {
  let df = drop_df()
  let out = df.drop([@expr.col("b")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "c"])
  assert_eq(out.shape(), (3, 2))
  // Data survives in the kept columns.
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(2, "c"), @types.Scalar::Float(3.5))
}

///|
test "drop removes multiple columns at once" {
  let df = drop_df()
  let out = df.drop([@expr.col("a"), @expr.col("c")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["b"])
}

///|
test "drop with an empty list is a structural identity" {
  let df = drop_df()
  let out = df.drop([])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "drop of every column yields a 0-column frame" {
  let df = drop_df()
  let out = df.drop([@expr.col("a"), @expr.col("b"), @expr.col("c")])
  assert_eq(out.check_invariants(), Ok(()))
  // 0-column case: DataFrame::DataFrame clamps nrows to 0 per the v0.1
  // contract.
  assert_eq(out.shape(), (0, 0))
}

// ── Output-name resolution (selector-ready container) ────────────────

///|
test "drop resolves each key by output_name, not by the columns it reads" {
  let df = drop_df()
  // An aliased key drops the column named by the alias (`output_name`'s
  // alias-wins rule), regardless of which column the expression references.
  // `col("a").with_alias("b")` therefore drops "b", leaving "a" and "c".
  let out = df.drop([@expr.col("a").with_alias("b")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "c"])
  // A plain `col("b")` drops the same column — the two routes agree.
  assert_eq(out, df.drop([@expr.col("b")]))
}

// ── Idempotency property ─────────────────────────────────────────────

///|
test "drop is idempotent under duplicate keys in input" {
  let df = drop_df()
  let once = df.drop([@expr.col("b")])
  let twice = df.drop([@expr.col("b"), @expr.col("b")])
  assert_eq(twice.check_invariants(), Ok(()))
  assert_eq(once, twice)
}

// ── Error cases ──────────────────────────────────────────────────────

// ── Declared schema metadata ─────────────────────────────────────────

///|
test "drop with an empty list preserves a declared schema" {
  // Built through `from_rows` so the schema carries an explicit
  // `nullable = false`; a `DataFrame::DataFrame` fixture defaults every field to
  // `nullable = true` and so cannot observe the difference.
  let df = DataFrame::from_rows(
    @types.Schema([@types.Field("a", @types.DataType::Int, nullable=false)]),
    [[@types.Scalar::Int(1)], [@types.Scalar::Int(2)]],
  )
  let out = df.drop([])
  assert_eq(out.check_invariants(), Ok(()))
  // `DataFrame`'s derived `Eq` includes the schema, so this pins the no-op as
  // a full identity, metadata included.
  assert_eq(out, df)
  assert_false(out.schema().field("a").nullable())
}

///|
test "drop rejects unknown columns with ColumnNotFound" {
  let df = drop_df()
  assert_eq(
    Ok(df.drop([@expr.col("missing")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  assert_eq(
    Ok(df.drop([@expr.col("a"), @expr.col("z")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("z")),
  )
}
