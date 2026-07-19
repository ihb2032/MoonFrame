///|
/// Blackbox semantics matrix for the vectorized expression evaluator,
/// driven through `DataFrame::with_columns` (the evaluator itself is
/// package private). Covers the full dtype × op × null/NaN grid:
/// arithmetic (`Int`/`Float` promotion, `/` always-`Float` with IEEE
/// division by zero, wrap-not-abort negation), all six comparisons per
/// dtype (IEEE NaN, dictionary-order strings, `false < true`), the
/// exhaustive Kleene tables for `&` / `|` / `not`, the total null probes,
/// every aggregation cross-checked against its `Series` reduction (NaN
/// propagate vs skip, all-null reductions), `cast` delegation,
/// `when/then/otherwise` selection, literal broadcast (both sides,
/// pure-literal columns, zero rows), the computed-result backend
/// convention, output naming, and every evaluation-time error path.

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
    Ok(arith_df().with_columns([@expr.col("s") + @expr.col("j")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "add",
        @types.DataType::String,
        @types.DataType::Int,
      ),
    ),
  )
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("b") + @expr.col("b")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "add",
        @types.DataType::Bool,
        @types.DataType::Bool,
      ),
    ),
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
    Ok(arith_df().with_columns([@expr.col("b") & @expr.col("j")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        "logical 'and' requires Bool operands, got Bool and Int",
      ),
    ),
  )
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("j") & @expr.col("b")])) catch {
      e => Err(e)
    },
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
    Ok(arith_df().with_columns([@expr.lit(@types.Scalar::Null)])) catch {
      e => Err(e)
    },
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
    Ok(arith_df().with_columns([@expr.col("zzz") + @expr.col("j")])) catch {
      e => Err(e)
    },
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

// ── Arithmetic: subtraction / multiplication ─────────────────────────

///|
test "subtract: orientation, dtype arms, and null propagation" {
  // Not commutative, so the values pin the operand order.
  let out = arith_df().with_columns([@expr.col("j") - @expr.col("i")])
  assert_eq(out.get_column("j").to_scalars(), [
    @types.Scalar::Int(9),
    @types.Scalar::Null,
    @types.Scalar::Int(27),
  ])
  let mixed = arith_df().with_columns([@expr.col("g") - @expr.col("i")])
  assert_eq(mixed.get_column("g").dtype(), @types.DataType::Float)
  assert_eq(mixed.get_column("g").to_scalars(), [
    @types.Scalar::Float(99.0),
    @types.Scalar::Null,
    @types.Scalar::Float(297.0),
  ])
}

///|
test "multiply: dtype arms and null propagation" {
  let out = arith_df().with_columns([@expr.col("i") * @expr.col("j")])
  assert_eq(out.get_column("i").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Null,
    @types.Scalar::Int(90),
  ])
  let promoted = arith_df().with_columns([@expr.col("f") * @expr.lit_int(2)])
  assert_eq(promoted.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Null,
  ])
}

///|
test "subtract/multiply: non-numeric operands raise with their own verb" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("s") - @expr.col("j")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "subtract",
        @types.DataType::String,
        @types.DataType::Int,
      ),
    ),
  )
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("b") * @expr.col("b")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "multiply",
        @types.DataType::Bool,
        @types.DataType::Bool,
      ),
    ),
  )
}

// ── Division: always Float, IEEE division by zero ────────────────────

///|
test "divide: every numeric pair produces Float" {
  // Int / Int — the arm that makes `/` not an `eval_arith` instance.
  let ii = arith_df().with_columns([@expr.col("j") / @expr.col("i")])
  assert_eq(ii.get_column("j").dtype(), @types.DataType::Float)
  assert_eq(ii.get_column("j").to_scalars(), [
    @types.Scalar::Float(10.0),
    @types.Scalar::Null,
    @types.Scalar::Float(10.0),
  ])
  let if_ = arith_df().with_columns([@expr.col("i") / @expr.col("f")])
  assert_eq(if_.get_column("i").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  let fi = arith_df().with_columns([@expr.col("g") / @expr.col("j")])
  assert_eq(
    fi.get_column("g").to_scalars(),
    Array::make(3, @types.Scalar::Float(10.0)),
  )
  // Float / Int with a null on the Float side.
  let fi_null = arith_df().with_columns([@expr.col("f") / @expr.col("j")])
  assert_eq(fi_null.get_column("f").to_scalars(), [
    @types.Scalar::Float(0.05),
    @types.Scalar::Float(0.075),
    @types.Scalar::Null,
  ])
  let ff = arith_df().with_columns([@expr.col("f") / @expr.col("g")])
  assert_eq(ff.get_column("f").to_scalars(), [
    @types.Scalar::Float(0.005),
    @types.Scalar::Float(0.0075),
    @types.Scalar::Null,
  ])
}

///|
test "divide by zero follows IEEE 754: ±inf and NaN, never a trap" {
  let signs = DataFrame::new([Series::from_ints("v", [10, -10])])
  let out = signs.with_columns([@expr.col("v") / @expr.lit_int(0)])
  assert_eq(out.get_column("v").to_scalars(), [
    @types.Scalar::Float(@double.infinity),
    @types.Scalar::Float(@double.neg_infinity),
  ])
  let zz = signs.with_columns([
    (@expr.lit_float(0.0) / @expr.lit_float(0.0)).with_alias("nan"),
  ])
  assert_true(zz.get_column("nan").get(0).as_float().is_nan())
}

///|
test "divide: non-numeric operands raise TypeMismatch" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("s") / @expr.col("j")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "divide",
        @types.DataType::String,
        @types.DataType::Int,
      ),
    ),
  )
}

