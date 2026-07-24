// Blackbox tests for the unary numeric ops `Expr::abs` / `floor` / `ceil` /
// `sign`: per-dtype behavior on both backends, NaN pass-through, null
// propagation, and the non-numeric type error.

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
test "unary numeric: Expr::explain renders the method calls" {
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
  assert_eq(@expr.col("f").round(decimals=-3), @expr.col("f").round())
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
