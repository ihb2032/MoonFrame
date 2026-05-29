// Blackbox tests for `@ops.null_count`.
//
// Invariants asserted on every successful summary:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) result.columns() == df.columns() — names + order preserved
//   (3) every column in the result is dtype Int (the count itself)
//   (4) result.shape() == (1, df.ncols()) — except for the 0-column
//       edge case, which collapses to (0, 0)
//   (5) the cell in result column `c` equals df.get_column(c).null_count()

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "null_count summarises each column into a single-cell Int" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None, Some(3), None]),
    @frame.Series::from_float_options("b", [
      Some((1.5 : Double)),
      Some((2.5 : Double)),
      None,
      Some((4.5 : Double)),
    ]),
    @frame.Series::from_strings("s", ["w", "x", "y", "z"]),
  ]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Shape: exactly one row, one column per input column.
  assert_eq(out.shape(), (1, 3))
  // Column names + order match the input verbatim.
  assert_eq(out.columns(), df.columns())
  // Each column in the summary is dtype Int (the count is always an Int).
  for name in out.columns() {
    assert_eq(out.get_column(name).unwrap().dtype(), @types.DataType::Int)
  }
  // Per-cell values: 2 nulls in "a", 1 null in "b", 0 nulls in "s".
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::Int(0)))
}

///|
test "null_count on a fully-valid frame returns all-zero counts" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::Int(0)))
}

///|
test "null_count on an all-null column reports the full row count" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [None, None, None, None, None]),
    @frame.Series::from_string_options("s", [
      Some("x"),
      None,
      Some("y"),
      None,
      Some("z"),
    ]),
  ]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(5)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::Int(2)))
}

///|
test "null_count on a 0-row frame reports zero for every column" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::Float),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Shape is (1, 2): the summary always has one row per source column,
  // independent of the source row count.
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Int(0)))
}

///|
test "null_count on a 0-column frame collapses to a 0x0 summary" {
  // DataFrame::new's documented behaviour for an empty column list is
  // nrows == 0. We can't return a 1×0 summary because there's no
  // anchor column to set nrows on; the natural fallback is (0, 0).
  let df = @frame.DataFrame::new([]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
  assert_eq(out.columns(), df.columns())
}

///|
test "null_count preserves column order even when names sort differently" {
  // The output column order is the input order, not lexicographic.
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("z", [Some(1), None]),
    @frame.Series::from_int_options("a", [None, None]),
    @frame.Series::from_int_options("m", [Some(1), Some(2)]),
  ]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["z", "a", "m"])
  assert_eq(out.get(0, "z"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(0, "m"), Ok(@types.Scalar::Int(0)))
}

///|
test "null_count covers every dtype branch" {
  // Int / Float / Bool / String — make sure each dtype contributes a
  // correct null count (the implementation goes through Series, which
  // delegates to BuiltinColumn::null_count which is dtype-agnostic, but
  // a regression here would silently miss one branch).
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("i", [Some(1), None]),
    @frame.Series::from_float_options("f", [None, Some((2.0 : Double))]),
    @frame.Series::from_bool_options("b", [None, Some(true)]),
    @frame.Series::from_string_options("s", [Some("x"), None]),
  ]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "i"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "f"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::Int(1)))
}

// ── Per-cell consistency with Series::null_count ─────────────────────

///|
test "null_count cell value equals the source series' null_count" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None, Some(3)]),
    @frame.Series::from_float_options("b", [None, None, Some((1.0 : Double))]),
  ]).unwrap()
  let out = null_count(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  for name in df.columns() {
    let expected = df.get_column(name).unwrap().null_count()
    assert_eq(out.get(0, name), Ok(@types.Scalar::Int(expected.to_int64())))
  }
}
