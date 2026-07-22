// Blackbox tests for the unary numeric ops `Expr::abs` / `floor` / `ceil` /
// `sign`: per-dtype behavior on both backends, NaN pass-through, null
// propagation, and the non-numeric type error.

///|
test "abs / floor / ceil / sign on the Numeric fast arm" {
  let df = DataFrame::new([
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
  let df = DataFrame::new([
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
  let nans = DataFrame::new([Series::from_floats("f", [@double.not_a_number])])
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
  let strs = DataFrame::new([Series::from_strings("s", ["x"])])
  assert_true(
    (Ok(strs.select([@expr.col("s").abs()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

///|
test "round: ties go to even (banker's rounding)" {
  let df = DataFrame::new([
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
}

///|
test "round: non-ties go to the nearest integer; Int is identity" {
  let df = DataFrame::new([
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
  let df = DataFrame::new([Series::from_float_options("f", [Some(2.5), None])])
  let out = df.select([@expr.col("f").round().with_alias("r")])
  // 2.5 rounds to the even 2; a null stays null.
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  // NaN and ±inf pass through unchanged.
  let inf = 1.0 / 0.0
  let special = DataFrame::new([
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
  let strs = DataFrame::new([Series::from_strings("s", ["x"])])
  assert_true(
    (Ok(strs.select([@expr.col("s").round()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

///|
test "unary numeric: Expr::explain renders the method calls" {
  inspect(@expr.col("x").abs().to_string(), content="col(x).abs()")
  inspect(@expr.col("x").floor().to_string(), content="col(x).floor()")
  inspect(@expr.col("x").ceil().to_string(), content="col(x).ceil()")
  inspect(@expr.col("x").sign().to_string(), content="col(x).sign()")
  inspect(@expr.col("x").round().to_string(), content="col(x).round()")
}
