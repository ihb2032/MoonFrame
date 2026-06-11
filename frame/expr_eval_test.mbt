///|
/// Blackbox semantics matrix for the S0 expression evaluator, driven
/// through `DataFrame::with_columns` (the evaluator itself is package
/// private). Covers: the dtype × op arms of `+` and `&`, null propagation
/// from either side, the exhaustive Kleene truth table, NaN-as-a-value,
/// literal broadcast (both sides, pure-literal columns, zero rows), output
/// naming, and every evaluation-time error path.

///|
/// Mixed-dtype frame driving the arithmetic matrix: nullable Int / Float
/// columns (null propagation), all-valid Int / Float (clean arms), plus
/// String / Bool columns for the `TypeMismatch` arms.
fn arith_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("i", [Some(1), None, Some(3)]),
    Series::from_ints("j", [10, 20, 30]),
    Series::from_float_options("f", [Some(0.5), Some(1.5), None]),
    Series::from_floats("g", [100.0, 200.0, 300.0]),
    Series::from_strings("s", ["a", "b", "c"]),
    Series::from_bools("b", [true, false, true]),
  ])
}

///|
/// Two nullable Bool columns whose row pairs enumerate `{T, F, N}²` — the
/// full Kleene grid in one frame.
fn kleene_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_bool_options("p", [
      Some(true),
      Some(true),
      Some(true),
      Some(false),
      Some(false),
      Some(false),
      None,
      None,
      None,
    ]),
    Series::from_bool_options("q", [
      Some(true),
      Some(false),
      None,
      Some(true),
      Some(false),
      None,
      Some(true),
      Some(false),
      None,
    ]),
  ])
}

// ── Arithmetic: dtype arms + null propagation ────────────────────────

///|
test "add Int+Int: elementwise, null propagates from either side" {
  let out = arith_df().with_columns([@expr.col("i") + @expr.col("j")])
  assert_eq(out.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("i").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Null,
    @types.Scalar::Int(33),
  ])
  // Same arm, null arriving from the right operand.
  let flipped = arith_df().with_columns([@expr.col("j") + @expr.col("i")])
  assert_eq(flipped.get_column("j").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Null,
    @types.Scalar::Int(33),
  ])
}