// ── Negation ─────────────────────────────────────────────────────────

///|
test "negate: Int and Float arms, null propagation, nesting" {
  let ints = arith_df().with_columns([-@expr.col("i")])
  assert_eq(ints.get_column("i").to_scalars(), [
    @types.Scalar::Int(-1),
    @types.Scalar::Null,
    @types.Scalar::Int(-3),
  ])
  let floats = arith_df().with_columns([-@expr.col("f")])
  assert_eq(floats.get_column("f").to_scalars(), [
    @types.Scalar::Float(-0.5),
    @types.Scalar::Float(-1.5),
    @types.Scalar::Null,
  ])
  // Double negation round-trips.
  let back = arith_df().with_columns([-(-@expr.col("j"))])
  assert_eq(back.get_column("j").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
}

///|
test "negate: non-numeric operand raises TypeMismatch" {
  assert_eq(
    Ok(arith_df().with_columns([-@expr.col("b")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::TypeMismatch("cannot negate Bool")),
  )
}

// ── Comparisons ──────────────────────────────────────────────────────

///|
/// Nullable-Int against all-valid Int: drives all six comparison verbs
/// over `<` / `=` / `>` / null rows in one frame.
fn cmp_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("x", [Some(1), Some(2), Some(3), None]),
    Series::from_ints("y", [2, 2, 1, 5]),
  ])
}

///|
test "compare Int-Int: all six verbs, with null propagation" {
  fn run(e : @expr.Expr) -> Array[@types.Scalar] raise @types.DataError {
    cmp_df().with_columns([e.with_alias("r")]).get_column("r").to_scalars()
  }

  let t = @types.Scalar::Bool(true)
  let f = @types.Scalar::Bool(false)
  let n = @types.Scalar::Null
  assert_eq(run(@expr.col("x").lt(@expr.col("y"))), [t, f, f, n])
  assert_eq(run(@expr.col("x").le(@expr.col("y"))), [t, t, f, n])
  assert_eq(run(@expr.col("x").gt(@expr.col("y"))), [f, f, t, n])
  assert_eq(run(@expr.col("x").ge(@expr.col("y"))), [f, t, t, n])
  assert_eq(run(@expr.col("x").eq(@expr.col("y"))), [f, t, f, n])
  assert_eq(run(@expr.col("x").ne(@expr.col("y"))), [t, f, t, n])
}

///|
test "compare: comparison output is Bool dtype" {
  let out = cmp_df().with_columns([
    @expr.col("x").lt(@expr.col("y")).with_alias("r"),
  ])
  assert_eq(out.get_column("r").dtype(), @types.DataType::Bool)
}

///|
test "compare Float: NaN is a value under IEEE 754 — non-null, all-false orderings" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::new([
    Series::from_floats("h", [nan, 1.0]),
    Series::from_floats("k", [nan, nan]),
  ])
  fn run(e : @expr.Expr) -> Array[@types.Scalar] raise @types.DataError {
    df.with_columns([e.with_alias("r")]).get_column("r").to_scalars()
  }

  let t = @types.Scalar::Bool(true)
  let f = @types.Scalar::Bool(false)
  // NaN == NaN is false (not null!), so ne is true and every ordering
  // comparison involving NaN is false.
  assert_eq(run(@expr.col("h").eq(@expr.col("k"))), [f, f])
  assert_eq(run(@expr.col("h").ne(@expr.col("k"))), [t, t])
  assert_eq(run(@expr.col("h").lt(@expr.col("k"))), [f, f])
  assert_eq(run(@expr.col("h").le(@expr.col("k"))), [f, f])
  assert_eq(run(@expr.col("h").gt(@expr.col("k"))), [f, f])
  assert_eq(run(@expr.col("h").ge(@expr.col("k"))), [f, f])
}

