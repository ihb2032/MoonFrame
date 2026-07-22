// Blackbox tests for `DataFrame::drop_nulls`, the single null-dropping
// verb. `subset` is omitted to gate on every column, or passed as
// `Array[Expr]` keys (resolved to names via `Expr::output_name`) to gate on
// a subset.
//
// Invariants asserted on every successful drop:
//   (1) check_invariants() == Ok(()) — formal spec from invariants.mbt
//   (2) result.schema() == df.schema() — drop is row-only
//   (3) result.columns() == df.columns() — column order + names stable
//   (4) result.nrows() equals the number of rows that survived the gate

///|
/// Four-row, three-column fixture mixing nullable Int, nullable Float
/// and a fully-valid String. The two null-bearing columns intentionally
/// drop nulls on **different** rows so the union semantics of
/// `drop_nulls()` (drop on any null) and the per-column semantics of
/// `drop_nulls(subset=...)` (drop only when *listed* columns are null) are
/// both observable.
fn drop_nulls_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3), Some(4)]),
    Series::from_float_options("b", [
      Some((1.5 : Double)),
      Some((2.5 : Double)),
      None,
      Some((4.5 : Double)),
    ]),
    Series::from_strings("s", ["w", "x", "y", "z"]),
  ])
}

// ── drop_nulls() — gate on every column ──────────────────────────────

///|
test "drop_nulls keeps only rows that are valid in every column" {
  let df = drop_nulls_df()
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  // Row 0 (a=1, b=1.5, s="w") and row 3 (a=4, b=4.5, s="z") survive;
  // rows 1 and 2 each carry one null and are dropped.
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.item(0, "s"), @types.Scalar::String("w"))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(4))
  assert_eq(out.item(1, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.item(1, "s"), @types.Scalar::String("z"))
}

///|
test "drop_nulls is a no-op on a fully-valid frame" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("s", ["x", "y", "z"]),
  ])
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  // Same shape, same contents — but a freshly built frame, so
  // structural equality is the right witness.
  assert_eq(out, df)
}

///|
test "drop_nulls keeps non-null NaN cells: NaN is a value, not a null" {
  let nan : Double = @double.not_a_number
  // `nf` is a Numeric-backed (all-valid) column carrying a NaN *value*;
  // `of` is option-backed with a genuine null at row 2 and a NaN value at
  // row 3. drop_nulls drops only the missing row — both NaN rows survive,
  // because NaN is a value and only validity-0 cells count as null.
  let df = DataFrame::new([
    Series::from_floats("nf", [1.0, nan, 3.0, 4.0]),
    Series::from_float_options("of", [Some(1.0), Some(2.0), None, Some(nan)]),
  ])
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  // Only row 2 (of is null) drops; rows 0, 1 and 3 survive.
  assert_eq(out.nrows(), 3)
  assert_true(out.item(1, "nf").as_float().is_nan()) // Numeric NaN kept
  assert_true(out.item(2, "of").as_float().is_nan()) // option NaN kept (was row 3)
}

///|
test "drop_nulls collapses to a 0-row frame when every row has at least one null" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None]),
    Series::from_float_options("b", [None, Some((2.0 : Double))]),
  ])
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  // Row 0: b null. Row 1: a null. Both drop, schema survives.
  assert_eq(out.schema(), df.schema())
  assert_eq(out.shape(), (0, 2))
}

