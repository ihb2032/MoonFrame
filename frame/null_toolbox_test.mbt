// Blackbox tests for the null / NaN toolbox additions: the directional
// fills (`fill_null_forward` / `_backward`, `limit?` capping consecutive
// slots), the frame-wide `fill_nan`, and the expression probes `is_finite`
// / `is_infinite` and the `clip` clamp. Evaluated eagerly and (for the
// frame verbs) through the lazy mirrors.

///|
/// Forward fill: leading nulls stay, the nearest present value above fills
/// the rest; `limit` caps the consecutive slots one value may fill.
test "forward_fill takes the value above, honoring the limit" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [
      None,
      Some(1),
      None,
      None,
      None,
      Some(5),
      None,
    ]),
  ])
  assert_eq(df.fill_null_forward().get_column("v").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(5),
    @types.Scalar::Int(5),
  ])
  // limit = 2: the three-slot gap after the 1 keeps its tail null.
  assert_eq(df.fill_null_forward(limit=2).get_column("v").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Null,
    @types.Scalar::Int(5),
    @types.Scalar::Int(5),
  ])
  // A limit below 1 raises.
  assert_true(
    (Ok(df.fill_null_forward(limit=0)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "backward_fill is the mirror; strings fill too" {
  let df = DataFrame::DataFrame([
    Series::from_string_options("s", [Some("a"), None, None, Some("d"), None]),
  ])
  assert_eq(df.fill_null_backward().get_column("s").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("d"),
    @types.Scalar::String("d"),
    @types.Scalar::String("d"),
    @types.Scalar::Null,
  ])
  // A column with no nulls passes through untouched.
  let full = DataFrame::DataFrame([Series::from_ints("i", [1, 2])])
  assert_eq(full.fill_null_backward(), full)
}

///|
test "the expression fills mirror the frame verbs, per column" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [None, Some(2), None, Some(4)]),
  ])
  assert_eq(
    df.select([@expr.col("v").forward_fill()]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Int(2),
      @types.Scalar::Int(2),
      @types.Scalar::Int(4),
    ],
  )
  assert_eq(
    df.select([@expr.col("v").backward_fill()]).get_column("v").to_scalars(),
    [
      @types.Scalar::Int(2),
      @types.Scalar::Int(2),
      @types.Scalar::Int(4),
      @types.Scalar::Int(4),
    ],
  )
}

///|
test "fill_nan replaces NaN in Float columns and nothing else" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::DataFrame([
    // A NaN and a null side by side: the NaN replaces, the null is missing,
    // not NaN, and passes through.
    Series::from_float_options("f", [Some(1.0), Some(nan), None]),
    Series::from_ints("i", [1, 2, 3]),
  ])
  let r = df.fill_nan(9.0)
  assert_eq(r.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(9.0),
    @types.Scalar::Null,
  ])
  assert_eq(r.get_column("i").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
}

///|
test "is_finite / is_infinite split NaN, infinity, and the rest" {
  let inf : Double = @double.infinity
  let nan : Double = @double.not_a_number
  let df = DataFrame::DataFrame([
    Series::from_float_options("f", [Some(1.0), Some(nan), Some(inf), None]),
  ])
  assert_eq(
    df.select([@expr.col("f").is_finite()]).get_column("f").to_scalars(),
    [
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(false),
      @types.Scalar::Null,
    ],
  )
  assert_eq(
    df.select([@expr.col("f").is_infinite()]).get_column("f").to_scalars(),
    [
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(true),
      @types.Scalar::Null,
    ],
  )
  // An Int cell is always finite, never infinite; a String operand raises.
  let i = DataFrame::DataFrame([Series::from_ints("i", [3])])
  assert_eq(
    i.select([@expr.col("i").is_finite()]).get_column("i").to_scalars(),
    [@types.Scalar::Bool(true)],
  )
  assert_eq(
    i.select([@expr.col("i").is_infinite()]).get_column("i").to_scalars(),
    [@types.Scalar::Bool(false)],
  )
  let s = DataFrame::DataFrame([Series::from_strings("s", ["a"])])
  assert_true(
    (Ok(s.select([@expr.col("s").is_finite()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  assert_true(
    (Ok(s.select([@expr.col("s").is_infinite()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  // A nullable Int column keeps its nulls under the probe (the `Builtin`
  // arm).
  let ni = DataFrame::DataFrame([Series::from_int_options("i", [Some(1), None])])
  assert_eq(
    ni.select([@expr.col("i").is_finite()]).get_column("i").to_scalars(),
    [@types.Scalar::Bool(true), @types.Scalar::Null],
  )
  // An all-valid Float column takes the numeric fast path.
  let fast = DataFrame::DataFrame([Series::from_floats("f", [1.0, inf])])
  assert_eq(
    fast.select([@expr.col("f").is_finite()]).get_column("f").to_scalars(),
    [@types.Scalar::Bool(true), @types.Scalar::Bool(false)],
  )
}

///|
test "clip clamps into the bounds, nulls and NaN passing through" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1), Some(5), Some(9), None]),
  ])
  assert_eq(
    df
    .select([
      @expr.col("v").clip(lower=@expr.lit_int(2), upper=@expr.lit_int(7)),
    ])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(2),
      @types.Scalar::Int(5),
      @types.Scalar::Int(7),
      @types.Scalar::Null,
    ],
  )
  // One-sided clamps; both omitted is the identity.
  assert_eq(
    df
    .select([@expr.col("v").clip(lower=@expr.lit_int(3))])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(3),
      @types.Scalar::Int(5),
      @types.Scalar::Int(9),
      @types.Scalar::Null,
    ],
  )
  assert_eq(
    df.select([@expr.col("v").clip()]).get_column("v").to_scalars(),
    df.get_column("v").to_scalars(),
  )
  // A Float bound promotes; a NaN cell compares false against both bounds
  // and passes through.
  let nan : Double = @double.not_a_number
  let f = DataFrame::DataFrame([Series::from_floats("f", [0.5, nan, 4.0])])
  let clamped = f
    .select([@expr.col("f").clip(upper=@expr.lit_float(3.0))])
    .get_column("f")
    .to_scalars()
  assert_eq(clamped[0], @types.Scalar::Float(0.5))
  assert_true(clamped[1] is @types.Scalar::Float(v) && v.is_nan())
  assert_eq(clamped[2], @types.Scalar::Float(3.0))
}
