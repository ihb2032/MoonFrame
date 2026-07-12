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
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "unary numeric: Expr::explain renders the method calls" {
  inspect(@expr.col("x").abs().explain(), content="col(x).abs()")
  inspect(@expr.col("x").floor().explain(), content="col(x).floor()")
  inspect(@expr.col("x").ceil().explain(), content="col(x).ceil()")
  inspect(@expr.col("x").sign().explain(), content="col(x).sign()")
}
