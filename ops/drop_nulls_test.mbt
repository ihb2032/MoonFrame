// Blackbox tests for `@ops.drop_nulls` and `@ops.drop_nulls_in`.
//
// Invariants asserted on every successful drop:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) result.schema() == df.schema() — drop is row-only, never
//       touches columns
//   (3) result.columns() == df.columns() — column order + names stable
//   (4) result.nrows() equals the number of rows that survived the
//       null gate

///|
/// Four-row, three-column fixture mixing nullable Int, nullable Float
/// and a fully-valid String. The two null-bearing columns intentionally
/// drop nulls on **different** rows so the union semantics of
/// `drop_nulls` (drop on any null) and the per-column semantics of
/// `drop_nulls_in` (drop only when *listed* columns are null) are both
/// observable.
fn drop_nulls_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None, Some(3), Some(4)]),
    @frame.Series::from_float_options("b", [
      Some((1.5 : Double)),
      Some((2.5 : Double)),
      None,
      Some((4.5 : Double)),
    ]),
    @frame.Series::from_strings("s", ["w", "x", "y", "z"]),
  ]).unwrap()
}

// ── drop_nulls — happy paths ─────────────────────────────────────────

///|
test "drop_nulls keeps only rows that are valid in every column" {
  let df = drop_nulls_df()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  // Row 0 (a=1, b=1.5, s="w") and row 3 (a=4, b=4.5, s="z") survive;
  // rows 1 and 2 each carry one null and are dropped.
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("w")))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(4)))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Float(4.5)))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("z")))
}

///|
test "drop_nulls is a no-op on a fully-valid frame" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ]).unwrap()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Same shape, same contents — but a freshly built frame, so
  // structural equality is the right witness.
  assert_eq(out, df)
}

///|
test "drop_nulls collapses to a 0-row frame when every row has at least one null" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(1), None]),
    @frame.Series::from_float_options("b", [None, Some((2.0 : Double))]),
  ]).unwrap()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Row 0: b null. Row 1: a null. Both drop, schema survives.
  assert_eq(out.schema(), df.schema())
  assert_eq(out.shape(), (0, 2))
}

///|
test "drop_nulls on a 0-row frame preserves the schema" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::String),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "drop_nulls on a 0x0 frame returns the same 0x0 frame" {
  let df = @frame.DataFrame::new([]).unwrap()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "drop_nulls on an all-null column drops every row" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [None, None, None]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ]).unwrap()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 2))
}

// ── drop_nulls_in — happy paths ──────────────────────────────────────

///|
test "drop_nulls_in only consults the listed columns" {
  let df = drop_nulls_df()
  // Gate on "a" only: drops row 1 (a=Null). Row 2's b=Null does NOT
  // disqualify the row anymore.
  let out = drop_nulls_in(df, ["a"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(4)))
  // The b=Null cell on the surviving row 2 must still read as Null
  // — drop_nulls_in does not fill or alter cells.
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Null))
}

///|
test "drop_nulls_in with every column equals drop_nulls" {
  let df = drop_nulls_df()
  let by_all = drop_nulls(df).unwrap()
  let by_in = drop_nulls_in(df, ["a", "b", "s"]).unwrap()
  assert_eq(by_in.check_invariants(), Ok(()))
  assert_eq(by_all, by_in)
}

///|
test "drop_nulls_in with empty name list is a no-op (no gating columns)" {
  let df = drop_nulls_df()
  let out = drop_nulls_in(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "drop_nulls_in tolerates duplicate names" {
  let df = drop_nulls_df()
  // Asking the same column to gate twice is the same as asking once.
  let dedup = drop_nulls_in(df, ["a"]).unwrap()
  let dup = drop_nulls_in(df, ["a", "a"]).unwrap()
  assert_eq(dedup, dup)
}

///|
test "drop_nulls_in on a column with no nulls is a no-op" {
  let df = drop_nulls_df()
  // Column "s" has no nulls — gating on it must keep every row.
  let out = drop_nulls_in(df, ["s"]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "drop_nulls_in supports a string column whose dtype carries no nulls" {
  // A frame whose only null-bearing column is NOT in the gate list.
  // The single-row outcome is row 2 surviving even though "b" is null
  // there — confirming we are reading the validity bitmap of the
  // listed columns only, not the row as a whole.
  let df = drop_nulls_df()
  let out = drop_nulls_in(df, ["s"]).unwrap()
  // All four rows survive.
  assert_eq(out.shape(), (4, 3))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Null))
}

// ── drop_nulls_in — error cases ──────────────────────────────────────

///|
test "drop_nulls_in rejects an unknown column with ColumnNotFound" {
  let df = drop_nulls_df()
  assert_eq(
    drop_nulls_in(df, ["missing"]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The input is unchanged and still well-formed.
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "drop_nulls_in reports the first offending name" {
  let df = drop_nulls_df()
  // The first spec is fine; the second is missing → ColumnNotFound("z").
  assert_eq(
    drop_nulls_in(df, ["a", "z", "missing"]),
    Err(@types.DataError::ColumnNotFound("z")),
  )
}

// ── Cross-API equivalence with Series::drop_nulls ────────────────────

///|
test "drop_nulls on a single-column frame matches Series::drop_nulls cell-by-cell" {
  let series = @frame.Series::from_int_options("a", [
    Some(1),
    None,
    Some(3),
    None,
    Some(5),
  ])
  let df = @frame.DataFrame::new([series]).unwrap()
  let out = drop_nulls(df).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  let cleaned = series.drop_nulls()
  assert_eq(out.shape(), (cleaned.len(), 1))
  for i in 0..<cleaned.len() {
    assert_eq(out.get(i, "a"), cleaned.get(i))
  }
}