///|
test "compare across Int and Float: both promotion arms" {
  // Int column on the left of a Float column.
  let out = arith_df().with_columns([
    @expr.col("i").lt(@expr.col("f")).with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(false), // 1 < 0.5
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // Float column on the left of an Int literal.
  let out2 = arith_df().with_columns([
    @expr.col("g").ge(@expr.lit_int(200)).with_alias("r"),
  ])
  assert_eq(out2.get_column("r").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
  ])
  // Equality across the promotion: an Int cell can equal a Float literal.
  let out3 = arith_df().with_columns([
    @expr.col("i").eq(@expr.lit_float(1.0)).with_alias("r"),
  ])
  assert_eq(out3.get_column("r").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "compare String: dictionary order, not MoonBit's shortlex" {
  let df = DataFrame::new([
    Series::from_string_options("u", [Some("fig"), Some("apple"), None]),
    Series::from_strings("v", ["apple", "apple", "pear"]),
  ])
  fn run(e : @expr.Expr) -> Array[@types.Scalar] raise @types.DataError {
    df.with_columns([e.with_alias("r")]).get_column("r").to_scalars()
  }

  let t = @types.Scalar::Bool(true)
  let f = @types.Scalar::Bool(false)
  let n = @types.Scalar::Null
  // Builtin shortlex would call "fig" < "apple" (shorter first); the
  // dictionary order the evaluator uses says it is greater.
  assert_eq(run(@expr.col("u").gt(@expr.col("v"))), [t, f, n])
  assert_eq(run(@expr.col("u").lt(@expr.col("v"))), [f, f, n])
  assert_eq(run(@expr.col("u").eq(@expr.col("v"))), [f, t, n])
}

///|
test "compare Bool: false < true" {
  let df = DataFrame::new([
    Series::from_bool_options("p", [Some(false), Some(true), None]),
  ])
  fn run(e : @expr.Expr) -> Array[@types.Scalar] raise @types.DataError {
    df.with_columns([e.with_alias("r")]).get_column("r").to_scalars()
  }

  let t = @types.Scalar::Bool(true)
  let f = @types.Scalar::Bool(false)
  let n = @types.Scalar::Null
  assert_eq(run(@expr.col("p").lt(@expr.lit_bool(true))), [t, f, n])
  assert_eq(run(@expr.col("p").ge(@expr.lit_bool(true))), [f, t, n])
  assert_eq(run(@expr.col("p").eq(@expr.lit_bool(false))), [t, f, n])
}

///|
test "compare: non-comparable dtype pairs raise TypeMismatch" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("s").lt(@expr.col("j"))])) catch {
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
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("b").eq(@expr.col("f"))])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::OpTypeMismatch(
        "compare",
        @types.DataType::Bool,
        @types.DataType::Float,
      ),
    ),
  )
}

// ── Logic: Kleene OR and NOT ─────────────────────────────────────────

///|
test "or: exhaustive Kleene truth table over {T,F,N}²" {
  let out = kleene_df().with_columns([@expr.col("p") | @expr.col("q")])
  assert_eq(out.get_column("p").to_scalars(), [
    @types.Scalar::Bool(true), // T | T
    @types.Scalar::Bool(true), // T | F
    @types.Scalar::Bool(true), // T | N  (true dominates)
    @types.Scalar::Bool(true), // F | T
    @types.Scalar::Bool(false), // F | F
    @types.Scalar::Null, // F | N
    @types.Scalar::Bool(true), // N | T  (true dominates)
    @types.Scalar::Null, // N | F
    @types.Scalar::Null, // N | N
  ])
}

///|
test "or: a literal true dominates every row, nulls included" {
  let out = kleene_df().with_columns([@expr.col("p") | @expr.lit_bool(true)])
  assert_eq(
    out.get_column("p").to_scalars(),
    Array::make(9, @types.Scalar::Bool(true)),
  )
}

///|
test "or: non-Bool operands raise TypeMismatch with the 'or' verb" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("j") | @expr.col("b")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        "logical 'or' requires Bool operands, got Int and Bool",
      ),
    ),
  )
}

///|
test "not: Kleene negation over {T,F,N}, and double negation round-trips" {
  let out = kleene_df().with_columns([@expr.col("p").not()])
  assert_eq(out.get_column("p").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  let back = kleene_df().with_columns([@expr.col("p").not().not()])
  assert_eq(back.get_column("p"), kleene_df().get_column("p"))
}

///|
test "not: non-Bool operand raises TypeMismatch" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("i").not()])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        "logical 'not' requires a Bool operand, got Int",
      ),
    ),
  )
}

// ── Null probes ──────────────────────────────────────────────────────

