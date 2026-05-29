// Blackbox tests for `@ops.count` / `sum` / `mean` / `min` / `max`.
//
// The ops layer delegates to the corresponding `Series` reductions
// (covered exhaustively in `frame/series_stats_test.mbt`), so the tests
// here focus on the layer-specific behaviour:
//   (1) column lookup — both the success path and `ColumnNotFound`
//   (2) Series-level error propagation (TypeMismatch for non-numeric
//       sum/mean, InvalidOperation for empty / all-null numeric mean)
//   (3) min / max returning `Scalar::Null` on empty / all-null columns
// Each branch in the shared `dispatch_stat` helper is exercised at
// least once via the public functions.

///|
/// Mixed-dtype fixture: an `Int` column with a null cell, a `Float`
/// column with a null cell, a fully-valid `Bool` column, and a `String`
/// column. Exercises every dtype branch every reduction may encounter.
fn stats_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_int_options("i", [Some(1), None, Some(2), Some(3)]),
    @frame.Series::from_float_options("f", [
      Some((1.0 : Double)),
      Some((2.0 : Double)),
      None,
      Some((4.0 : Double)),
    ]),
    @frame.Series::from_bools("b", [true, false, true, true]),
    @frame.Series::from_strings("s", ["banana", "apple", "cherry", "banana"]),
  ]).unwrap()
}

// ── count ────────────────────────────────────────────────────────────

///|
test "count returns the non-null cell count for an existing column" {
  let df = stats_df()
  // Int column "i" has one null in four cells → count = 3.
  assert_eq(count(df, "i"), Ok(3))
  // Bool column "b" has no nulls → count = 4.
  assert_eq(count(df, "b"), Ok(4))
}

///|
test "count returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    count(df, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "count on a 0-row column is zero" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  assert_eq(count(df, "a"), Ok(0))
}

// ── sum ──────────────────────────────────────────────────────────────

///|
test "sum on an Int column ignores nulls" {
  let df = stats_df()
  // 1 + 2 + 3 = 6 (the None cell is skipped).
  assert_eq(sum(df, "i"), Ok(@types.Scalar::Int(6)))
}

///|
test "sum on a Float column ignores nulls" {
  let df = stats_df()
  // 1.0 + 2.0 + 4.0 = 7.0.
  assert_eq(sum(df, "f"), Ok(@types.Scalar::Float(7.0)))
}

///|
test "sum returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    sum(df, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "sum on a Bool column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true(sum(df, "b") is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "sum on a String column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true(sum(df, "s") is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "sum on an empty Int column is the additive identity" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  assert_eq(sum(df, "a"), Ok(@types.Scalar::Int(0)))
}

// ── mean ─────────────────────────────────────────────────────────────

///|
test "mean on an Int column promotes to Float" {
  let df = stats_df()
  // (1 + 2 + 3) / 3 = 2.0.
  assert_eq(mean(df, "i"), Ok((2.0 : Double)))
}

///|
test "mean on a Float column ignores nulls" {
  let df = stats_df()
  // (1.0 + 2.0 + 4.0) / 3 ≈ 2.333...
  let r = mean(df, "f").unwrap()
  // Avoid pinning the trailing digits of the Float division.
  assert_true(r > 2.3 && r < 2.4)
}

///|
test "mean returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    mean(df, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "mean on a Bool column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true(mean(df, "b") is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "mean on a String column surfaces TypeMismatch" {
  let df = stats_df()
  assert_true(mean(df, "s") is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "mean on an empty numeric column is InvalidOperation" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::Float),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  assert_true(mean(df, "a") is Err(@types.DataError::InvalidOperation(_)))
  assert_true(mean(df, "b") is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "mean on an all-null numeric column is InvalidOperation" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [None, None, None]),
    @frame.Series::from_float_options("b", [None, None, None]),
  ]).unwrap()
  assert_true(mean(df, "a") is Err(@types.DataError::InvalidOperation(_)))
  assert_true(mean(df, "b") is Err(@types.DataError::InvalidOperation(_)))
}

// ── min ──────────────────────────────────────────────────────────────

///|
test "min on an Int column returns the smallest non-null cell" {
  let df = stats_df()
  assert_eq(min(df, "i"), Ok(@types.Scalar::Int(1)))
}

///|
test "min on a Float column returns the smallest non-null cell" {
  let df = stats_df()
  assert_eq(min(df, "f"), Ok(@types.Scalar::Float(1.0)))
}

///|
test "min on a Bool column follows false < true" {
  let df = stats_df()
  assert_eq(min(df, "b"), Ok(@types.Scalar::Bool(false)))
}

///|
test "min on a String column uses lexicographic order" {
  let df = stats_df()
  assert_eq(min(df, "s"), Ok(@types.Scalar::String("apple")))
}

///|
test "min returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    min(df, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "min on an all-null column returns Scalar::Null" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [None, None]),
  ]).unwrap()
  assert_eq(min(df, "a"), Ok(@types.Scalar::Null))
}

///|
test "min on an empty column returns Scalar::Null" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::String),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  assert_eq(min(df, "a"), Ok(@types.Scalar::Null))
}

// ── max ──────────────────────────────────────────────────────────────

///|
test "max on an Int column returns the largest non-null cell" {
  let df = stats_df()
  assert_eq(max(df, "i"), Ok(@types.Scalar::Int(3)))
}

///|
test "max on a Float column returns the largest non-null cell" {
  let df = stats_df()
  assert_eq(max(df, "f"), Ok(@types.Scalar::Float(4.0)))
}

///|
test "max on a Bool column follows false < true" {
  let df = stats_df()
  assert_eq(max(df, "b"), Ok(@types.Scalar::Bool(true)))
}

///|
test "max on a String column uses lexicographic order" {
  let df = stats_df()
  assert_eq(max(df, "s"), Ok(@types.Scalar::String("cherry")))
}

///|
test "max returns ColumnNotFound for a missing column" {
  let df = stats_df()
  assert_eq(
    max(df, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "max on an all-null column returns Scalar::Null" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_float_options("a", [None, None, None]),
  ]).unwrap()
  assert_eq(max(df, "a"), Ok(@types.Scalar::Null))
}

///|
test "max on an empty column returns Scalar::Null" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Bool),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  assert_eq(max(df, "a"), Ok(@types.Scalar::Null))
}