///|
test "drop_nulls on a 0-row frame preserves the schema" {
  let schema = @types.Schema::new([
    @types.Field("a", @types.DataType::Int),
    @types.Field("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "drop_nulls on a 0x0 frame returns the same 0x0 frame" {
  let df = DataFrame::new([])
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "drop_nulls on an all-null column drops every row" {
  let df = DataFrame::new([
    Series::from_int_options("a", [None, None, None]),
    Series::from_strings("s", ["x", "y", "z"]),
  ])
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 2))
}

// ── drop_nulls(subset=...) — gate on the listed columns ──────────────

///|
test "drop_nulls(subset) only consults the listed columns" {
  let df = drop_nulls_df()
  // Gate on "a" only: drops row 1 (a=Null). Row 2's b=Null does NOT
  // disqualify the row anymore.
  let out = df.drop_nulls(subset=[@expr.col("a")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(4))
  // The b=Null cell on the surviving row 2 must still read as Null
  // — drop_nulls does not fill or alter cells.
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
}

///|
test "drop_nulls(subset) listing every column equals drop_nulls()" {
  let df = drop_nulls_df()
  let by_all = df.drop_nulls()
  let by_in = df.drop_nulls(subset=[
    @expr.col("a"),
    @expr.col("b"),
    @expr.col("s"),
  ])
  assert_eq(by_in.check_invariants(), Ok(()))
  assert_eq(by_all, by_in)
}

///|
test "drop_nulls(subset=[]) is a no-op (no gating columns)" {
  let df = drop_nulls_df()
  let out = df.drop_nulls(subset=[])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "drop_nulls(subset) tolerates duplicate keys" {
  let df = drop_nulls_df()
  // Asking the same column to gate twice is the same as asking once.
  let dedup = df.drop_nulls(subset=[@expr.col("a")])
  let dup = df.drop_nulls(subset=[@expr.col("a"), @expr.col("a")])
  assert_eq(dedup, dup)
}

///|
test "drop_nulls(subset) on a column with no nulls is a no-op" {
  let df = drop_nulls_df()
  // Column "s" has no nulls — gating on it must keep every row.
  let out = df.drop_nulls(subset=[@expr.col("s")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "drop_nulls(subset) reads only the listed columns' validity bitmaps" {
  // A frame whose only null-bearing column is NOT in the gate list.
  // Row 2 survives even though "b" is null there — confirming we are
  // reading the validity bitmap of the listed columns only.
  let df = drop_nulls_df()
  let out = df.drop_nulls(subset=[@expr.col("s")])
  // All four rows survive.
  assert_eq(out.shape(), (4, 3))
  assert_eq(out.item(2, "b"), @types.Scalar::Null)
}

///|
test "drop_nulls(subset) resolves each key by output_name" {
  let df = drop_nulls_df()
  // An aliased key gates on the column named by the alias (`output_name`'s
  // alias-wins rule): `col("b").with_alias("a")` gates on "a", so it drops
  // row 1 — identical to gating on `col("a")`, never on "b".
  let out = df.drop_nulls(subset=[@expr.col("b").with_alias("a")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df.drop_nulls(subset=[@expr.col("a")]))
  // Row 2 (b=Null but a non-null) survives, proving "b" never gated.
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
}

// ── drop_nulls(subset=...) — error cases ─────────────────────────────

///|
test "drop_nulls(subset) rejects an unknown column with ColumnNotFound" {
  let df = drop_nulls_df()
  assert_eq(
    Ok(df.drop_nulls(subset=[@expr.col("missing")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The input is unchanged and still well-formed.
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "drop_nulls(subset) reports the first offending key" {
  let df = drop_nulls_df()
  // The first key is fine; the second is missing → ColumnNotFound("z").
  assert_eq(
    Ok(
      df.drop_nulls(subset=[
        @expr.col("a"),
        @expr.col("z"),
        @expr.col("missing"),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("z")),
  )
}

// ── Cross-API equivalence with Series::drop_nulls ────────────────────

///|
test "drop_nulls on a single-column frame matches Series::drop_nulls cell-by-cell" {
  let series = Series::from_int_options("a", [
    Some(1),
    None,
    Some(3),
    None,
    Some(5),
  ])
  let df = DataFrame::new([series])
  let out = df.drop_nulls()
  assert_eq(out.check_invariants(), Ok(()))
  let cleaned = series.drop_nulls()
  assert_eq(out.shape(), (cleaned.len(), 1))
  for i in 0..<cleaned.len() {
    assert_eq(out.item(i, "a"), cleaned.get(i))
  }
}