///|
test "is_null / is_not_null: read validity, never produce a null" {
  let probed = arith_df().with_columns([
    @expr.col("i").is_null().with_alias("inull"),
    @expr.col("i").is_not_null().with_alias("ival"),
    // An all-valid Numeric-backed column probes all-false / all-true.
    @expr.col("j").is_null().with_alias("jnull"),
  ])
  assert_eq(probed.get_column("inull").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
  assert_eq(probed.get_column("ival").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
  assert_eq(
    probed.get_column("jnull").to_scalars(),
    Array::make(3, @types.Scalar::Bool(false)),
  )
  assert_eq(probed.get_column("inull").null_count(), 0)
}

///|
test "is_nan / is_not_nan: NaN is a value, nulls propagate, Int is never NaN" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::new([
    Series::from_float_options("f", [Some(1.0), Some(nan), None]),
    Series::from_int_options("i", [Some(5), None, Some(7)]),
  ])
  let out = df.with_columns([
    @expr.col("f").is_nan().with_alias("fnan"),
    @expr.col("f").is_not_nan().with_alias("fnn"),
    @expr.col("i").is_nan().with_alias("inan"),
  ])
  // Float: finite -> false, NaN -> true, null -> null (the probe propagates).
  assert_eq(out.get_column("fnan").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("fnn").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  // Int is never NaN: present cells -> false, null -> null.
  assert_eq(out.get_column("inan").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "is_nan / is_not_nan: a non-numeric operand raises TypeMismatch" {
  let df = DataFrame::new([Series::from_strings("s", ["a"])])
  assert_true(
    (Ok(df.with_columns([@expr.col("s").is_nan()])) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (Ok(df.with_columns([@expr.col("s").is_not_nan()])) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "fill_nan: replaces NaN, keeps finite and null cells, named after self" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::new([
    Series::from_float_options("x", [Some(1.5), Some(nan), None]),
  ])
  let out = df.with_columns([@expr.col("x").fill_nan(@expr.lit_float(0.0))])
  // NaN -> 0.0; finite kept; a true null stays null (fill_nan fills only NaN).
  assert_eq(out.get_column("x").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(0.0),
    @types.Scalar::Null,
  ])
  assert_eq(out.columns(), ["x"])
}

///|
test "fill_null / fill_nan evaluate exactly like their guarded-ternary spelling" {
  // The dedicated nodes must be cell-for-cell (dtype and backend) equal to
  // the ternary they replaced — including the Int-meets-Float promotion and
  // the Kleene null-condition fallthrough. Two single-column frames so the
  // whole-frame Eq is meaningful: a NaN cell surviving into both outputs
  // would compare unequal to itself (IEEE), and the fill_nan output holds
  // none.
  let nan : Double = @double.not_a_number
  let df_i = DataFrame::new([
    Series::from_int_options("i", [Some(1), None, Some(3)]),
  ])
  assert_eq(
    df_i.with_columns([@expr.col("i").fill_null(@expr.lit_float(0.5))]),
    df_i.with_columns([
      @expr.when(@expr.col("i").is_not_null())
      .then(@expr.col("i"))
      .otherwise(@expr.lit_float(0.5)),
    ]),
  )
  let df_f = DataFrame::new([
    Series::from_float_options("f", [Some(1.5), Some(nan), None]),
  ])
  assert_eq(
    df_f.with_columns([@expr.col("f").fill_nan(@expr.lit_float(0.0))]),
    df_f.with_columns([
      @expr.when(@expr.col("f").is_not_nan())
      .then(@expr.col("f"))
      .otherwise(@expr.lit_float(0.0)),
    ]),
  )
  // Mismatched branch dtypes raise the same TypeMismatch either way.
  assert_true(
    (Ok(df_i.with_columns([@expr.col("i").fill_null(@expr.lit_str("?"))])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a chained fill_null coalesce evaluates in linear work" {
  // 24 chained fills over a nullable column: the old ternary lowering
  // re-evaluated the base subtree 2^24 times (an effective hang); the
  // dedicated node evaluates each link once. The first fill already leaves
  // no null, so the later links are no-ops value-wise.
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3)]),
  ])
  let mut e = @expr.col("a").fill_null(@expr.lit_int(0))
  for _ in 1..<=23 {
    e = e.fill_null(@expr.lit_int(9))
  }
  let out = df.with_columns([e])
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
    @types.Scalar::Int(3),
  ])
}

// ── Aggregations ─────────────────────────────────────────────────────

///|
test "sum: skips nulls, matches Series::sum, broadcasts over the frame" {
  let df = arith_df()
  let out = df.with_columns([@expr.col("i").sum().with_alias("total")])
  // 1 + 3, the null skipped — and the length-1 result stretches to nrows.
  assert_eq(
    out.get_column("total").to_scalars(),
    Array::make(3, @types.Scalar::Int(4)),
  )
  assert_eq(out.get_column("total").get(0), df.get_column("i").sum())
  // Float sum propagates NaN: it is a value, not a missing cell.
  let nan : Double = @double.not_a_number
  let nans = DataFrame::new([Series::from_floats("h", [nan, 1.0])])
  let nsum = nans.with_columns([@expr.col("h").sum().with_alias("t")])
  assert_true(nsum.get_column("t").get(0).as_float().is_nan())
}

///|
test "sum: non-numeric operand raises TypeMismatch" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("s").sum()])) catch {
      e => Err(e)
    },
    Err(@types.DataError::TypeMismatch("sum undefined for String")),
  )
}

///|
test "mean: Int and Float operands reduce to Float, NaN propagates" {
  let out = arith_df().with_columns([
    @expr.col("j").mean().with_alias("jm"),
    @expr.col("i").mean().with_alias("im"), // nulls excluded: (1+3)/2
    @expr.col("f").mean().with_alias("fm"),
  ])
  assert_eq(
    out.get_column("jm").to_scalars(),
    Array::make(3, @types.Scalar::Float(20.0)),
  )
  assert_eq(
    out.get_column("im").to_scalars(),
    Array::make(3, @types.Scalar::Float(2.0)),
  )
  assert_eq(
    out.get_column("fm").to_scalars(),
    Array::make(3, @types.Scalar::Float(1.0)),
  )
  let nan : Double = @double.not_a_number
  let nans = DataFrame::new([Series::from_floats("h", [nan, 1.0])])
  let nmean = nans.with_columns([@expr.col("h").mean().with_alias("m")])
  assert_true(nmean.get_column("m").get(0).as_float().is_nan())
}

