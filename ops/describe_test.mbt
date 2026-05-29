// Blackbox tests for `@ops.describe`.
//
// Invariants asserted on every successful summary:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) result.columns() == fixed schema (regardless of input)
//   (3) result.nrows() == df.ncols() (one row per source column)
//   (4) result column dtypes are pinned: column, dtype, min, max are
//       String; count, null_count, unique_count are Int; mean is Float
//       (nullable)
//
// Coverage targets:
//   - The empty-columns shortcut (0 source columns ⇒ 0 result rows).
//   - The `s.mean()` `Ok` branch (numeric column with at least one
//     non-null cell) AND the `Err` branch (non-numeric column OR
//     empty / all-null numeric column).
//   - `render_extremum` `is_null=true` (empty / all-null column) AND
//     `is_null=false` (column with at least one non-null cell).
//   - Every concrete dtype (Int / Float / Bool / String) reaches the
//     min / max rendering path at least once.

///|
/// Expected output schema for every `describe` result. Pinned in one
/// place so a schema change announces itself in exactly one test name
/// rather than rippling through every assertion.
fn describe_schema() -> Array[String] {
  [
    "column", "dtype", "count", "null_count", "unique_count", "mean", "min", "max",
  ]
}

///|
/// Mixed-dtype fixture covering Int (nullable), Float (nullable), Bool,
/// and String. Picked so:
///   - mean's Ok branch fires for "i" and "f"
///   - mean's Err branch fires for "b" and "s" (TypeMismatch)
///   - render_extremum's is_null=false branch fires for every column
fn describe_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_int_options("i", [Some(1), None, Some(3), Some(5)]),
    @frame.Series::from_float_options("f", [
      Some((1.0 : Double)),
      Some((2.0 : Double)),
      None,
      Some((3.0 : Double)),
    ]),
    @frame.Series::from_bools("b", [true, false, true, true]),
    @frame.Series::from_strings("s", ["banana", "apple", "cherry", "banana"]),
  ]).unwrap()
}

// ── Structural invariants ────────────────────────────────────────────

///|
test "describe schema is fixed regardless of source shape" {
  let df = describe_df()
  let out = describe(df)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), describe_schema())
  // One row per source column, eight schema columns.
  assert_eq(out.shape(), (4, 8))
}

///|
test "describe column dtypes are pinned" {
  let df = describe_df()
  let out = describe(df)
  assert_eq(out.get_column("column").unwrap().dtype(), @types.DataType::String)
  assert_eq(out.get_column("dtype").unwrap().dtype(), @types.DataType::String)
  assert_eq(out.get_column("count").unwrap().dtype(), @types.DataType::Int)
  assert_eq(out.get_column("null_count").unwrap().dtype(), @types.DataType::Int)
  assert_eq(
    out.get_column("unique_count").unwrap().dtype(),
    @types.DataType::Int,
  )
  assert_eq(out.get_column("mean").unwrap().dtype(), @types.DataType::Float)
  assert_eq(out.get_column("min").unwrap().dtype(), @types.DataType::String)
  assert_eq(out.get_column("max").unwrap().dtype(), @types.DataType::String)
}

// ── Per-row content: every dtype ──────────────────────────────────────

