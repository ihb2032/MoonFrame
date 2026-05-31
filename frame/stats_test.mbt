// Blackbox tests for `DataFrame::count` / `sum` / `mean` / `min` / `max`.
//
// These methods delegate to the corresponding `Series` reductions
// (covered exhaustively in `series_stats_test.mbt`), so the tests here
// focus on the layer-specific behaviour:
//   (1) column lookup — both the success path and `ColumnNotFound`
//   (2) Series-level error propagation (TypeMismatch for non-numeric
//       sum/mean, InvalidOperation for empty / all-null numeric mean)
//   (3) min / max returning `Scalar::Null` on empty / all-null columns

///|
/// Mixed-dtype fixture: an `Int` column with a null cell, a `Float`
/// column with a null cell, a fully-valid `Bool` column, and a `String`
/// column. Exercises every dtype branch every reduction may encounter.
fn stats_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("i", [Some(1), None, Some(2), Some(3)]),
    Series::from_float_options("f", [
      Some((1.0 : Double)),
      Some((2.0 : Double)),
      None,
      Some((4.0 : Double)),
    ]),
    Series::from_bools("b", [true, false, true, true]),
    Series::from_strings("s", ["banana", "apple", "cherry", "banana"]),
  ])
}

// ── count ────────────────────────────────────────────────────────────

///|
test "count returns the non-null cell count for an existing column" {
  let df = stats_df()
  // Int column "i" has one null in four cells → count = 3.
  assert_eq(df.count("i"), 3)
  // Bool column "b" has no nulls → count = 4.
  assert_eq(df.count("b"), 4)
}

///|
test "count returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    try? df.count("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "count on a 0-row column is zero" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)])
  let df = DataFrame::empty(schema)
  assert_eq(df.count("a"), 0)
}

// ── sum ──────────────────────────────────────────────────────────────

///|
test "sum on an Int column ignores nulls" {
  let df = stats_df()
  // 1 + 2 + 3 = 6 (the None cell is skipped).
  assert_eq(df.sum("i"), @types.Scalar::Int(6))
}

///|
test "sum on a Float column ignores nulls" {
  let df = stats_df()
  // 1.0 + 2.0 + 4.0 = 7.0.
  assert_eq(df.sum("f"), @types.Scalar::Float(7.0))
}

///|
test "sum returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    try? df.sum("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "sum on a Bool column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true((try? df.sum("b")) is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "sum on a String column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true((try? df.sum("s")) is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "sum on an empty Int column is the additive identity" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)])
  let df = DataFrame::empty(schema)
  assert_eq(df.sum("a"), @types.Scalar::Int(0))
}

// ── mean ─────────────────────────────────────────────────────────────

///|
test "mean on an Int column promotes to Float" {
  let df = stats_df()
  // (1 + 2 + 3) / 3 = 2.0.
  assert_eq(df.mean("i"), (2.0 : Double))
}

///|
test "mean on a Float column ignores nulls" {
  let df = stats_df()
  // (1.0 + 2.0 + 4.0) / 3 ≈ 2.333...
  let r = df.mean("f")
  // Avoid pinning the trailing digits of the Float division.
  assert_true(r > 2.3 && r < 2.4)
}

///|
test "mean returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    try? df.mean("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "mean on a Bool column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true((try? df.mean("b")) is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "mean on a String column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true((try? df.mean("s")) is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "mean on an empty numeric column is InvalidOperation" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::Float),
  ])
  let df = DataFrame::empty(schema)
  assert_true((try? df.mean("a")) is Err(@types.DataError::InvalidOperation(_)))
  assert_true((try? df.mean("b")) is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "mean on an all-null numeric column is InvalidOperation" {
  let df = DataFrame::new([
    Series::from_int_options("a", [None, None, None]),
    Series::from_float_options("b", [None, None, None]),
  ])
  assert_true((try? df.mean("a")) is Err(@types.DataError::InvalidOperation(_)))
  assert_true((try? df.mean("b")) is Err(@types.DataError::InvalidOperation(_)))
}

// ── min ──────────────────────────────────────────────────────────────

///|
test "min on an Int column returns the smallest non-null cell" {
  let df = stats_df()
  assert_eq(df.min("i"), @types.Scalar::Int(1))
}

///|
test "min on a Float column returns the smallest non-null cell" {
  let df = stats_df()
  assert_eq(df.min("f"), @types.Scalar::Float(1.0))
}

///|
test "min on a Bool column follows false < true" {
  let df = stats_df()
  assert_eq(df.min("b"), @types.Scalar::Bool(false))
}

///|
test "min on a String column uses lexicographic order" {
  let df = stats_df()
  assert_eq(df.min("s"), @types.Scalar::String("apple"))
}

///|
test "min returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    try? df.min("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "min on an all-null column returns Scalar::Null" {
  let df = DataFrame::new([Series::from_int_options("a", [None, None])])
  assert_eq(df.min("a"), @types.Scalar::Null)
}

///|
test "min on an empty column returns Scalar::Null" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  assert_eq(df.min("a"), @types.Scalar::Null)
}

// ── max ──────────────────────────────────────────────────────────────

///|
test "max on an Int column returns the largest non-null cell" {
  let df = stats_df()
  assert_eq(df.max("i"), @types.Scalar::Int(3))
}

///|
test "max on a Float column returns the largest non-null cell" {
  let df = stats_df()
  assert_eq(df.max("f"), @types.Scalar::Float(4.0))
}

///|
test "max on a Bool column follows false < true" {
  let df = stats_df()
  assert_eq(df.max("b"), @types.Scalar::Bool(true))
}

///|
test "max on a String column uses lexicographic order" {
  let df = stats_df()
  assert_eq(df.max("s"), @types.Scalar::String("cherry"))
}

///|
test "max returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    try? df.max("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "max on an all-null column returns Scalar::Null" {
  let df = DataFrame::new([Series::from_float_options("a", [None, None, None])])
  assert_eq(df.max("a"), @types.Scalar::Null)
}

///|
test "max on an empty column returns Scalar::Null" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Bool),
  ])
  let df = DataFrame::empty(schema)
  assert_eq(df.max("a"), @types.Scalar::Null)
}