///|
test "mean: an all-null operand yields a null cell, not an error" {
  // The deliberate divergence from Series::mean (which raises
  // InvalidOperation): a reduction slot must exist for an all-null group.
  let df = DataFrame::new([
    Series::from_int_options("n", [None, None]),
    Series::from_ints("k", [1, 2]),
  ])
  let out = df.with_columns([@expr.col("n").mean().with_alias("m")])
  assert_eq(
    out.get_column("m").to_scalars(),
    Array::make(2, @types.Scalar::Null),
  )
  assert_eq(out.get_column("m").dtype(), @types.DataType::Float)
}

///|
test "mean: non-numeric operand raises TypeMismatch" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("b").mean()])) catch {
      e => Err(e)
    },
    Err(@types.DataError::TypeMismatch("mean undefined for Bool")),
  )
}

///|
test "min/max: skip nulls and NaN, match the Series reductions, keep the dtype" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::new([
    Series::from_int_options("i", [Some(3), None, Some(1)]),
    Series::from_floats("h", [nan, 2.0, 1.0]),
    Series::from_strings("s", ["fig", "apple", "pear"]),
    Series::from_bools("b", [true, false, true]),
  ])
  let out = df.with_columns([
    @expr.col("i").min().with_alias("imin"),
    @expr.col("i").max().with_alias("imax"),
    @expr.col("h").min().with_alias("hmin"), // NaN skipped
    @expr.col("h").max().with_alias("hmax"),
    @expr.col("s").min().with_alias("smin"), // dictionary order
    @expr.col("b").min().with_alias("bmin"), // false < true
    @expr.col("b").max().with_alias("bmax"),
  ])
  assert_eq(out.get_column("imin").get(0), @types.Scalar::Int(1))
  assert_eq(out.get_column("imax").get(0), @types.Scalar::Int(3))
  assert_eq(out.get_column("hmin").get(0), @types.Scalar::Float(1.0))
  assert_eq(out.get_column("hmax").get(0), @types.Scalar::Float(2.0))
  assert_eq(out.get_column("smin").get(0), @types.Scalar::String("apple"))
  assert_eq(out.get_column("bmin").get(0), @types.Scalar::Bool(false))
  assert_eq(out.get_column("bmax").get(0), @types.Scalar::Bool(true))
  assert_eq(out.get_column("imin").get(0), df.get_column("i").min())
  assert_eq(out.get_column("hmax").get(0), df.get_column("h").max())
}

///|
test "min/max: empty reductions produce a null cell in every dtype" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::new([
    Series::from_int_options("i", [None, None]),
    Series::from_floats("h", [nan, nan]), // all-NaN Float reduces to null
    Series::from_string_options("s", [None, None]),
    Series::from_bool_options("b", [None, None]),
  ])
  let out = df.with_columns([
    @expr.col("i").min().with_alias("imin"),
    @expr.col("h").max().with_alias("hmax"),
    @expr.col("s").min().with_alias("smin"),
    @expr.col("b").max().with_alias("bmax"),
  ])
  assert_eq(out.get_column("imin").get(0), @types.Scalar::Null)
  assert_eq(out.get_column("hmax").get(0), @types.Scalar::Null)
  assert_eq(out.get_column("smin").get(0), @types.Scalar::Null)
  assert_eq(out.get_column("bmax").get(0), @types.Scalar::Null)
  // The dtype survives the empty reduction.
  assert_eq(out.get_column("imin").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("smin").dtype(), @types.DataType::String)
}

///|
test "count: non-null cells, never null" {
  let out = arith_df().with_columns([
    @expr.col("i").count().with_alias("ic"),
    @expr.col("j").count().with_alias("jc"),
    @expr.col("s").count().with_alias("sc"), // count is dtype-agnostic
  ])
  assert_eq(
    out.get_column("ic").to_scalars(),
    Array::make(3, @types.Scalar::Int(2)),
  )
  assert_eq(
    out.get_column("jc").to_scalars(),
    Array::make(3, @types.Scalar::Int(3)),
  )
  assert_eq(
    out.get_column("sc").to_scalars(),
    Array::make(3, @types.Scalar::Int(3)),
  )
}

///|
test "composite aggregation: reduce a derived column" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_ints("b", [4, 5, 6]),
  ])
  let out = df.with_columns([
    (@expr.col("a") * @expr.col("b")).sum().with_alias("dot"),
    (@expr.col("a").max() - @expr.col("a").min()).with_alias("range"),
  ])
  // 1·4 + 2·5 + 3·6 — the inner product a single-column reduction cannot
  // express.
  assert_eq(
    out.get_column("dot").to_scalars(),
    Array::make(3, @types.Scalar::Int(32)),
  )
  // An arithmetic of two reductions stays length-1 before broadcast.
  assert_eq(
    out.get_column("range").to_scalars(),
    Array::make(3, @types.Scalar::Int(2)),
  )
}

