// Blackbox tests for `Expr::floor_div` (Polars `//`): floor toward −∞, the
// Int-zero → null guard, Float IEEE zero division, mixed promotion, null
// propagation, and the non-numeric type error — on both backends.

///|
test "floor_div: Int floors toward -inf, not truncation (Numeric arm)" {
  let df = DataFrame::new([
    Series::from_ints("a", [7L, -7L, 7L, -7L, 6L]),
    Series::from_ints("b", [2L, 2L, -2L, -2L, 3L]),
  ])
  let out = df.select([@expr.col("a").floor_div(@expr.col("b")).with_alias("q")])
  // 7//2=3, -7//2=-4, 7//-2=-4, -7//-2=3, 6//3=2.
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(-4),
    @types.Scalar::Int(-4),
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
  ])
}

///|
test "floor_div: Int division by zero is a null cell" {
  let df = DataFrame::new([
    Series::from_ints("a", [10L, 5L]),
    Series::from_ints("b", [0L, 2L]),
  ])
  let out = df.select([@expr.col("a").floor_div(@expr.col("b")).with_alias("q")])
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(2),
  ])
}

///|
test "floor_div: mixed Int/Float promotes to a floored Float" {
  let df = DataFrame::new([
    Series::from_ints("a", [7L]),
    Series::from_floats("b", [2.0]),
  ])
  let out = df.select([
    @expr.col("a").floor_div(@expr.col("b")).with_alias("q"),
    @expr.col("b").floor_div(@expr.col("a")).with_alias("r"),
  ])
  // 7 // 2.0 = floor(3.5) = 3.0; 2.0 // 7 = floor(0.285…) = 0.0.
  assert_eq(out.get_column("q").to_scalars(), [@types.Scalar::Float(3.0)])
  assert_eq(out.get_column("r").to_scalars(), [@types.Scalar::Float(0.0)])
}

///|
test "floor_div: Float floors the quotient; zero divisor is IEEE inf/nan" {
  let df = DataFrame::new([
    Series::from_floats("a", [7.5, 1.0, 0.0]),
    Series::from_floats("b", [2.0, 0.0, 0.0]),
  ])
  let q = df
    .select([@expr.col("a").floor_div(@expr.col("b")).with_alias("q")])
    .get_column("q")
    .to_scalars()
  assert_eq(q[0], @types.Scalar::Float(3.0)) // floor(3.75)
  // 1.0 / 0.0 = +inf, floor(+inf) = +inf.
  assert_true(
    match q[1] {
      @types.Scalar::Float(v) => v == @double.infinity
      _ => false
    },
  )
  // 0.0 / 0.0 = NaN, floor(NaN) = NaN.
  assert_true(
    match q[2] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
}

///|
test "floor_div: null propagates (Builtin arm) and non-numeric raises" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(7L), None]),
    Series::from_float_options("b", [Some(2.0), Some(2.0)]),
  ])
  let out = df.select([@expr.col("a").floor_div(@expr.col("b")).with_alias("q")])
  // 7 // 2.0 = 3.0; null // 2.0 = null.
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Null,
  ])
  let strs = DataFrame::new([
    Series::from_strings("s", ["x"]),
    Series::from_ints("n", [1L]),
  ])
  assert_eq(
    Ok(strs.select([@expr.col("s").floor_div(@expr.col("n"))])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "floor-divide",
        @types.DataType::String,
        @types.DataType::Int,
      ),
    ),
  )
}

///|
test "floor_div: general (Builtin) arms for every numeric dtype pair" {
  // Each operand column carries a null, so the pair takes the Builtin general
  // arm rather than the `Numeric` fast path.
  let df = DataFrame::new([
    Series::from_int_options("ia", [Some(7L), Some(10L), None]),
    Series::from_int_options("ib", [Some(2L), Some(0L), Some(2L)]),
    Series::from_float_options("fa", [Some(7.5), None, Some(1.0)]),
    Series::from_float_options("fb", [Some(2.0), Some(2.0), Some(0.0)]),
  ])
  let out = df.select([
    @expr.col("ia").floor_div(@expr.col("ib")).with_alias("ii"),
    @expr.col("fa").floor_div(@expr.col("ib")).with_alias("fi"),
    @expr.col("fa").floor_div(@expr.col("fb")).with_alias("ff"),
  ])
  // ii: 7//2=3, 10//0=null (zero), null//2=null.
  assert_eq(out.get_column("ii").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // fi: 7.5//2=floor(3.75)=3.0, null//0=null, 1.0//2=floor(0.5)=0.0.
  assert_eq(out.get_column("fi").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Null,
    @types.Scalar::Float(0.0),
  ])
  // ff: 7.5//2.0=3.0, null//2.0=null, 1.0//0.0=floor(+inf)=+inf.
  let ff = out.get_column("ff").to_scalars()
  assert_eq(ff[0], @types.Scalar::Float(3.0))
  assert_eq(ff[1], @types.Scalar::Null)
  assert_true(
    match ff[2] {
      @types.Scalar::Float(v) => v == @double.infinity
      _ => false
    },
  )
}

///|
test "floor_div: Expr::explain renders it with //" {
  let e = @expr.col("a").floor_div(@expr.col("b"))
  inspect(e.explain(), content="(col(a) // col(b))")
}
