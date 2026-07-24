///|
/// Blackbox behavior tests for `DataFrame::with_columns`: naming,
/// replace-in-place vs append, within-call duplicate detection, identity
/// on an empty expression list, and equivalence with a hand-built
/// materialised series. The evaluator's dtype / null / broadcast semantics
/// live in `expr_eval_test.mbt`.

///|
fn base_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_ints("b", [10, 20, 30]),
  ])
}

///|
test "replace: an existing output name replaces in place" {
  let out = base_df().with_columns([@expr.col("a") + @expr.col("b")])
  assert_eq(out.columns(), ["a", "b"])
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Int(22),
    @types.Scalar::Int(33),
  ])
  // The non-target column is untouched.
  assert_eq(out.get_column("b").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "append: a new output name lands rightmost" {
  let out = base_df().with_columns([@expr.lit_int(99)])
  assert_eq(out.columns(), ["a", "b", "literal"])
  assert_eq(
    out.get_column("literal").to_scalars(),
    Array::make(3, @types.Scalar::Int(99)),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "mixed: replace and append in one call, in expression order" {
  let out = base_df().with_columns([
    @expr.col("b") + @expr.lit_int(1),
    @expr.lit_float(0.5),
  ])
  assert_eq(out.columns(), ["a", "b", "literal"])
  assert_eq(out.get_column("b").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Int(21),
    @types.Scalar::Int(31),
  ])
  assert_eq(
    out.get_column("literal").to_scalars(),
    Array::make(3, @types.Scalar::Float(0.5)),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "duplicate output names raise DuplicateColumn at the second expr" {
  // Append flavor: two pure literals both name themselves "literal".
  assert_eq(
    Ok(base_df().with_columns([@expr.lit_int(1), @expr.lit_int(2)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("literal")),
  )
  // Replace flavor: two expressions both target existing column "a" —
  // neither silently wins.
  assert_eq(
    Ok(
      base_df().with_columns([
        @expr.col("a") + @expr.lit_int(1),
        @expr.col("a") + @expr.lit_int(2),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("a")),
  )
}

///|
test "with_columns([]) returns an equal frame" {
  let df = base_df()
  assert_eq(df.with_columns([]), df)
}

///|
test "with_columns([]) preserves a declared schema" {
  // A `from_rows` frame carries the caller's explicit `nullable = false`;
  // an empty expression list adds nothing, so it must come back untouched
  // (the derived `Eq` compares the schema too).
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int, nullable=false),
    ]),
    [[@types.Scalar::Int(1)], [@types.Scalar::Int(2)]],
  )
  let out = df.with_columns([])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
  assert_false(out.schema().field("a").nullable())
}

///|
test "alias drives naming: a fresh alias appends, an existing one replaces" {
  let appended = base_df().with_columns([
    (@expr.col("a") + @expr.col("b")).with_alias("net"),
  ])
  assert_eq(appended.columns(), ["a", "b", "net"])
  assert_eq(appended.get_column("net").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Int(22),
    @types.Scalar::Int(33),
  ])
  // The source columns are untouched by an aliased derivation.
  assert_eq(appended.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  let replaced = base_df().with_columns([
    (@expr.col("a") + @expr.col("b")).with_alias("b"),
  ])
  assert_eq(replaced.columns(), ["a", "b"])
  assert_eq(replaced.get_column("b").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Int(22),
    @types.Scalar::Int(33),
  ])
}

///|
test "a derived column equals the equivalent hand-built series" {
  // The expression path must produce the identical column to a precomputed,
  // hand-built series — backend included: an all-valid numeric result
  // converges onto `Numeric`, exactly where `from_ints` would have put it.
  let derived = base_df()
    .with_columns([@expr.col("a") + @expr.col("b")])
    .get_column("a")
  assert_eq(derived, Series::from_ints("a", [11, 22, 33]))
}