///|
test "aggregations on an empty frame broadcast to zero rows" {
  let df = DataFrame::new([Series::from_ints("a", [])])
  let out = df.with_columns([
    @expr.col("a").sum().with_alias("t"),
    @expr.col("a").count().with_alias("n"),
    @expr.col("a").min().with_alias("m"),
    @expr.col("a").mean().with_alias("avg"),
  ])
  assert_eq(out.nrows(), 0)
  assert_eq(out.get_column("t").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("avg").dtype(), @types.DataType::Float)
  assert_eq(out.check_invariants(), Ok(()))
}

// ── Cast ─────────────────────────────────────────────────────────────

///|
test "cast: delegates to Series::cast, preserving nulls" {
  let widened = arith_df().with_columns([
    @expr.col("i").cast(@types.DataType::Float).with_alias("if"),
    @expr.col("f").cast(@types.DataType::Int).with_alias("fi"), // truncates
    @expr.col("j").cast(@types.DataType::String).with_alias("js"),
  ])
  assert_eq(widened.get_column("if").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Null,
    @types.Scalar::Float(3.0),
  ])
  assert_eq(widened.get_column("fi").to_scalars(), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  assert_eq(widened.get_column("js").to_scalars(), [
    @types.Scalar::String("10"),
    @types.Scalar::String("20"),
    @types.Scalar::String("30"),
  ])
}

