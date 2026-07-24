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
test "modulo at Int64::MIN % -1 is zero" {
  assert_eq(extremes_result((a, b) => a.modulo(b)), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
  ])
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
