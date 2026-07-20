// Blackbox tests for `Expr::modulo` (`%`) and `Expr::pow` (`**`, always Float).

///|
test "modulo: Int remainder carries the dividend's sign; every arm" {
  let df = DataFrame::new([
    Series::from_ints("i", [7L, -7L, 6L]),
    Series::from_ints("j", [2L, 2L, -4L]),
    Series::from_floats("f", [7.5, -7.5, 8.0]),
    Series::from_floats("g", [2.0, 2.0, 3.0]),
  ])
  let out = df.select([
    @expr.col("i").modulo(@expr.col("j")).with_alias("ii"),
    @expr.col("i").modulo(@expr.col("g")).with_alias("if"),
    @expr.col("f").modulo(@expr.col("j")).with_alias("fi"),
    @expr.col("f").modulo(@expr.col("g")).with_alias("ff"),
  ])
  // ii: 7%2=1, -7%2=-1, 6%-4=2.
  assert_eq(out.get_column("ii").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(-1),
    @types.Scalar::Int(2),
  ])
  // if (Int%Float→Float): 7%2=1, -7%2=-1, 6%3=0.
  assert_eq(out.get_column("if").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(-1.0),
    @types.Scalar::Float(0.0),
  ])
  // fi (Float%Int): 7.5%2=1.5, -7.5%2=-1.5, 8%-4=0.
  assert_eq(out.get_column("fi").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(-1.5),
    @types.Scalar::Float(0.0),
  ])
  // ff: 7.5%2=1.5, -7.5%2=-1.5, 8%3=2.
  assert_eq(out.get_column("ff").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(-1.5),
    @types.Scalar::Float(2.0),
  ])
}

///|
test "modulo: Numeric Int-by-zero divisor yields null (fast arm)" {
  let df = DataFrame::new([
    Series::from_ints("a", [10L, 5L]),
    Series::from_ints("b", [0L, 2L]),
  ])
  let out = df.select([@expr.col("a").modulo(@expr.col("b")).with_alias("m")])
  // 10%0=null, 5%2=1.
  assert_eq(out.get_column("m").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
  ])
}