///|
test "cast: unsupported targets and impossible casts surface unchanged" {
  assert_eq(
    Ok(arith_df().with_columns([@expr.col("i").cast(@types.DataType::Bool)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::Unsupported("cast to Bool")),
  )
  // The delegate's own diagnostics pass through: NaN cannot become Int.
  let nan : Double = @double.not_a_number
  assert_eq(
    Ok(
      arith_df().with_columns([@expr.lit_float(nan).cast(@types.DataType::Int)]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message("cannot cast NaN to Int"),
      ),
    ),
  )
}

// ── when / then / otherwise ──────────────────────────────────────────

///|
test "ternary: true, false, null condition, and null branch cell in one frame" {
  let df = DataFrame::new([
    Series::from_bool_options("c", [Some(true), Some(false), None, Some(true)]),
    Series::from_int_options("t", [Some(1), Some(2), Some(3), None]),
    Series::from_ints("e", [10, 20, 30, 40]),
  ])
  let out = df.with_columns([
    @expr.when(@expr.col("c"))
    .then(@expr.col("t"))
    .otherwise(@expr.col("e"))
    .with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Int(1), // true  → then
    @types.Scalar::Int(20), // false → otherwise
    @types.Scalar::Null, // null condition → null
    @types.Scalar::Null, // true → then, whose cell is null
  ])
}

///|
test "ternary: Int and Float branches unify to Float, either orientation" {
  let df = DataFrame::new([
    Series::from_bools("c", [true, false]),
    Series::from_ints("i", [1, 2]),
    Series::from_floats("f", [0.5, 0.25]),
  ])
  let out = df.with_columns([
    @expr.when(@expr.col("c"))
    .then(@expr.col("i"))
    .otherwise(@expr.col("f"))
    .with_alias("if_"),
    @expr.when(@expr.col("c"))
    .then(@expr.col("f"))
    .otherwise(@expr.col("i"))
    .with_alias("fi_"),
  ])
  assert_eq(out.get_column("if_").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(0.25),
  ])
  assert_eq(out.get_column("fi_").to_scalars(), [
    @types.Scalar::Float(0.5),
    @types.Scalar::Float(2.0),
  ])
}

///|
test "ternary: Float, Bool, and String branch arms select elementwise" {
  let df = DataFrame::new([
    Series::from_bools("c", [true, false]),
    Series::from_floats("f", [1.5, 2.5]),
    Series::from_bools("p", [false, false]),
    Series::from_strings("s", ["yes", "no"]),
  ])
  let out = df.with_columns([
    @expr.when(@expr.col("c"))
    .then(@expr.col("f"))
    .otherwise(@expr.lit_float(0.0))
    .with_alias("ff"),
    @expr.when(@expr.col("c"))
    .then(@expr.lit_bool(true))
    .otherwise(@expr.col("p"))
    .with_alias("bb"),
    @expr.when(@expr.col("c"))
    .then(@expr.col("s"))
    .otherwise(@expr.lit_str("-"))
    .with_alias("ss"),
  ])
  assert_eq(out.get_column("ff").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(0.0),
  ])
  assert_eq(out.get_column("bb").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
  assert_eq(out.get_column("ss").to_scalars(), [
    @types.Scalar::String("yes"),
    @types.Scalar::String("-"),
  ])
}

///|
test "ternary: the grade demo — literal branches against a column condition" {
  let df = DataFrame::new([Series::from_ints("score", [55, 60, 90])])
  let out = df.with_columns([
    @expr.when(@expr.col("score").ge(@expr.lit_int(60)))
    .then(@expr.lit_str("pass"))
    .otherwise(@expr.lit_str("fail"))
    .with_alias("grade"),
  ])
  assert_eq(out.get_column("grade").to_scalars(), [
    @types.Scalar::String("fail"),
    @types.Scalar::String("pass"),
    @types.Scalar::String("pass"),
  ])
}

///|
test "ternary: literal condition and then-branch stretch to the otherwise column" {
  // cond and then are length-1, otherwise is column-length: the one shape
  // where the then branch needs its own stretch after the two pair passes.
  let out = arith_df().with_columns([
    @expr.when(@expr.lit_bool(true))
    .then(@expr.lit_int(-1))
    .otherwise(@expr.col("j"))
    .with_alias("r"),
  ])
  assert_eq(
    out.get_column("r").to_scalars(),
    Array::make(3, @types.Scalar::Int(-1)),
  )
  let flipped = arith_df().with_columns([
    @expr.when(@expr.lit_bool(false))
    .then(@expr.lit_int(-1))
    .otherwise(@expr.col("j"))
    .with_alias("r"),
  ])
  assert_eq(flipped.get_column("r").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
}

///|
test "ternary: a non-Bool condition raises TypeMismatch" {
  assert_eq(
    Ok(
      arith_df().with_columns([
        @expr.when(@expr.col("j"))
        .then(@expr.lit_int(1))
        .otherwise(@expr.lit_int(0)),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::TypeMismatch("when condition must be Bool, got Int")),
  )
}

///|
test "ternary: branches that do not unify raise TypeMismatch" {
  assert_eq(
    Ok(
      arith_df().with_columns([
        @expr.when(@expr.col("b"))
        .then(@expr.lit_int(1))
        .otherwise(@expr.lit_str("x")),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        "when/then/otherwise branches do not unify: Int and String",
      ),
    ),
  )
}

///|
test "ternary: a null branch cell nulls the output (Int and Int×Float arms)" {
  // The other ternary tests put a null only in the *then* branch and leave
  // the *otherwise* column fully valid, so each arm's otherwise-branch null
  // path — and the Int×Float / Float×Int then-branch null path — never ran.
  // Here every *selected* branch cell is null: row 0 takes `then` (null),
  // row 1 takes `otherwise` (null), so both branch readers' `else { None }`
  // arms fire and the output is null on both rows.
  let df = DataFrame::new([
    Series::from_bools("c", [true, false]),
    Series::from_int_options("ai", [None, Some(2)]),
    Series::from_int_options("bi", [Some(9), None]),
    Series::from_float_options("af", [None, Some(2.0)]),
    Series::from_float_options("bf", [Some(9.0), None]),
  ])
  let out = df.with_columns([
    @expr.when(@expr.col("c"))
    .then(@expr.col("ai"))
    .otherwise(@expr.col("bi"))
    .with_alias("ii"),
    @expr.when(@expr.col("c"))
    .then(@expr.col("ai"))
    .otherwise(@expr.col("bf"))
    .with_alias("if_"),
    @expr.when(@expr.col("c"))
    .then(@expr.col("af"))
    .otherwise(@expr.col("bi"))
    .with_alias("fi_"),
  ])
  let both_null = [@types.Scalar::Null, @types.Scalar::Null]
  assert_eq(out.get_column("ii").to_scalars(), both_null)
  assert_eq(out.get_column("if_").to_scalars(), both_null)
  assert_eq(out.get_column("fi_").to_scalars(), both_null)
}

///|
test "ternary: a null branch cell nulls the output (Float, Bool, String arms)" {
  // Same idea for the remaining arms: a null `then` cell (row 0, condition
  // true) and a null `otherwise` cell (row 1, condition false) exercise the
  // `else { None }` arm of both branch readers for Float, Bool, and String.
  let df = DataFrame::new([
    Series::from_bools("c", [true, false]),
    Series::from_float_options("af", [None, Some(2.0)]),
    Series::from_float_options("bf", [Some(9.0), None]),
    Series::from_bool_options("tb", [None, Some(true)]),
    Series::from_bool_options("eb", [Some(false), None]),
    Series::from_string_options("ts", [None, Some("x")]),
    Series::from_string_options("es", [Some("y"), None]),
  ])
  let out = df.with_columns([
    @expr.when(@expr.col("c"))
    .then(@expr.col("af"))
    .otherwise(@expr.col("bf"))
    .with_alias("ff"),
    @expr.when(@expr.col("c"))
    .then(@expr.col("tb"))
    .otherwise(@expr.col("eb"))
    .with_alias("bb"),
    @expr.when(@expr.col("c"))
    .then(@expr.col("ts"))
    .otherwise(@expr.col("es"))
    .with_alias("ss"),
  ])
  let both_null = [@types.Scalar::Null, @types.Scalar::Null]
  assert_eq(out.get_column("ff").to_scalars(), both_null)
  assert_eq(out.get_column("bb").to_scalars(), both_null)
  assert_eq(out.get_column("ss").to_scalars(), both_null)
}

// ── Backend convention ───────────────────────────────────────────────

///|
test "backend: all-valid numeric computed results converge to Numeric" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2]),
    Series::from_ints("b", [3, 4]),
    Series::from_int_options("c", [Some(5), None]),
  ])
  let out = df.with_columns([
    (@expr.col("a") + @expr.col("b")).with_alias("clean"),
    (@expr.col("a") + @expr.col("c")).with_alias("nulled"),
    (@expr.col("a") / @expr.col("b")).with_alias("ratio"),
    @expr.col("a").eq(@expr.col("b")).with_alias("cmp"),
    @expr.col("c").sum().with_alias("agg"),
    @expr.col("a").cast(@types.DataType::Float).with_alias("casted"),
  ])
  // Computed all-valid numerics land on the fast path…
  assert_eq(
    out.get_column("clean").storage_kind(),
    @column.StorageKind::Numeric,
  )
  assert_eq(
    out.get_column("ratio").storage_kind(),
    @column.StorageKind::Numeric,
  )
  assert_eq(out.get_column("agg").storage_kind(), @column.StorageKind::Numeric)
  assert_eq(
    out.get_column("casted").storage_kind(),
    @column.StorageKind::Numeric,
  )
  // …while nullable and non-numeric results stay Builtin.
  assert_eq(
    out.get_column("nulled").storage_kind(),
    @column.StorageKind::Builtin,
  )
  assert_eq(out.get_column("cmp").storage_kind(), @column.StorageKind::Builtin)
}

