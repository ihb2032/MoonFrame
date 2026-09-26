// Blackbox tests for the numeric expression operators, one family per
// section: the unary ops (`abs` / `floor` / `ceil` / `sign` / `round`),
// the binary arithmetic edges (`modulo` / `pow` / `floor_div`), the exact
// `Int` ↔ `Float` comparison the kernel promises, and the `Int64` extremes
// where 2^63 wraps rather than aborts.
// Blackbox tests for the unary numeric ops `Expr::abs` / `floor` / `ceil` /
// `sign` / `round`: per-dtype behavior on both backends, NaN pass-through, null
// propagation, and the non-numeric type error — plus, for `round`, the
// half-to-even rule, the `decimals~` places, and the non-finite edges.

///|
test "abs / floor / ceil / sign on the Numeric fast arm" {
  let df = DataFrame::DataFrame([
    Series::from_ints("i", [-3L, 3L, 0L]),
    Series::from_floats("f", [-3.7, 3.2, 0.0]),
  ])
  let out = df.select([
    @expr.col("i").abs().with_alias("i_abs"),
    @expr.col("i").floor().with_alias("i_floor"),
    @expr.col("i").ceil().with_alias("i_ceil"),
    @expr.col("i").sign().with_alias("i_sign"),
    @expr.col("f").abs().with_alias("f_abs"),
    @expr.col("f").floor().with_alias("f_floor"),
    @expr.col("f").ceil().with_alias("f_ceil"),
    @expr.col("f").sign().with_alias("f_sign"),
  ])
  // `Int`: floor/ceil are identity, abs and sign act.
  assert_eq(out.get_column("i_abs").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("i_floor").to_scalars(), [
    @types.Scalar::Int(-3),
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("i_ceil").to_scalars(), [
    @types.Scalar::Int(-3),
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("i_sign").to_scalars(), [
    @types.Scalar::Int(-1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
  ])
  // `Float`: floor toward −∞, ceil toward +∞.
  assert_eq(out.get_column("f_abs").to_scalars(), [
    @types.Scalar::Float(3.7),
    @types.Scalar::Float(3.2),
    @types.Scalar::Float(0.0),
  ])
  assert_eq(out.get_column("f_floor").to_scalars(), [
    @types.Scalar::Float(-4.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(0.0),
  ])
  assert_eq(out.get_column("f_ceil").to_scalars(), [
    @types.Scalar::Float(-3.0),
    @types.Scalar::Float(4.0),
    @types.Scalar::Float(0.0),
  ])
  assert_eq(out.get_column("f_sign").to_scalars(), [
    @types.Scalar::Float(-1.0),
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(0.0),
  ])
}

///|
test "unary numeric: Builtin arm, null propagation, NaN, non-numeric" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("i", [Some(-3L), None]),
    Series::from_float_options("f", [Some(-3.7), None]),
  ])
  let out = df.select([
    @expr.col("i").abs().with_alias("i_abs"),
    @expr.col("f").floor().with_alias("f_floor"),
  ])
  assert_eq(out.get_column("i_abs").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("f_floor").to_scalars(), [
    @types.Scalar::Float(-4.0),
    @types.Scalar::Null,
  ])
  // `NaN` passes through `abs` / `sign`.
  let nans = DataFrame::DataFrame([
    Series::from_floats("f", [@double.not_a_number]),
  ])
  let nout = nans.select([
    @expr.col("f").abs().with_alias("a"),
    @expr.col("f").sign().with_alias("s"),
  ])
  assert_true(
    match nout.get_column("a").to_scalars()[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_true(
    match nout.get_column("s").to_scalars()[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  // A non-numeric operand raises.
  let strs = DataFrame::DataFrame([Series::from_strings("s", ["x"])])
  assert_true(
    (Ok(strs.select([@expr.col("s").abs()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

///|
test "round: ties go to even (banker's rounding)" {
  let df = DataFrame::DataFrame([
    Series::from_floats("x", [0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5, -3.5]),
  ])
  let out = df.select([@expr.col("x").round().with_alias("r")])
  // Each exact half rounds to its even neighbour: 0.5→0, 1.5→2, 2.5→2, 3.5→4,
  // and the negatives symmetrically.
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(4.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(-2.0),
    @types.Scalar::Float(-2.0),
    @types.Scalar::Float(-4.0),
  ])
  // `-0.5`'s even neighbour is `-0.0`: IEEE equality calls both zeros
  // equal above, so the sign is asserted where IEEE makes it observable —
  // under division, where +0.0 and -0.0 go to opposite infinities.
  let cells = out.get_column("r").to_scalars()
  assert_true(cells[0] is @types.Scalar::Float(v) && v == 0.0 && 1.0 / v > 0.0)
  assert_true(cells[4] is @types.Scalar::Float(v) && v == 0.0 && 1.0 / v < 0.0)
}

///|
test "round: non-ties go to the nearest integer; Int is identity" {
  let df = DataFrame::DataFrame([
    Series::from_ints("i", [-3L, 4L, 0L]),
    Series::from_floats("f", [3.2, 3.7, -3.7]),
  ])
  let out = df.select([
    @expr.col("i").round().with_alias("ri"),
    @expr.col("f").round().with_alias("rf"),
  ])
  assert_eq(out.get_column("ri").to_scalars(), [
    @types.Scalar::Int(-3),
    @types.Scalar::Int(4),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("rf").to_scalars(), [
    @types.Scalar::Float(3.0), // 3.2 → 3
    @types.Scalar::Float(4.0), // 3.7 → 4
    @types.Scalar::Float(-4.0), // -3.7 → -4
  ])
}

///|
test "round: Builtin null, NaN / ±inf pass through, non-numeric raises" {
  let df = DataFrame::DataFrame([
    Series::from_float_options("f", [Some(2.5), None]),
  ])
  let out = df.select([@expr.col("f").round().with_alias("r")])
  // 2.5 rounds to the even 2; a null stays null.
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  // NaN and ±inf pass through unchanged.
  let inf = 1.0 / 0.0
  let special = DataFrame::DataFrame([
    Series::from_floats("f", [@double.not_a_number, inf, -inf]),
  ])
  let s = special
    .select([@expr.col("f").round().with_alias("r")])
    .get_column("r")
    .to_scalars()
  assert_true(
    match s[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_eq(s[1], @types.Scalar::Float(inf))
  assert_eq(s[2], @types.Scalar::Float(-inf))
  // A non-numeric operand raises.
  let strs = DataFrame::DataFrame([Series::from_strings("s", ["x"])])
  assert_true(
    (Ok(strs.select([@expr.col("s").round()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

///|
test "unary numeric: Expr::to_string renders the method calls" {
  inspect(@expr.col("x").abs().to_string(), content="col(x).abs()")
  inspect(@expr.col("x").floor().to_string(), content="col(x).floor()")
  inspect(@expr.col("x").ceil().to_string(), content="col(x).ceil()")
  inspect(@expr.col("x").sign().to_string(), content="col(x).sign()")
  inspect(@expr.col("x").round().to_string(), content="col(x).round()")
}

///|
test "round takes a decimal-place count" {
  let df = DataFrame::DataFrame([
    Series::from_floats("f", [1.2345, 2.5, -1.2345, 0.125]),
    Series::from_ints("i", [7, 8, 9, 10]),
  ])
  let rounded = df.select([
    @expr.col("f").round(decimals=2).with_alias("two"),
    @expr.col("f").round().with_alias("zero"),
    @expr.col("i").round(decimals=3).with_alias("int"),
  ])
  assert_eq(rounded.item(0, "two"), @types.Scalar::Float(1.23))
  assert_eq(rounded.item(2, "two"), @types.Scalar::Float(-1.23))
  // Ties still go to even, at the requested place: 0.125 → 0.12.
  assert_eq(rounded.item(3, "two"), @types.Scalar::Float(0.12))
  // The default is unchanged: whole numbers, ties to even.
  assert_eq(rounded.item(1, "zero"), @types.Scalar::Float(2.0))
  // An Int column is the identity at any setting.
  assert_eq(rounded.item(0, "int"), @types.Scalar::Int(7))
  // A negative count clamps to 0 rather than raising.
  assert_same_expr(@expr.col("f").round(decimals=-3), @expr.col("f").round())
  // A non-default count renders as the argument that builds it.
  inspect(@expr.col("f").round(decimals=2), content="col(f).round(decimals=2)")
}

///|
test "round(decimals) stays total at the numeric edges" {
  let nan = 0.0 / 0.0
  let inf = 1.0 / 0.0
  let df = DataFrame::DataFrame([
    Series::from_floats("f", [nan, inf, -inf, 1.7976931348623157e308, 1.5]),
  ])
  // Non-finite cells pass through untouched, as with the whole-number form.
  let out = df.select([@expr.col("f").round(decimals=2).with_alias("r")])
  let cells = out.get_column("r").to_scalars()
  assert_true(
    match cells[0] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_eq(cells[1], @types.Scalar::Float(inf))
  assert_eq(cells[2], @types.Scalar::Float(-inf))
  // Scaling the largest finite Double by 100 overflows, so the value is left
  // as it is rather than round-tripping through infinity.
  assert_eq(cells[3], @types.Scalar::Float(1.7976931348623157e308))
  // A decimal count so large that 10^decimals is infinite is likewise a no-op.
  let huge = df.select([@expr.col("f").round(decimals=400).with_alias("r")])
  assert_eq(huge.get_column("r").to_scalars()[4], @types.Scalar::Float(1.5))
}

///|
test "round(decimals) is the identity past the value's own resolution" {
  // Asking for more places than a `Double` can resolve must return the value
  // unchanged. Scaling by `10^decimals` and dividing back does not: above
  // `10^22` the scale is itself inexact, so the round trip moved the value by
  // an ulp even though rounding could not have.
  let df = DataFrame::DataFrame([
    Series::from_floats("f", [1.5, -1.5, 123456.789, 0.1, 1.0e15]),
  ])
  for places in [17, 20, 30, 99, 300, 308, 309, 400] {
    let out = df.select([@expr.col("f").round(decimals=places).with_alias("r")])
    assert_eq(out.get_column("r").to_scalars(), df.get_column("f").to_scalars())
  }
  // A value that is already integral is untouched at any place, however few.
  let integral = df.select([@expr.col("f").round(decimals=2).with_alias("r")])
  assert_eq(integral.item(4, "r"), @types.Scalar::Float(1.0e15))
  // The guard must not swallow the rounding that a fine place genuinely does:
  // a magnitude small enough to still have a fraction at that place rounds.
  let small = DataFrame::DataFrame([
    Series::from_floats("f", [4.0e-18, 6.0e-18, 1.0e-300]),
  ])
  let rounded = small.select([@expr.col("f").round(decimals=17).with_alias("r")])
  assert_eq(rounded.item(0, "r"), @types.Scalar::Float(0.0))
  assert_eq(rounded.item(1, "r"), @types.Scalar::Float(1.0e-17))
  assert_eq(rounded.item(2, "r"), @types.Scalar::Float(0.0))
}

// Blackbox tests for `Expr::modulo` (`%`) and `Expr::pow` (`**`, always Float).

///|
test "modulo: Int remainder carries the dividend's sign; every arm" {
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let strs = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let strs = DataFrame::DataFrame([
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
test "mod / pow: Expr::to_string renders % and **" {
  inspect(
    @expr.col("a").modulo(@expr.col("b")).to_string(),
    content="(col(a) % col(b))",
  )
  inspect(
    @expr.col("a").pow(@expr.col("b")).to_string(),
    content="(col(a) ** col(b))",
  )
}

// Blackbox tests for `Expr::floor_div` (Polars `//`): floor toward −∞, the
// Int-zero → null guard, Float IEEE zero division, mixed promotion, null
// propagation, and the non-numeric type error — on both backends.

///|
test "floor_div: Int floors toward -inf, not truncation (Numeric arm)" {
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(7L), None]),
    Series::from_float_options("b", [Some(2.0), Some(2.0)]),
  ])
  let out = df.select([@expr.col("a").floor_div(@expr.col("b")).with_alias("q")])
  // 7 // 2.0 = 3.0; null // 2.0 = null.
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Null,
  ])
  let strs = DataFrame::DataFrame([
    Series::from_strings("s", ["x"]),
    Series::from_ints("n", [1L]),
  ])
  assert_eq(
    Ok(strs.select([@expr.col("s").floor_div(@expr.col("n"))])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "floor-divide",
          @types.DataType::String,
          @types.DataType::Int,
        ),
      ),
    ),
  )
}

///|
test "floor_div: general (Builtin) arms for every numeric dtype pair" {
  // Each operand column carries a null, so the pair takes the Builtin general
  // arm rather than the `Numeric` fast path.
  let df = DataFrame::DataFrame([
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
test "floor_div: Expr::to_string renders it with //" {
  let e = @expr.col("a").floor_div(@expr.col("b"))
  inspect(e.to_string(), content="(col(a) // col(b))")
}

// Integer arithmetic at the `Int64` edges. `Int64::MIN` has no positive
// counterpart, so negating, absolute-value-ing, multiplying or floor-dividing
// it by `-1` all produce `2^63`, which does not fit — every one of them wraps
// back to `Int64::MIN` rather than aborting, and must do so identically on all
// four backends. `//` is the one that needed help: wasm's `i64.div_s` traps on
// that pair by specification (`i64.rem_s` special-cases it to `0` instead), so
// `floor_div_i64` routes division by `-1` through negation.

///|
let i64_min : Int64 = -9223372036854775808L

///|
/// The extremes fixture on the `Numeric` backend (`from_ints` is all-valid) and
/// on `Builtin` (`from_int_options` carries a validity bitmap). Every kernel
/// has a fast path for the first and a nullable path for the second, so both
/// have to be exercised.
fn extremes(nullable : Bool) -> DataFrame raise @types.DataError {
  let a = [i64_min, i64_min, -1L, 0L]
  let b = [-1L, 1L, -1L, -1L]
  DataFrame::DataFrame(
    if nullable {
      [
        Series::from_int_options("a", a.map(v => Some(v))),
        Series::from_int_options("b", b.map(v => Some(v))),
      ]
    } else {
      [Series::from_ints("a", a), Series::from_ints("b", b)]
    },
  )
}

///|
/// Evaluate `build(col a, col b)` over both storage backends and return the
/// cells, asserting the two agree — the parity a backend-specific intrinsic
/// would break.
fn extremes_result(
  build : (@expr.Expr, @expr.Expr) -> @expr.Expr,
) -> Array[@types.Scalar] raise {
  let of = fn(nullable : Bool) -> Array[@types.Scalar] raise @types.DataError {
    extremes(nullable)
    .select([build(@expr.col("a"), @expr.col("b")).with_alias("r")])
    .get_column("r")
    .to_scalars()
  }
  let numeric = of(false)
  assert_eq(numeric, of(true))
  numeric
}

///|
test "floor_div at Int64::MIN / -1 wraps instead of trapping" {
  // Rows: MIN // -1, MIN // 1, -1 // -1, 0 // -1.
  assert_eq(extremes_result((a, b) => a.floor_div(b)), [
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
  ])
}

///|
test "floor_div by -1 still floors: it agrees with negation everywhere" {
  // The special case must not change any *representable* quotient. `// -1` is
  // exact for every dividend, so it is negation — including the sign of zero
  // and the odd/even cases a floor adjustment would disturb.
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [7L, -7L, 8L, -8L, 0L, 9223372036854775807L]),
    Series::from_ints("b", [-1L, -1L, -1L, -1L, -1L, -1L]),
  ])
  let out = df.select([
    @expr.col("a").floor_div(@expr.col("b")).with_alias("q"),
    (-@expr.col("a")).with_alias("n"),
  ])
  assert_eq(out.get_column("q").to_scalars(), out.get_column("n").to_scalars())
  assert_eq(out.get_column("q").to_scalars(), [
    @types.Scalar::Int(-7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(-8),
    @types.Scalar::Int(8),
    @types.Scalar::Int(0),
    @types.Scalar::Int(-9223372036854775807L),
  ])
}

///|
test "modulo at Int64::MIN % -1 is zero on every backend" {
  // `%` is evaluated as part of the same division `//` is, so it faults on the
  // same pair — but only on some backends: wasm's `i64.rem_s` defines
  // `Int64::MIN % -1` as `0`, while a native build lowers `%` to a hardware
  // divide that raises the divide-by-zero fault. `0` is the answer either way
  // (a remainder by ±1 is always 0), so `rem_i64` returns it without dividing.
  assert_eq(extremes_result((a, b) => a.modulo(b)), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
  ])
}

///|
test "modulo by -1 is zero for every dividend, like modulo by 1" {
  // The special case must agree with the general path wherever that path is
  // defined: `a % -1` and `a % 1` are both `0` for every `a`.
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [7L, -7L, 0L, 9223372036854775807L, i64_min]),
  ])
  let out = df.select([
    @expr.col("a").modulo(@expr.lit_int(-1)).with_alias("m"),
    @expr.col("a").modulo(@expr.lit_int(1)).with_alias("p"),
  ])
  let zeros = Array::make(5, @types.Scalar::Int(0))
  assert_eq(out.get_column("m").to_scalars(), zeros)
  assert_eq(out.get_column("p").to_scalars(), zeros)
}

///|
test "neg / abs / mul wrap at Int64::MIN" {
  let wrapped = [
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
  ]
  // -a and a * b (b = -1 except row 1) are the same wrap.
  assert_eq(extremes_result((a, _) => -a), wrapped)
  assert_eq(extremes_result((a, b) => a * b), [
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
  ])
  // abs leaves MIN alone (no positive counterpart) and is identity on the rest.
  assert_eq(extremes_result((a, _) => a.abs()), [
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(i64_min),
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
  ])
}

///|
test "true division of Int64::MIN is Float, so it never overflows" {
  // `/` is always Float in MoonFrame, so the pair that overflows in Int64
  // arithmetic is an ordinary IEEE quotient here.
  assert_eq(extremes_result((a, b) => a / b), [
    @types.Scalar::Float(9223372036854775808.0),
    @types.Scalar::Float(-9223372036854775808.0),
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(-0.0),
  ])
}

// Blackbox tests pinning the expr comparison kernel's exact `Int` vs `Float`
// behavior (no 2^53 promotion) — the authoritative home of that exactness,
// on both the Numeric fast arm and the Builtin nullable arm.

///|
test "expr comparison: Int vs Float is exact past 2^53 (Numeric fast arm)" {
  // i = [2^53+1, 2^53], f = [2^53, 2^53]; both columns null-free → Numeric.
  let df = DataFrame::DataFrame([
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
  let df = DataFrame::DataFrame([
    Series::from_int_options("i", [Some(9007199254740993L), None]),
    Series::from_float_options("f", [Some(9007199254740992.0), Some(1.0)]),
  ])
  let out = df.select([@expr.col("i").eq(@expr.col("f")).with_alias("eq")])
  assert_eq(out.get_column("eq").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
}

///|
test "expr comparison: Int vs Float at the Int64 boundaries, ±Inf and NaN" {
  // Past the Int64 range the helpers answer from the bounds alone: `MAX` is
  // below the 2^63 `Double` it would round to, `MIN` is above `-Inf`, and
  // `NaN` makes every verdict `false`.
  let df = DataFrame::DataFrame([
    // MAX vs 2^63, MIN vs -Inf, 0 vs NaN, 0 vs +Inf — all null-free → Numeric.
    Series::from_ints("i", [9223372036854775807L, -9223372036854775808L, 0L, 0L]),
    Series::from_floats("f", [
      9223372036854775808.0, @double.neg_infinity, @double.not_a_number, @double.infinity,
    ]),
  ])
  let t = @types.Scalar::Bool(true)
  let f = @types.Scalar::Bool(false)
  let out = df.select([
    @expr.col("i").eq(@expr.col("f")).with_alias("eq"),
    @expr.col("i").lt(@expr.col("f")).with_alias("lt"),
    @expr.col("i").gt(@expr.col("f")).with_alias("gt"),
  ])
  assert_eq(out.get_column("eq").to_scalars(), [f, f, f, f])
  assert_eq(out.get_column("lt").to_scalars(), [t, f, f, t])
  assert_eq(out.get_column("gt").to_scalars(), [f, t, f, f])
}
