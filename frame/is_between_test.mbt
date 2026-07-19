// Blackbox tests for `Expr::is_between` — both-closed `lo <= x <= hi`.

///|
test "is_between: both endpoints are inclusive" {
  let df = DataFrame::new([Series::from_ints("a", [0L, 1L, 5L, 10L, 11L])])
  let out = df.select([
    @expr.col("a")
    .is_between(@expr.lit_int(1), @expr.lit_int(10))
    .with_alias("r"),
  ])
  // 1 and 10 (the endpoints) are in range; 0 and 11 are out.
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
}

///|
test "is_between: Float, String, and Bool ordering" {
  let df = DataFrame::new([
    Series::from_floats("f", [0.5, 2.0, 3.5]),
    Series::from_strings("s", ["apple", "cherry", "zebra"]),
    Series::from_bools("b", [true, false, true]),
  ])
  let out = df.select([
    @expr.col("f")
    .is_between(@expr.lit_float(1.0), @expr.lit_float(3.0))
    .with_alias("rf"),
    @expr.col("s")
    .is_between(@expr.lit_str("b"), @expr.lit_str("m"))
    .with_alias("rs"),
    @expr.col("b")
    .is_between(@expr.lit_bool(false), @expr.lit_bool(true))
    .with_alias("rb"),
  ])
  assert_eq(out.get_column("rf").to_scalars(), [
    @types.Scalar::Bool(false), // 0.5 < 1.0
    @types.Scalar::Bool(true), // 1.0 <= 2.0 <= 3.0
    @types.Scalar::Bool(false), // 3.5 > 3.0
  ])
  assert_eq(out.get_column("rs").to_scalars(), [
    @types.Scalar::Bool(false), // "apple" < "b"
    @types.Scalar::Bool(true), // "b" <= "cherry" <= "m"
    @types.Scalar::Bool(false), // "zebra" > "m"
  ])
  // Every Bool is within [false, true].
  assert_eq(out.get_column("rb").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
  ])
}

///|
test "is_between: a null cell yields null" {
  let df = DataFrame::new([Series::from_int_options("a", [Some(5L), None])])
  let out = df.select([
    @expr.col("a")
    .is_between(@expr.lit_int(0), @expr.lit_int(10))
    .with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
}

///|
test "is_between: column bounds propagate nulls under Kleene AND" {
  let df = DataFrame::new([
    Series::from_ints("a", [5L, 20L]),
    Series::from_int_options("lo", [None, None]),
    Series::from_ints("hi", [10L, 10L]),
  ])
  let out = df.select([
    @expr.col("a").is_between(@expr.col("lo"), @expr.col("hi")).with_alias("r"),
  ])
  // row0: (5 >= null) & (5 <= 10) = null & true  = null.
  // row1: (20 >= null) & (20 <= 10) = null & false = false (a known false wins).
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "is_between: equals ge().land(le()), operand shared" {
  // A *computed* operand is evaluated once by the dedicated node; the result
  // must still match the explicit `ge & le` lowering cell for cell.
  let df = DataFrame::new([
    Series::from_int_options("x", [Some(2L), Some(7L), None]),
  ])
  let operand = @expr.col("x") + @expr.lit_int(1)
  let via_between = df
    .select([
      operand.is_between(@expr.lit_int(3), @expr.lit_int(8)).with_alias("r"),
    ])
    .get_column("r")
    .to_scalars()
  let via_manual = df
    .select([
      operand
      .ge(@expr.lit_int(3))
      .land(operand.le(@expr.lit_int(8)))
      .with_alias("r"),
    ])
    .get_column("r")
    .to_scalars()
  assert_eq(via_between, via_manual)
}

///|
test "is_between: a non-orderable operand raises OpTypeMismatch" {
  let df = DataFrame::new([Series::from_strings("s", ["x"])])
  assert_eq(
    Ok(
      df.select([@expr.col("s").is_between(@expr.lit_int(0), @expr.lit_int(10))]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "compare",
        @types.DataType::String,
        @types.DataType::Int,
      ),
    ),
  )
}

///|
test "is_between: reduces per group over an aggregation" {
  let df = DataFrame::new([
    Series::from_strings("k", ["x", "x", "y"]),
    Series::from_ints("v", [10L, 20L, 5L]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v")
      .sum()
      .is_between(@expr.lit_int(0), @expr.lit_int(25))
      .with_alias("in_range"),
    ])
  assert_eq(out.get_column("in_range").to_scalars(), [
    @types.Scalar::Bool(false), // x: 30 > 25
    @types.Scalar::Bool(true), // y: 5
  ])
}
