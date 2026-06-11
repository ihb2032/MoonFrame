///|
/// Blackbox behavior tests for `DataFrame::select_exprs`: projection
/// equivalence with `select(names)`, the output-height rule (all-scalar
/// → one row, mixed → broadcast to the frame), naming and column order,
/// within-call duplicate detection, the empty selection, zero-row frames,
/// and the evaluation-time error paths. The evaluator's dtype / null /
/// broadcast semantics live in `expr_eval_test.mbt`.

///|
fn sel_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_ints("b", [10, 20, 30]),
    Series::from_strings("region", ["west", "east", "west"]),
  ])
}

///|
test "pure column projection equals select by name, backends preserved" {
  let df = DataFrame::new([
    Series::from_ints("n", [1, 2, 3]),
    Series::from_int_options("m", [Some(1), None, Some(3)]),
  ])
  let out = df.select_exprs([@expr.col("m"), @expr.col("n")])
  assert_eq(out, df.select(["m", "n"]))
  // `col(...)` references keep their source backend through the gather.
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
  assert_eq(out.get_column("m").storage_kind(), @column.StorageKind::Builtin)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "derived columns build a brand-new frame in expression order" {
  let out = sel_df().select_exprs([
    (@expr.col("a") + @expr.col("b")).with_alias("total"),
    @expr.col("a").gt(@expr.lit_int(1)).with_alias("big"),
  ])
  assert_eq(out.columns(), ["total", "big"])
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Int(22),
    @types.Scalar::Int(33),
  ])
  assert_eq(out.get_column("big").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "output naming: alias, leftmost column reference, literal fallback" {
  let out = sel_df().select_exprs([
    @expr.col("b") + @expr.lit_int(1), // leftmost Col → "b"
    (@expr.col("a") * @expr.col("b")).with_alias("prod"),
    @expr.lit_str("x"), // column-less tree → "literal"
  ])
  assert_eq(out.columns(), ["b", "prod", "literal"])
}

///|
test "selecting a derived expression equals deriving then selecting" {
  // Equivalence with the with_columns path: the projection of a derived
  // column is the same column with_columns would have appended.
  let expr = (@expr.col("a") + @expr.col("b")).with_alias("t")
  assert_eq(
    sel_df().select_exprs([expr]),
    sel_df().with_columns([expr]).select(["t"]),
  )
}

///|
test "all-scalar expressions collapse to a one-row summary frame" {
  let out = sel_df().select_exprs([
    @expr.col("a").sum().with_alias("total"),
    @expr.col("a").mean().with_alias("avg"),
    @expr.col("a").count().with_alias("n"),
    @expr.lit_str("summary").with_alias("tag"),
  ])
  assert_eq(out.shape(), (1, 4))
  assert_eq(out.get_column("total").get(0), @types.Scalar::Int(6))
  assert_eq(out.get_column("avg").get(0), @types.Scalar::Float(2.0))
  assert_eq(out.get_column("n").get(0), @types.Scalar::Int(3))
  assert_eq(out.get_column("tag").get(0), @types.Scalar::String("summary"))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "mixed selection broadcasts scalar results to the frame height" {
  let out = sel_df().select_exprs([
    @expr.col("a"),
    @expr.col("a").sum().with_alias("total"),
    @expr.lit_int(7).with_alias("seven"),
  ])
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  assert_eq(
    out.get_column("total").to_scalars(),
    Array::make(3, @types.Scalar::Int(6)),
  )
  assert_eq(
    out.get_column("seven").to_scalars(),
    Array::make(3, @types.Scalar::Int(7)),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "select_exprs([]) collapses to the 0x0 frame, like select([])" {
  let out = sel_df().select_exprs([])
  assert_eq(out.shape(), (0, 0))
  assert_eq(out, sel_df().select([]))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "single-row frame: frame-tall and scalar results coincide at one row" {
  let df = DataFrame::new([Series::from_ints("a", [5])])
  let out = df.select_exprs([
    @expr.col("a"),
    @expr.col("a").sum().with_alias("t"),
  ])
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.get_column("a").get(0), @types.Scalar::Int(5))
  assert_eq(out.get_column("t").get(0), @types.Scalar::Int(5))
}

///|
test "zero-row frame: a frame-tall result pins the height at zero" {
  let df = DataFrame::new([Series::from_ints("a", [])])
  let out = df.select_exprs([
    @expr.col("a"),
    @expr.col("a").sum().with_alias("t"),
  ])
  assert_eq(out.shape(), (0, 2))
  assert_eq(out.get_column("t").dtype(), @types.DataType::Int)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "zero-row frame: an all-scalar selection still yields its one-row summary" {
  let df = DataFrame::new([Series::from_ints("a", [])])
  let out = df.select_exprs([
    @expr.col("a").sum().with_alias("t"),
    @expr.col("a").count().with_alias("n"),
    @expr.col("a").mean().with_alias("avg"),
  ])
  assert_eq(out.shape(), (1, 3))
  assert_eq(out.get_column("t").get(0), @types.Scalar::Int(0))
  assert_eq(out.get_column("n").get(0), @types.Scalar::Int(0))
  assert_eq(out.get_column("avg").get(0), @types.Scalar::Null)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "duplicate output names raise DuplicateColumn at the second expression" {
  // Two column-less trees both name themselves "literal".
  assert_eq(
    try? sel_df().select_exprs([@expr.lit_int(1), @expr.lit_int(2)]),
    Err(@types.DataError::DuplicateColumn("literal")),
  )
  // The same column referenced twice without an alias collides on its name.
  assert_eq(
    try? sel_df().select_exprs([
      @expr.col("a"),
      @expr.col("a") + @expr.lit_int(1),
    ]),
    Err(@types.DataError::DuplicateColumn("a")),
  )
  // Detection runs in expression order: the collision at the second
  // expression fires before the third (itself unevaluable) is touched.
  assert_eq(
    try? sel_df().select_exprs([
      @expr.lit_int(1),
      @expr.lit_int(2),
      @expr.col("zzz"),
    ]),
    Err(@types.DataError::DuplicateColumn("literal")),
  )
}

///|
test "evaluation errors surface: unknown column, dtype mismatch" {
  assert_eq(
    try? sel_df().select_exprs([@expr.col("zzz")]),
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
  assert_eq(
    try? sel_df().select_exprs([@expr.col("region") + @expr.col("a")]),
    Err(@types.DataError::TypeMismatch("cannot add String and Int")),
  )
}