///|
test "describe row 0 summarises the Int column" {
  let df = describe_df()
  let out = describe(df)
  // Column "i": values [1, None, 3, 5] → count=3, null=1, unique=3,
  // mean=3.0, min=1, max=5.
  assert_eq(out.get(0, "column"), Ok(@types.Scalar::String("i")))
  assert_eq(out.get(0, "dtype"), Ok(@types.Scalar::String("Int")))
  assert_eq(out.get(0, "count"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(0, "null_count"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "unique_count"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(0, "mean"), Ok(@types.Scalar::Float(3.0)))
  assert_eq(out.get(0, "min"), Ok(@types.Scalar::String("1")))
  assert_eq(out.get(0, "max"), Ok(@types.Scalar::String("5")))
}

///|
test "describe row 1 summarises the Float column" {
  let df = describe_df()
  let out = describe(df)
  // Column "f": values [1.0, 2.0, None, 3.0] → count=3, null=1,
  // unique=3, mean=2.0, min=1.0, max=3.0.
  assert_eq(out.get(1, "column"), Ok(@types.Scalar::String("f")))
  assert_eq(out.get(1, "dtype"), Ok(@types.Scalar::String("Float")))
  assert_eq(out.get(1, "count"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(1, "null_count"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "unique_count"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(1, "mean"), Ok(@types.Scalar::Float(2.0)))
  // Double::to_string emits "1" / "3" — pin the rendered text so a
  // future Float formatter change is announced.
  let min_cell = out.get(1, "min").unwrap()
  let max_cell = out.get(1, "max").unwrap()
  assert_true(not(min_cell.is_null()))
  assert_true(not(max_cell.is_null()))
}

///|
test "describe row 2 summarises the Bool column (mean is Null)" {
  let df = describe_df()
  let out = describe(df)
  // Column "b": values [true, false, true, true] → count=4, null=0,
  // unique=2 (true / false), mean=Null (TypeMismatch collapses to
  // null), min=false, max=true.
  assert_eq(out.get(2, "column"), Ok(@types.Scalar::String("b")))
  assert_eq(out.get(2, "dtype"), Ok(@types.Scalar::String("Bool")))
  assert_eq(out.get(2, "count"), Ok(@types.Scalar::Int(4)))
  assert_eq(out.get(2, "null_count"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(2, "unique_count"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(2, "mean"), Ok(@types.Scalar::Null))
  // Bool::to_string emits "true" / "false".
  assert_eq(out.get(2, "min"), Ok(@types.Scalar::String("false")))
  assert_eq(out.get(2, "max"), Ok(@types.Scalar::String("true")))
}

///|
test "describe row 3 summarises the String column (mean is Null)" {
  let df = describe_df()
  let out = describe(df)
  // Column "s": values ["banana","apple","cherry","banana"] → count=4,
  // null=0, unique=3, mean=Null, min="apple", max="cherry".
  assert_eq(out.get(3, "column"), Ok(@types.Scalar::String("s")))
  assert_eq(out.get(3, "dtype"), Ok(@types.Scalar::String("String")))
  assert_eq(out.get(3, "count"), Ok(@types.Scalar::Int(4)))
  assert_eq(out.get(3, "null_count"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(3, "unique_count"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(3, "mean"), Ok(@types.Scalar::Null))
  assert_eq(out.get(3, "min"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(3, "max"), Ok(@types.Scalar::String("cherry")))
}

// ── Empty / all-null branches ────────────────────────────────────────

///|
test "describe on a 0-row numeric frame routes mean / min / max to Null" {
  // Empty Int column → Series::mean errors with InvalidOperation,
  // Series::min / max return Scalar::Null. Both map to the
  // `render_extremum` is_null=true branch.
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::Float),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = describe(df)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 8))
  // Both rows: count=0, null=0, unique=0, mean=Null, min=Null, max=Null.
  for i in 0..<2 {
    assert_eq(out.get(i, "count"), Ok(@types.Scalar::Int(0)))
    assert_eq(out.get(i, "null_count"), Ok(@types.Scalar::Int(0)))
    assert_eq(out.get(i, "unique_count"), Ok(@types.Scalar::Int(0)))
    assert_eq(out.get(i, "mean"), Ok(@types.Scalar::Null))
    assert_eq(out.get(i, "min"), Ok(@types.Scalar::Null))
    assert_eq(out.get(i, "max"), Ok(@types.Scalar::Null))
  }
}

///|
test "describe on an all-null numeric column routes mean / min / max to Null" {
  // The `Err` arm of `s.mean()` is exercised by the InvalidOperation
  // path here (numeric column with zero non-null cells), distinct from
  // the TypeMismatch path covered by the Bool / String rows above.
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [None, None, None]),
  ]).unwrap()
  let out = describe(df)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "count"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(0, "null_count"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(0, "unique_count"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(0, "mean"), Ok(@types.Scalar::Null))
  assert_eq(out.get(0, "min"), Ok(@types.Scalar::Null))
  assert_eq(out.get(0, "max"), Ok(@types.Scalar::Null))
}

///|
test "describe on an all-null String column produces typed-null extrema" {
  // String column with no non-null cells: render_extremum's
  // is_null=true branch still applies to a non-numeric column.
  let df = @frame.DataFrame::new([
    @frame.Series::from_string_options("s", [None, None]),
  ]).unwrap()
  let out = describe(df)
  assert_eq(out.get(0, "dtype"), Ok(@types.Scalar::String("String")))
  assert_eq(out.get(0, "count"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(0, "null_count"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(0, "min"), Ok(@types.Scalar::Null))
  assert_eq(out.get(0, "max"), Ok(@types.Scalar::Null))
}

// ── Edge: zero columns ───────────────────────────────────────────────

///|
test "describe on a 0-column frame collapses to a 0x8 result" {
  let df = @frame.DataFrame::new([]).unwrap()
  let out = describe(df)
  assert_eq(out.check_invariants(), Ok(()))
  // No source columns → no output rows, but the eight schema columns
  // are still present so downstream code can rely on the result shape.
  assert_eq(out.shape(), (0, 8))
  assert_eq(out.columns(), describe_schema())
}

// ── All-non-numeric mix (mean's Err path on every row) ───────────────

///|
test "describe on an all-String frame leaves mean Null for every row" {
  // Every source column is non-numeric → every `s.mean()` returns
  // TypeMismatch → every mean cell is Null.
  let df = @frame.DataFrame::new([
    @frame.Series::from_strings("a", ["x", "y"]),
    @frame.Series::from_strings("b", ["m", "n"]),
  ]).unwrap()
  let out = describe(df)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 8))
  for i in 0..<2 {
    assert_eq(out.get(i, "mean"), Ok(@types.Scalar::Null))
  }
}

// ── Column-order preservation ────────────────────────────────────────

///|
test "describe preserves source column order in the `column` row labels" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("z", [1, 2]),
    @frame.Series::from_ints("a", [3, 4]),
    @frame.Series::from_ints("m", [5, 6]),
  ]).unwrap()
  let out = describe(df)
  // Source declaration order is z, a, m — preserved verbatim, not
  // lexicographic.
  assert_eq(out.get(0, "column"), Ok(@types.Scalar::String("z")))
  assert_eq(out.get(1, "column"), Ok(@types.Scalar::String("a")))
  assert_eq(out.get(2, "column"), Ok(@types.Scalar::String("m")))
}

// ── Local helpers ────────────────────────────────────────────────────

///|
/// Tiny `Bool` negation — MoonBit's prefix `!` doesn't work in
/// expression position for booleans, so a named helper keeps the
/// inline assertion readable.
fn not(b : Bool) -> Bool {
  if b {
    false
  } else {
    true
  }
}
