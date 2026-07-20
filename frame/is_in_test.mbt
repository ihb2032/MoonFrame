// Blackbox tests for `Expr::is_in` — membership as an OR of `eq`.

///|
test "is_in: membership over a numeric column, present cells true/false" {
  let df = DataFrame::new([Series::from_ints("a", [1L, 2L, 3L, 4L])])
  let out = df.select([
    @expr.col("a")
    .is_in([@types.Scalar::Int(2), @types.Scalar::Int(4)])
    .with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
}

///|
test "is_in: Int/Float members compare exactly across the 2^53 boundary" {
  let df = DataFrame::new([
    Series::from_ints("a", [9007199254740993L, 9007199254740992L]),
  ])
  // The Double 9007199254740992.0 equals the Int 9007199254740992 exactly, but
  // NOT 9007199254740993 (which the Double cannot represent) — no promotion
  // collision.
  let out = df.select([
    @expr.col("a")
    .is_in([@types.Scalar::Float(9007199254740992.0)])
    .with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
}

///|
test "is_in: a null cell yields null; a null member matches nothing" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1L), Some(2L), None]),
  ])
  // The null member is skipped (it has no value to equal), so only `1` matches.
  let out = df.select([
    @expr.col("a")
    .is_in([@types.Scalar::Int(1), @types.Scalar::Null])
    .with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
}

///|
test "is_in: an empty set is false for present cells, null for null cells" {
  let df = DataFrame::new([Series::from_int_options("a", [Some(1L), None])])
  let out = df.select([@expr.col("a").is_in([]).with_alias("r")])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
}

///|
test "is_in: String and Bool columns" {
  let df = DataFrame::new([
    Series::from_strings("s", ["north", "south", "east"]),
    Series::from_bools("b", [true, false, true]),
  ])
  let out = df.select([
    @expr.col("s")
    .is_in([@types.Scalar::String("north"), @types.Scalar::String("east")])
    .with_alias("rs"),
    @expr.col("b").is_in([@types.Scalar::Bool(true)]).with_alias("rb"),
  ])
  assert_eq(out.get_column("rs").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
  assert_eq(out.get_column("rb").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
}

///|
test "is_in: a NaN member never matches (IEEE), as under eq" {
  let nan = 0.0 / 0.0
  let df = DataFrame::new([Series::from_floats("a", [1.0, nan])])
  let out = df.select([
    @expr.col("a")
    .is_in([@types.Scalar::Float(nan), @types.Scalar::Float(1.0)])
    .with_alias("r"),
  ])
  // 1.0 matches the 1.0 member; the NaN cell matches nothing (NaN != NaN).
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
}

///|
test "is_in: a member whose dtype cannot compare with the column raises" {
  let df = DataFrame::new([Series::from_ints("a", [1L, 2L])])
  assert_eq(
    Ok(df.select([@expr.col("a").is_in([@types.Scalar::String("x")])])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "compare",
          @types.DataType::Int,
          @types.DataType::String,
        ),
      ),
    ),
  )
}

///|
test "is_in: is_in([v]) is exactly eq(lit(v)), nulls included" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1L), Some(2L), None]),
  ])
  let via_is_in = df
    .select([@expr.col("a").is_in([@types.Scalar::Int(2)]).with_alias("r")])
    .get_column("r")
    .to_scalars()
  let via_eq = df
    .select([@expr.col("a").eq(@expr.lit_int(2)).with_alias("r")])
    .get_column("r")
    .to_scalars()
  assert_eq(via_is_in, via_eq)
}

///|
test "is_in: mixed Int and Float members take the exact path" {
  // An Int column with a mixed-dtype member list falls off the Int fast path
  // onto the exact `eq` kernel, so the Int member and the (integral) Float
  // member both match by exact value.
  let df = DataFrame::new([Series::from_ints("a", [3L, 4L, 5L])])
  // A null member is still skipped on this exact path (the general-kernel case).
  let out = df.select([
    @expr.col("a")
    .is_in([
      @types.Scalar::Int(3),
      @types.Scalar::Float(4.0),
      @types.Scalar::Null,
    ])
    .with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
}

///|
test "is_in: a Float column matches -0.0 against a 0.0 member (IEEE)" {
  // Float membership stays on the exact path, where -0.0 == 0.0 (IEEE), so a
  // negative-zero cell matches a positive-zero member.
  let df = DataFrame::new([Series::from_floats("a", [-0.0, 1.0])])
  let out = df.select([
    @expr.col("a").is_in([@types.Scalar::Float(0.0)]).with_alias("r"),
  ])
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
}

///|
test "is_in: String and Bool columns skip a null member and reject a foreign dtype" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("north"), Some("south"), None]),
    Series::from_bool_options("b", [Some(true), Some(false), None]),
  ])
  // A null member is skipped on the String / Bool fast paths, exactly as on the
  // numeric one, and a null cell yields null.
  let out = df.select([
    @expr.col("s")
    .is_in([@types.Scalar::Null, @types.Scalar::String("north")])
    .with_alias("rs"),
    @expr.col("b")
    .is_in([
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
      @types.Scalar::Null,
    ])
    .with_alias("rb"),
  ])
  assert_eq(out.get_column("rs").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  // `b in {true, false}` is true for both present cells; the null cell is null.
  assert_eq(out.get_column("rb").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  // A foreign-dtype member falls off the fast path onto the exact kernel, which
  // raises the same structured mismatch `eq` would.
  assert_eq(
    Ok(df.select([@expr.col("s").is_in([@types.Scalar::Int(1)])])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "compare",
          @types.DataType::String,
          @types.DataType::Int,
        ),
      ),
    ),
  )
  assert_eq(
    Ok(df.select([@expr.col("b").is_in([@types.Scalar::String("x")])])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "compare",
          @types.DataType::Bool,
          @types.DataType::String,
        ),
      ),
    ),
  )
}

///|
test "is_in: reduces per group over an aggregation, rejects a bare column" {
  let df = DataFrame::new([
    Series::from_strings("k", ["x", "x", "y"]),
    Series::from_ints("v", [10L, 20L, 5L]),
  ])
  // `sum().is_in([...])` is a per-group scalar Bool: is the group's sum one of
  // these totals?
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v")
      .sum()
      .is_in([@types.Scalar::Int(30), @types.Scalar::Int(99)])
      .with_alias("hit"),
    ])
  assert_eq(out.get_column("hit").to_scalars(), [
    @types.Scalar::Bool(true), // x: 10+20 = 30
    @types.Scalar::Bool(false), // y: 5
  ])
  // A bare `col(...).is_in(...)` is row-wise, not a reduction.
  assert_true(
    (Ok(df.group_by([@expr.col("k")]).agg([@expr.col("v").is_in([])])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