///|
test "add Int+Float and Float+Int: result promotes to Float" {
  let out = arith_df().with_columns([@expr.col("i") + @expr.col("f")])
  assert_eq(out.get_column("i").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("i").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  let out2 = arith_df().with_columns([@expr.col("f") + @expr.col("j")])
  assert_eq(out2.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(out2.get_column("f").to_scalars(), [
    @types.Scalar::Float(10.5),
    @types.Scalar::Float(21.5),
    @types.Scalar::Null,
  ])
}

///|
test "add Float+Float: elementwise with null propagation" {
  let out = arith_df().with_columns([@expr.col("f") + @expr.col("g")])
  assert_eq(out.get_column("f").to_scalars(), [
    @types.Scalar::Float(100.5),
    @types.Scalar::Float(201.5),
    @types.Scalar::Null,
  ])
}

///|
test "add: NaN is a value and propagates through, distinct from null" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::new([Series::from_floats("h", [nan, 1.0])])
  let out = df.with_columns([@expr.col("h") + @expr.lit_float(1.0)])
  assert_true(out.get_column("h").get(0).as_float().is_nan())
  assert_eq(out.get_column("h").get(1), @types.Scalar::Float(2.0))
}

///|
test "add: non-numeric operands raise TypeMismatch at evaluation" {
  assert_eq(
    try? arith_df().with_columns([@expr.col("s") + @expr.col("j")]),
    Err(@types.DataError::TypeMismatch("cannot add String and Int")),
  )
  assert_eq(
    try? arith_df().with_columns([@expr.col("b") + @expr.col("b")]),
    Err(@types.DataError::TypeMismatch("cannot add Bool and Bool")),
  )
}

// ── Logic: Kleene AND ────────────────────────────────────────────────

///|
test "and: exhaustive Kleene truth table over {T,F,N}²" {
  let out = kleene_df().with_columns([@expr.col("p") & @expr.col("q")])
  assert_eq(out.get_column("p").to_scalars(), [
    @types.Scalar::Bool(true), // T & T
    @types.Scalar::Bool(false), // T & F
    @types.Scalar::Null, // T & N
    @types.Scalar::Bool(false), // F & T
    @types.Scalar::Bool(false), // F & F
    @types.Scalar::Bool(false), // F & N  (false dominates)
    @types.Scalar::Null, // N & T
    @types.Scalar::Bool(false), // N & F  (false dominates)
    @types.Scalar::Null, // N & N
  ])
}

///|
test "and: a literal false dominates every row, nulls included" {
  let out = kleene_df().with_columns([@expr.col("p") & @expr.lit_bool(false)])
  assert_eq(
    out.get_column("p").to_scalars(),
    Array::make(9, @types.Scalar::Bool(false)),
  )
}

///|
test "and: non-Bool operands raise TypeMismatch at evaluation" {
  assert_eq(
    try? arith_df().with_columns([@expr.col("b") & @expr.col("j")]),
    Err(
      @types.DataError::TypeMismatch(
        "logical 'and' requires Bool operands, got Bool and Int",
      ),
    ),
  )
  assert_eq(
    try? arith_df().with_columns([@expr.col("j") & @expr.col("b")]),
    Err(
      @types.DataError::TypeMismatch(
        "logical 'and' requires Bool operands, got Int and Bool",
      ),
    ),
  )
}

// ── Literals and broadcast ───────────────────────────────────────────

///|
test "literal broadcast: length-1 stretches to the column side" {
  let out = arith_df().with_columns([@expr.col("j") + @expr.lit_int(5)])
  assert_eq(out.get_column("j").to_scalars(), [
    @types.Scalar::Int(15),
    @types.Scalar::Int(25),
    @types.Scalar::Int(35),
  ])
  // Literal on the left: same values, and the output is still named after
  // the leftmost *column* reference, found through the literal.
  let flipped = arith_df().with_columns([@expr.lit_int(5) + @expr.col("j")])
  assert_eq(flipped.get_column("j").to_scalars(), [
    @types.Scalar::Int(15),
    @types.Scalar::Int(25),
    @types.Scalar::Int(35),
  ])
  // Int literal against a Float column promotes.
  let promoted = arith_df().with_columns([@expr.col("g") + @expr.lit_int(1)])
  assert_eq(promoted.get_column("g").to_scalars(), [
    @types.Scalar::Float(101.0),
    @types.Scalar::Float(201.0),
    @types.Scalar::Float(301.0),
  ])
}

///|
test "pure-literal expressions append a broadcast 'literal' column" {
  let out = arith_df().with_columns([@expr.lit_int(1) + @expr.lit_int(2)])
  assert_eq(out.get_column("literal").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(3),
    @types.Scalar::Int(3),
  ])
  let strs = arith_df().with_columns([@expr.lit_str("x")])
  assert_eq(
    strs.get_column("literal").to_scalars(),
    Array::make(3, @types.Scalar::String("x")),
  )
  let bools = arith_df().with_columns([@expr.lit_bool(true)])
  assert_eq(
    bools.get_column("literal").to_scalars(),
    Array::make(3, @types.Scalar::Bool(true)),
  )
}

///|
test "empty frame: column exprs and literals broadcast to zero rows" {
  let df = DataFrame::new([Series::from_ints("a", [])])
  let out = df.with_columns([@expr.col("a") + @expr.lit_int(1)])
  assert_eq(out.nrows(), 0)
  assert_eq(out.get_column("a").len(), 0)
  let lit_left = df.with_columns([@expr.lit_int(1) + @expr.col("a")])
  assert_eq(lit_left.get_column("a").len(), 0)
  let pure = df.with_columns([@expr.lit_int(7)])
  assert_eq(pure.get_column("literal").len(), 0)
  assert_eq(pure.check_invariants(), Ok(()))
}

// ── Errors and naming ────────────────────────────────────────────────

///|
test "null literal raises Unsupported at evaluation" {
  assert_eq(
    try? arith_df().with_columns([@expr.lit(@types.Scalar::Null)]),
    Err(
      @types.DataError::Unsupported(
        "cannot evaluate a Null literal: no Null-dtype column backend",
      ),
    ),
  )
}

///|
test "unknown column raises ColumnNotFound at evaluation" {
  assert_eq(
    try? arith_df().with_columns([@expr.col("zzz") + @expr.col("j")]),
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
}

///|
test "nested trees evaluate depth-first and keep the leftmost name" {
  let out = arith_df().with_columns([
    @expr.col("i") + @expr.col("j") + @expr.lit_int(100),
  ])
  assert_eq(out.get_column("i").to_scalars(), [
    @types.Scalar::Int(111),
    @types.Scalar::Null,
    @types.Scalar::Int(133),
  ])
}