///|
test "modulo: Int-by-zero null, Float-by-zero NaN, Builtin arms, non-numeric" {
  let df = DataFrame::new([
    Series::from_int_options("i", [Some(10L), None, Some(5L)]),
    Series::from_int_options("j", [Some(0L), Some(2L), Some(3L)]),
    Series::from_float_options("f", [Some(1.0), Some(7.5), None]),
    Series::from_float_options("g", [Some(0.0), Some(2.0), Some(2.0)]),
  ])
  let out = df.select([
    @expr.col("i").modulo(@expr.col("j")).with_alias("ii"),
    @expr.col("i").modulo(@expr.col("g")).with_alias("ig"),
    @expr.col("f").modulo(@expr.col("j")).with_alias("fj"),
    @expr.col("f").modulo(@expr.col("g")).with_alias("fg"),
  ])
  // ii (Builtin Int/Int): 10%0=null, null, 5%3=2.
  assert_eq(out.get_column("ii").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Int(2),
  ])
  // ig (Builtin Int/Float): 10%0.0=nan, null, 5%2.0=1.0.
  let ig = out.get_column("ig").to_scalars()
  assert_true(
    match ig[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_eq(ig[1], @types.Scalar::Null)
  assert_eq(ig[2], @types.Scalar::Float(1.0))
  // fj (Builtin Float/Int): 1%0=nan, 7.5%2=1.5, null.
  let fj = out.get_column("fj").to_scalars()
  assert_true(
    match fj[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_eq(fj[1], @types.Scalar::Float(1.5))
  assert_eq(fj[2], @types.Scalar::Null)
  // fg (Builtin Float/Float): 1%0.0=nan, 7.5%2.0=1.5, null.
  let fg = out.get_column("fg").to_scalars()
  assert_true(
    match fg[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_eq(fg[1], @types.Scalar::Float(1.5))
  assert_eq(fg[2], @types.Scalar::Null)
  // Non-numeric raises.
  let strs = DataFrame::new([
    Series::from_strings("s", ["x"]),
    Series::from_ints("n", [1L]),
  ])
  assert_eq(
    Ok(strs.select([@expr.col("s").modulo(@expr.col("n"))])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "take the remainder of",
          @types.DataType::String,
          @types.DataType::Int,
        ),
      ),
    ),
  )
}

///|
test "pow: always Float; every numeric arm" {
  let df = DataFrame::new([
    Series::from_ints("i", [2L, 4L]),
    Series::from_ints("j", [3L, 2L]),
    Series::from_floats("f", [2.0, 9.0]),
    Series::from_floats("g", [10.0, 0.5]),
  ])
  let out = df.select([
    @expr.col("i").pow(@expr.col("j")).with_alias("ii"),
    @expr.col("i").pow(@expr.col("g")).with_alias("ig"),
    @expr.col("f").pow(@expr.col("j")).with_alias("fj"),
    @expr.col("f").pow(@expr.col("g")).with_alias("fg"),
  ])
  // ii: 2^3=8, 4^2=16 (Float).
  assert_eq(out.get_column("ii").to_scalars(), [
    @types.Scalar::Float(8.0),
    @types.Scalar::Float(16.0),
  ])
  // ig (Int^Float): 2^10=1024, 4^0.5=2.
  assert_eq(out.get_column("ig").to_scalars(), [
    @types.Scalar::Float(1024.0),
    @types.Scalar::Float(2.0),
  ])
  // fj (Float^Int): 2^3=8, 9^2=81.
  assert_eq(out.get_column("fj").to_scalars(), [
    @types.Scalar::Float(8.0),
    @types.Scalar::Float(81.0),
  ])
  // fg (Float^Float): 2^10=1024, 9^0.5=3.
  assert_eq(out.get_column("fg").to_scalars(), [
    @types.Scalar::Float(1024.0),
    @types.Scalar::Float(3.0),
  ])
}

///|
test "pow: negative / zero exponents, Builtin arms, null, non-numeric" {
  let df = DataFrame::new([
    Series::from_float_options("b", [Some(2.0), Some(0.0), None]),
    Series::from_float_options("e", [Some(-1.0), Some(0.0), Some(2.0)]),
    Series::from_int_options("ib", [Some(2L), Some(3L), None]),
    Series::from_int_options("ie", [Some(-2L), Some(0L), Some(2L)]),
  ])
  let out = df.select([
    @expr.col("b").pow(@expr.col("e")).with_alias("ff"),
    @expr.col("ib").pow(@expr.col("ie")).with_alias("ii"),
    @expr.col("ib").pow(@expr.col("e")).with_alias("if"),
    @expr.col("b").pow(@expr.col("ie")).with_alias("fi"),
  ])
  // ff: 2^-1=0.5, 0^0=1, null.
  assert_eq(out.get_column("ff").to_scalars(), [
    @types.Scalar::Float(0.5),
    @types.Scalar::Float(1.0),
    @types.Scalar::Null,
  ])
  // ii (Builtin Int^Int, still Float): 2^-2=0.25, 3^0=1, null.
  assert_eq(out.get_column("ii").to_scalars(), [
    @types.Scalar::Float(0.25),
    @types.Scalar::Float(1.0),
    @types.Scalar::Null,
  ])
  // if / fi just exercise the remaining Builtin mixed arms.
  assert_eq(out.get_column("if").to_scalars()[1], @types.Scalar::Float(1.0))
  assert_eq(out.get_column("fi").to_scalars()[1], @types.Scalar::Float(1.0))
  // Non-numeric raises.
  let strs = DataFrame::new([
    Series::from_strings("s", ["x"]),
    Series::from_ints("n", [2L]),
  ])
  assert_eq(
    Ok(strs.select([@expr.col("s").pow(@expr.col("n"))])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "exponentiate",
          @types.DataType::String,
          @types.DataType::Int,
        ),
      ),
    ),
  )
}

///|
test "mod / pow: Expr::explain renders % and **" {
  inspect(
    @expr.col("a").modulo(@expr.col("b")).explain(),
    content="(col(a) % col(b))",
  )
  inspect(
    @expr.col("a").pow(@expr.col("b")).explain(),
    content="(col(a) ** col(b))",
  )
}
