// Blackbox tests pinning the expr comparison kernel's exact `Int` vs `Float`
// behavior (no 2^53 promotion) — the eval-path mirror of the `Scalar::eq` /
// `Scalar::lt` tests in `types/scalar_test.mbt`.

///|
test "expr comparison: Int vs Float is exact past 2^53 (Numeric fast arm)" {
  // i = [2^53+1, 2^53], f = [2^53, 2^53]; both columns null-free → Numeric.
  let df = DataFrame::new([
    Series::from_ints("i", [9007199254740993L, 9007199254740992L]),
    Series::from_floats("f", [9007199254740992.0, 9007199254740992.0]),
  ])
  let t = @types.Scalar::Bool(true)
  let f = @types.Scalar::Bool(false)
  // Int-vs-Float, all six verbs. Row 0 (2^53+1 vs 2^53, distinct), row 1 equal.
  let fwd = df.select([
    @expr.col("i").eq(@expr.col("f")).with_alias("eq"),
    @expr.col("i").ne(@expr.col("f")).with_alias("ne"),
    @expr.col("i").lt(@expr.col("f")).with_alias("lt"),
    @expr.col("i").le(@expr.col("f")).with_alias("le"),
    @expr.col("i").gt(@expr.col("f")).with_alias("gt"),
    @expr.col("i").ge(@expr.col("f")).with_alias("ge"),
  ])
  assert_eq(fwd.get_column("eq").to_scalars(), [f, t])
  assert_eq(fwd.get_column("ne").to_scalars(), [t, f])
  assert_eq(fwd.get_column("lt").to_scalars(), [f, f])
  assert_eq(fwd.get_column("le").to_scalars(), [f, t])
  assert_eq(fwd.get_column("gt").to_scalars(), [t, f])
  assert_eq(fwd.get_column("ge").to_scalars(), [t, t])
  // Float-vs-Int (the transposed verdict), all six verbs. Row 0 (2^53 vs
  // 2^53+1), row 1 (2^53 vs 2^53).
  let rev = df.select([
    @expr.col("f").eq(@expr.col("i")).with_alias("eq"),
    @expr.col("f").ne(@expr.col("i")).with_alias("ne"),
    @expr.col("f").lt(@expr.col("i")).with_alias("lt"),
    @expr.col("f").le(@expr.col("i")).with_alias("le"),
    @expr.col("f").gt(@expr.col("i")).with_alias("gt"),
    @expr.col("f").ge(@expr.col("i")).with_alias("ge"),
  ])
  assert_eq(rev.get_column("eq").to_scalars(), [f, t])
  assert_eq(rev.get_column("ne").to_scalars(), [t, f])
  assert_eq(rev.get_column("lt").to_scalars(), [t, f])
  assert_eq(rev.get_column("le").to_scalars(), [t, t])
  assert_eq(rev.get_column("gt").to_scalars(), [f, f])
  assert_eq(rev.get_column("ge").to_scalars(), [f, t])
}

///|
test "expr comparison: exact past 2^53 on the Builtin (nullable) arm" {
  // A null forces the general Builtin arm; the exact verdict is unchanged and
  // the null layer still nulls its row.
  let df = DataFrame::new([
    Series::from_int_options("i", [Some(9007199254740993L), None]),
    Series::from_float_options("f", [Some(9007199254740992.0), Some(1.0)]),
  ])
  let out = df.select([@expr.col("i").eq(@expr.col("f")).with_alias("eq")])
  assert_eq(out.get_column("eq").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
}
