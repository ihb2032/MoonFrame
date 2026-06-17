// Blackbox tests for `DataFrame::unique` — full-row dedup keeping the first
// occurrence of each distinct row, in first-appearance order (Polars'
// `maintain_order=True`). Row identity reuses the composite `KeyCell` encoding
// `group_by` / `join` key on (see `frame/row_key.mbt`), so null is an ordinary
// value, `NaN` equals `NaN`, and `-0.0` folds into `+0.0`.
//
// Invariants asserted on a successful dedup: check_invariants() == Ok(()),
// the schema and column order are unchanged (dedup is row-only), and the
// surviving rows are the first occurrences in input order.

///|
/// Six rows over two columns with three distinct rows — `(1,x)`, `(2,y)`,
/// `(3,z)` — each repeated out of order so first-appearance ordering is
/// observable.
fn dup_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 1, 3, 2, 1]),
    Series::from_strings("b", ["x", "y", "x", "z", "y", "x"]),
  ])
}

///|
test "unique keeps the first occurrence of each distinct row, in first-appearance order" {
  let df = dup_df()
  let out = df.unique()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  // Distinct rows in first appearance: (1,x)@0, (2,y)@1, (3,z)@3.
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "b"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(1, "b"), @types.Scalar::String("y"))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(2, "b"), @types.Scalar::String("z"))
}

///|
test "unique on an all-distinct frame returns it unchanged" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  let out = df.unique()
  // No duplicates, so the gather is a no-op and the frame is returned as-is.
  assert_eq(out, df)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "unique collapses an all-identical frame to a single row" {
  let df = DataFrame::new([
    Series::from_ints("a", [7, 7, 7]),
    Series::from_strings("b", ["q", "q", "q"]),
  ])
  let out = df.unique()
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(7))
  assert_eq(out.item(0, "b"), @types.Scalar::String("q"))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "unique treats null as an ordinary value: rows null in the same places are duplicates" {
  // Rows: (null,1), (2,null), (null,1), (2,null), (null,2).
  let df = DataFrame::new([
    Series::from_int_options("a", [None, Some(2), None, Some(2), None]),
    Series::from_int_options("b", [Some(1), None, Some(1), None, Some(2)]),
  ])
  let out = df.unique()
  // Distinct in first appearance: (null,1)@0, (2,null)@1, (null,2)@4.
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Null)
  assert_eq(out.item(0, "b"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
  assert_eq(out.item(2, "a"), @types.Scalar::Null)
  assert_eq(out.item(2, "b"), @types.Scalar::Int(2))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "unique on a 0-row frame is unchanged" {
  let df = DataFrame::new([
    Series::from_ints("a", []),
    Series::from_strings("b", []),
  ])
  let out = df.unique()
  assert_eq(out, df)
  assert_eq(out.nrows(), 0)
  assert_eq(out.columns(), ["a", "b"])
}

///|
test "unique folds NaN and signed zero like a group key" {
  let nan = @double.not_a_number
  // Rows: NaN, NaN, 0.0, -0.0 — two NaN collapse to one, and +0.0 / -0.0
  // share a bucket, so two distinct rows survive (NaN@0, 0.0@2).
  let df = DataFrame::new([Series::from_floats("f", [nan, nan, 0.0, -0.0])])
  let out = df.unique()
  assert_eq(out.shape(), (2, 1))
  assert_true(out.item(0, "f").as_float().is_nan())
  assert_eq(out.item(1, "f"), @types.Scalar::Float(0.0))
  assert_eq(out.check_invariants(), Ok(()))
}
