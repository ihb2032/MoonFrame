// Blackbox tests for row access: `DataFrame::row` (single-row tuple) and
// `DataFrame::rows` (every row, row-major).

///|
/// Reusable mixed-dtype frame for the tests below. Row 1 is all-null so
/// every dtype has a null cell to surface as `Scalar::Null`.
fn sample_frame() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("i", [Some(7), None, Some(9)]),
    Series::from_float_options("f", [Some(1.5), None, Some(3.5)]),
    Series::from_bool_options("b", [Some(true), None, Some(false)]),
    Series::from_string_options("s", [Some("a"), None, Some("c")]),
  ])
}

// ── row ──────────────────────────────────────────────────────────────

///|
test "row returns the cells in column order across dtypes" {
  let df = sample_frame()
  assert_eq(df.row(0), [
    @types.Scalar::Int(7),
    @types.Scalar::Float(1.5),
    @types.Scalar::Bool(true),
    @types.Scalar::String("a"),
  ])
  assert_eq(df.row(2), [
    @types.Scalar::Int(9),
    @types.Scalar::Float(3.5),
    @types.Scalar::Bool(false),
    @types.Scalar::String("c"),
  ])
}

///|
test "row reads null cells as Scalar::Null" {
  // Row 1 is all-null — every cell reads as Null regardless of dtype.
  assert_eq(sample_frame().row(1), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
}

///|
test "row validates the index up front with IndexOutOfBounds" {
  let df = sample_frame()
  assert_eq(try? df.row(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(try? df.row(3), Err(@types.DataError::IndexOutOfBounds(3)))
}

// ── rows ─────────────────────────────────────────────────────────────

///|
test "rows materialises every row, row-major" {
  assert_eq(sample_frame().rows(), [
    [
      @types.Scalar::Int(7),
      @types.Scalar::Float(1.5),
      @types.Scalar::Bool(true),
      @types.Scalar::String("a"),
    ],
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Null,
    ],
    [
      @types.Scalar::Int(9),
      @types.Scalar::Float(3.5),
      @types.Scalar::Bool(false),
      @types.Scalar::String("c"),
    ],
  ])
}

///|
test "rows agrees with row at every index" {
  let df = sample_frame()
  let rows = df.rows()
  assert_eq(rows.length(), df.nrows())
  for r in 0..<df.nrows() {
    assert_eq(rows[r], df.row(r))
  }
}

///|
test "rows of a frame with no rows is empty" {
  // Columns declared, zero rows — no tuples to emit.
  let df = DataFrame::new([
    Series::from_ints("a", []),
    Series::from_strings("s", []),
  ])
  assert_eq(df.rows(), [])
}