// ── Integration: one realistic pipeline tree ─────────────────────────

///|
test "deep tree: derive, compare, combine, and alias in one call" {
  let df = DataFrame::new([
    Series::from_ints("revenue", [100, 200, 300]),
    Series::from_ints("cost", [50, 250, 100]),
    Series::from_strings("region", ["west", "east", "west"]),
  ])
  let out = df.with_columns([
    (@expr.col("revenue") - @expr.col("cost")).with_alias("profit"),
    ((@expr.col("revenue") - @expr.col("cost")).gt(@expr.lit_int(0)) &
    @expr.col("region").eq(@expr.lit_str("west"))).with_alias("flag"),
  ])
  assert_eq(out.columns(), ["revenue", "cost", "region", "profit", "flag"])
  assert_eq(out.get_column("profit").to_scalars(), [
    @types.Scalar::Int(50),
    @types.Scalar::Int(-50),
    @types.Scalar::Int(200),
  ])
  assert_eq(out.get_column("flag").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "deep expression trees evaluate without overflowing the stack" {
  // Evaluating a tree this deep formerly overflowed the native call stack and
  // aborted — select / filter / with_columns / agg all route through the
  // evaluator. The explicit work + value stack evaluates any depth.
  let df = DataFrame::new([Series::from_ints("x", [5])])
  let depth = 50000
  let mut e = @expr.col("x")
  for _ in 0..<depth {
    e = e + @expr.lit_int(1)
  }
  let out = df.with_columns([e.with_alias("r")])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Int((5 + depth).to_int64()),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "numeric fast arms: mixed all-valid pairings and the unary probes" {
  // `j` / `g` are all-valid (the `Numeric` backend), so these drive the
  // evaluator's raw-array fast arms; the mixed pairings promote to Float.
  let df = arith_df()
  // Int / Float division (always Float).
  let q = df.with_columns([(@expr.col("j") / @expr.col("g")).with_alias("q")])
  assert_eq(q.get_column("q").to_scalars(), [
    @types.Scalar::Float(0.1),
    @types.Scalar::Float(0.1),
    @types.Scalar::Float(0.1),
  ])
  // Int vs Float equality (Eq always consults the eq primitive — the
  // ordering verbs can short-circuit past it).
  let c = df.with_columns([@expr.col("j").eq(@expr.col("g")).with_alias("c")])
  assert_eq(c.get_column("c").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
  ])
  // Float negation stays on the fast path.
  let n = df.with_columns([(-@expr.col("g")).with_alias("n")])
  assert_eq(n.get_column("n").to_scalars(), [
    @types.Scalar::Float(-100.0),
    @types.Scalar::Float(-200.0),
    @types.Scalar::Float(-300.0),
  ])
  // The NaN probes over all-valid operands: an Int cell is never NaN, and
  // NaN in a Float column is a value the probe sees (not a null).
  let pi = df.with_columns([@expr.col("j").is_nan().with_alias("pi")])
  assert_eq(pi.get_column("pi").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
  ])
  let dfn = DataFrame::new([Series::from_floats("h", [1.0, 0.0 / 0.0, 3.0])])
  let ph = dfn.with_columns([@expr.col("h").is_nan().with_alias("ph")])
  assert_eq(ph.get_column("ph").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
  let pf = dfn.with_columns([@expr.col("h").is_not_nan().with_alias("pf")])
  assert_eq(pf.get_column("pf").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
}

///|
test "comparison general arm: Float-led pairings through nullable operands" {
  // `f` is nullable (the `Builtin` backend), so these pairings take the
  // general comparison arm — a null on either side nulls the cell.
  let df = arith_df()
  // (Float, Int) pairing: f vs the all-valid j; Ge falls through its lt
  // half to the eq primitive on every present pair here.
  let a = df.with_columns([@expr.col("f").ge(@expr.col("j")).with_alias("a")])
  assert_eq(a.get_column("a").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  // (Float, Float) pairing: f vs the all-valid g.
  let b = df.with_columns([@expr.col("f").ge(@expr.col("g")).with_alias("b")])
  assert_eq(b.get_column("b").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
}
