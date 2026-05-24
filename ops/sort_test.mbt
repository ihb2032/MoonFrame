// Blackbox tests for `@ops.sort_by` and `@ops.sort_by_many`.
//
// Invariants asserted on every successful sort:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) result.schema() == df.schema() — sort is row-only, columns
//       (names, dtypes, order) survive verbatim
//   (3) result.columns() == df.columns() — column order is stable
//   (4) result.shape() == df.shape() — sort is a permutation, not a
//       projection
//   (5) reading any cell in `result` round-trips back to the
//       corresponding cell in `df` at the source row index
//
// Stability is a per-test obligation: tests that exercise the
// stable-sort guarantee carry a "stability" tag in the test name and
// inspect a tiebreaker column.

// ── SortSpec — builder semantics, exercised behaviorally ─────────────

///|
test "SortSpec::asc produces ascending order with NullsLast as default" {
  // The builder's contract is verified by the resulting permutation:
  // ascending puts smaller real values first, default null placement
  // pushes missing rows to the end.
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(2), None, Some(1), Some(3)]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("a")).unwrap()
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(3, "a"), Ok(@types.Scalar::Null))
}

///|
test "SortSpec::desc produces descending order with NullsLast as default" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(2), None, Some(1), Some(3)]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::desc("a")).unwrap()
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(3, "a"), Ok(@types.Scalar::Null))
}

///|
test "SortSpec::with_null_order overrides null placement without touching the direction" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [Some(2), None, Some(1)]),
  ]).unwrap()
  // asc + NullsFirst — value order still ascending, but null moves
  // to the head.
  let out_asc = sort_by(df, SortSpec::asc("a").with_null_order(NullsFirst)).unwrap()
  assert_eq(out_asc.get(0, "a"), Ok(@types.Scalar::Null))
  assert_eq(out_asc.get(1, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out_asc.get(2, "a"), Ok(@types.Scalar::Int(2)))
  // desc + NullsFirst — value order descends but null still leads.
  let out_desc = sort_by(df, SortSpec::desc("a").with_null_order(NullsFirst)).unwrap()
  assert_eq(out_desc.get(0, "a"), Ok(@types.Scalar::Null))
  assert_eq(out_desc.get(1, "a"), Ok(@types.Scalar::Int(2)))
  assert_eq(out_desc.get(2, "a"), Ok(@types.Scalar::Int(1)))
}

///|
test "SortSpec::with_null_order applied twice keeps the last assignment" {
  // Idempotence proof for the builder: the final `NullsLast` overrides
  // the earlier `NullsFirst`, so the result must equal `SortSpec::asc`
  // applied directly (its default is NullsLast).
  let direct = SortSpec::asc("z")
  let chained = SortSpec::asc("z")
    .with_null_order(NullsFirst)
    .with_null_order(NullsLast)
  assert_eq(direct, chained)
}

// ── Fixture ──────────────────────────────────────────────────────────

///|
/// Five-row, four-column fixture covering Int / Float-with-null /
/// String / Bool so each sort key flavor has a dedicated column to
/// exercise. Row ordering inside `a` is intentionally non-monotonic to
/// make the ascending result observable.
fn sort_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_ints("a", [3, 1, 4, 1, 5]),
    @frame.Series::from_float_options("b", [
      Some((2.5 : Float)),
      None,
      Some((1.5 : Float)),
      Some((4.5 : Float)),
      None,
    ]),
    @frame.Series::from_strings("s", ["pear", "apple", "fig", "date", "berry"]),
    @frame.Series::from_bools("t", [true, false, true, false, true]),
  ]).unwrap()
}

// ── Single-key sort: Int ─────────────────────────────────────────────

///|
test "sort_by Int ascending reorders rows by the key" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::asc("a")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.shape(), df.shape())
  // a sorted ascending: 1, 1, 3, 4, 5 — and the two 1s keep their
  // original relative order (stability) so the tiebreaker `s` reads
  // "apple" (row 1) then "date" (row 3).
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(3, "a"), Ok(@types.Scalar::Int(4)))
  assert_eq(out.get(4, "a"), Ok(@types.Scalar::Int(5)))
  // Stability witness via the secondary column `s`.
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("date")))
}

///|
test "sort_by Int descending mirrors the ascending order" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::desc("a")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // a sorted descending: 5, 4, 3, 1, 1. Stability still holds on
  // the two 1s (apple before date — original row order).
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(5)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(4)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(3, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(4, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(3, "s"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(4, "s"), Ok(@types.Scalar::String("date")))
}

// ── Single-key sort: Float with nulls ────────────────────────────────

///|
test "sort_by Float ascending places nulls last by default" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::asc("b")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // b values: 2.5, Null, 1.5, 4.5, Null → asc/NullsLast = 1.5, 2.5,
  // 4.5, Null, Null.
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Float(2.5)))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Float(4.5)))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(4, "b"), Ok(@types.Scalar::Null))
  // Stability between the two nulls (original rows 1 and 4 → s =
  // "apple" then s = "berry").
  assert_eq(out.get(3, "s"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(4, "s"), Ok(@types.Scalar::String("berry")))
}

///|
test "sort_by Float NullsFirst pushes missing values to the top" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::asc("b").with_null_order(NullsFirst)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // asc/NullsFirst = Null, Null, 1.5, 2.5, 4.5.
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Float(2.5)))
  assert_eq(out.get(4, "b"), Ok(@types.Scalar::Float(4.5)))
  // Stability among the nulls preserves original order.
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("berry")))
}

///|
test "sort_by Float with equal values preserves original order (stability)" {
  // The Float comparator's value-equal arm only fires when two
  // non-null, non-NaN floats compare equal. Two 1.0s in the fixture
  // exercise that arm; stability requires their original ordering to
  // survive (tag "b" before tag "c").
  let df = @frame.DataFrame::new([
    @frame.Series::from_floats("v", [3.0, 1.0, 1.0, 2.0]),
    @frame.Series::from_strings("tag", ["a", "b", "c", "d"]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("v")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "v"), Ok(@types.Scalar::Float(1.0)))
  assert_eq(out.get(1, "v"), Ok(@types.Scalar::Float(1.0)))
  assert_eq(out.get(0, "tag"), Ok(@types.Scalar::String("b")))
  assert_eq(out.get(1, "tag"), Ok(@types.Scalar::String("c")))
  assert_eq(out.get(2, "v"), Ok(@types.Scalar::Float(2.0)))
  assert_eq(out.get(3, "v"), Ok(@types.Scalar::Float(3.0)))
}

///|
test "sort_by Float descending NullsLast" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::desc("b")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // desc/NullsLast = 4.5, 2.5, 1.5, Null, Null.
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Float(4.5)))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Float(2.5)))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(4, "b"), Ok(@types.Scalar::Null))
}

///|
test "sort_by Float descending NullsFirst" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::desc("b").with_null_order(NullsFirst)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // desc/NullsFirst = Null, Null, 4.5, 2.5, 1.5.
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Null))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Float(4.5)))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Float(2.5)))
  assert_eq(out.get(4, "b"), Ok(@types.Scalar::Float(1.5)))
}

// ── Single-key sort: String ──────────────────────────────────────────

///|
test "sort_by String ascending is lexicographic" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::asc("s")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // "apple" < "berry" < "date" < "fig" < "pear".
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("berry")))
  assert_eq(out.get(2, "s"), Ok(@types.Scalar::String("date")))
  assert_eq(out.get(3, "s"), Ok(@types.Scalar::String("fig")))
  assert_eq(out.get(4, "s"), Ok(@types.Scalar::String("pear")))
  // And `a` follows along: 1, 5, 1, 4, 3.
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(4, "a"), Ok(@types.Scalar::Int(3)))
}

///|
test "sort_by String descending reverses the lexicographic order" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::desc("s")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("pear")))
  assert_eq(out.get(4, "s"), Ok(@types.Scalar::String("apple")))
}

///|
test "sort_by String breaks length ties lexicographically (shorter wins on prefix match)" {
  // The fixture is intentionally chosen so the merge sort exercises
  // both length-tiebreak branches of `compare_string_lex`:
  //   * "abc" vs "ab"  → equal on the first two chars, then la > lb
  //     → the longer string sorts after.
  //   * "ab"  vs "abc" → equal on the first two chars, then la < lb
  //     → the shorter string sorts before.
  // A naive sort that compared by length first (MoonBit's built-in
  // `<` on `String`) would put "ab" before "abd" *and* before "abc",
  // not catching the char-by-char difference between "abc" and "abd".
  let df = @frame.DataFrame::new([
    @frame.Series::from_strings("s", ["abd", "ab", "abc"]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("s")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("ab")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("abc")))
  assert_eq(out.get(2, "s"), Ok(@types.Scalar::String("abd")))
}

// ── Single-key sort: Bool ────────────────────────────────────────────

///|
test "sort_by Bool ascending puts false before true (stable)" {
  let df = sort_df()
  let out = sort_by(df, SortSpec::asc("t")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // t = [true, false, true, false, true].
  // asc: false, false, true, true, true. Stable: rows 1, 3, then
  // 0, 2, 4 (in their original relative order).
  assert_eq(out.get(0, "t"), Ok(@types.Scalar::Bool(false)))
  assert_eq(out.get(1, "t"), Ok(@types.Scalar::Bool(false)))
  assert_eq(out.get(2, "t"), Ok(@types.Scalar::Bool(true)))
  assert_eq(out.get(3, "t"), Ok(@types.Scalar::Bool(true)))
  assert_eq(out.get(4, "t"), Ok(@types.Scalar::Bool(true)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("apple")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("date")))
  assert_eq(out.get(2, "s"), Ok(@types.Scalar::String("pear")))
  assert_eq(out.get(3, "s"), Ok(@types.Scalar::String("fig")))
  assert_eq(out.get(4, "s"), Ok(@types.Scalar::String("berry")))
}

// ── Multi-key sort ───────────────────────────────────────────────────

///|
test "sort_by_many: secondary key only matters for tied primaries" {
  // Two-column fixture: a has ties (X, X, Y, Y), b distinguishes.
  let df = @frame.DataFrame::new([
    @frame.Series::from_strings("a", ["X", "X", "Y", "Y"]),
    @frame.Series::from_ints("b", [2, 1, 2, 1]),
  ]).unwrap()
  let out = sort_by_many(df, [SortSpec::asc("a"), SortSpec::asc("b")]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::String("X")))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::String("X")))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::String("Y")))
  assert_eq(out.get(2, "b"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(3, "a"), Ok(@types.Scalar::String("Y")))
  assert_eq(out.get(3, "b"), Ok(@types.Scalar::Int(2)))
}

///|
test "sort_by_many: primary asc + secondary desc" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_strings("dept", ["eng", "eng", "ops", "ops", "ops"]),
    @frame.Series::from_ints("salary", [100, 200, 50, 150, 75]),
  ]).unwrap()
  let out = sort_by_many(df, [SortSpec::asc("dept"), SortSpec::desc("salary")]).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Within eng (sorted asc), salaries desc: 200, 100.
  assert_eq(out.get(0, "dept"), Ok(@types.Scalar::String("eng")))
  assert_eq(out.get(0, "salary"), Ok(@types.Scalar::Int(200)))
  assert_eq(out.get(1, "salary"), Ok(@types.Scalar::Int(100)))
  // Within ops, salaries desc: 150, 75, 50.
  assert_eq(out.get(2, "dept"), Ok(@types.Scalar::String("ops")))
  assert_eq(out.get(2, "salary"), Ok(@types.Scalar::Int(150)))
  assert_eq(out.get(3, "salary"), Ok(@types.Scalar::Int(75)))
  assert_eq(out.get(4, "salary"), Ok(@types.Scalar::Int(50)))
}

///|
test "sort_by_many: empty specs is an identity sort" {
  let df = sort_df()
  let out = sort_by_many(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Stability turns "no keys, every comparison ties" into the
  // identity permutation.
  assert_eq(out, df)
}

// ── Stability stress: all keys equal ─────────────────────────────────

///|
test "sort_by on an all-equal column is the identity (stability)" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("k", [7, 7, 7, 7, 7]),
    @frame.Series::from_strings("tag", ["a", "b", "c", "d", "e"]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("k")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Every row tied → original order preserved.
  assert_eq(out, df)
}

// ── Edge cases: empty / single-row / all-null ────────────────────────

///|
test "sort_by on a 0x0 frame returns the same 0x0 frame" {
  let df = @frame.DataFrame::new([]).unwrap()
  let out = sort_by_many(df, []).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "sort_by on a 0-row frame preserves the schema and stays empty" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::String),
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = sort_by(df, SortSpec::asc("a")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "sort_by on a single-row frame is the identity" {
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [42])]).unwrap()
  let out = sort_by(df, SortSpec::desc("a")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "sort_by on an all-null Int column is a stable identity" {
  let df = @frame.DataFrame::new([
    @frame.Series::from_int_options("a", [None, None, None]),
    @frame.Series::from_strings("s", ["x", "y", "z"]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("a")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Every row is missing → null-vs-null is a tie → stability preserves
  // the original order regardless of NullsFirst / NullsLast.
  assert_eq(out, df)
  // Same outcome with NullsFirst.
  let out_first = sort_by(df, SortSpec::asc("a").with_null_order(NullsFirst)).unwrap()
  assert_eq(out_first, df)
}

// ── NaN handling: Float NaN is treated as null ───────────────────────

///|
test "sort_by Float treats NaN identically to Null (NullsLast)" {
  let nan = (0.0 : Float) / (0.0 : Float)
  let df = @frame.DataFrame::new([
    @frame.Series::from_float_options("v", [
      Some((1.0 : Float)),
      Some(nan),
      Some((2.0 : Float)),
      None,
    ]),
    @frame.Series::from_strings("s", ["one", "nan", "two", "null"]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("v")).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // Reals first (1.0, 2.0) then NaN-and-Null bucket in original order
  // (nan came before null in the source).
  assert_eq(out.get(0, "v"), Ok(@types.Scalar::Float(1.0)))
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("one")))
  assert_eq(out.get(1, "v"), Ok(@types.Scalar::Float(2.0)))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("two")))
  // Position 2: the NaN. Reading it back as Scalar yields a non-null
  // Float because the validity bit is still 1 — NaN is *valid* in
  // Arrow terms, the sort treats it as missing only for ordering.
  assert_eq(out.get(2, "s"), Ok(@types.Scalar::String("nan")))
  let v2 = out.get(2, "v").unwrap()
  match v2 {
    @types.Scalar::Float(f) => assert_true(f.is_nan())
    _ => abort("unreachable: NaN slot should still read back as Scalar::Float")
  }
  // Position 3: the actual Null.
  assert_eq(out.get(3, "v"), Ok(@types.Scalar::Null))
  assert_eq(out.get(3, "s"), Ok(@types.Scalar::String("null")))
}

///|
test "sort_by Float NullsFirst groups NaN with Null at the top" {
  let nan = (0.0 : Float) / (0.0 : Float)
  let df = @frame.DataFrame::new([
    @frame.Series::from_float_options("v", [
      Some((1.0 : Float)),
      Some(nan),
      None,
    ]),
    @frame.Series::from_strings("s", ["one", "nan", "null"]),
  ]).unwrap()
  let out = sort_by(df, SortSpec::asc("v").with_null_order(NullsFirst)).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  // NullsFirst groups NaN + Null at the start (stable: nan first,
  // then null).
  assert_eq(out.get(0, "s"), Ok(@types.Scalar::String("nan")))
  assert_eq(out.get(1, "s"), Ok(@types.Scalar::String("null")))
  assert_eq(out.get(2, "v"), Ok(@types.Scalar::Float(1.0)))
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "sort_by rejects an unknown column with ColumnNotFound" {
  let df = sort_df()
  assert_eq(
    sort_by(df, SortSpec::asc("missing")),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The input frame stays well-formed (the validator runs before any
  // mutation could happen).
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "sort_by_many surfaces ColumnNotFound on the first offending spec" {
  let df = sort_df()
  // The first spec is fine; the second has the missing name.
  assert_eq(
    sort_by_many(df, [SortSpec::asc("a"), SortSpec::asc("missing")]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "sort_by exercises the build_sort_key dispatch on each dtype" {
  // The dispatch in `build_sort_key` cascades through the four typed
  // accessors. To cover every cascade step, sort once per dtype —
  // `Int` hits the first arm, `Float` falls through to the second,
  // `Bool` to the third, and `String` reaches the terminal unwrap.
  let df = @frame.DataFrame::new([
    @frame.Series::from_ints("i", [2, 1]),
    @frame.Series::from_floats("f", [(2.0 : Float), (1.0 : Float)]),
    @frame.Series::from_bools("b", [true, false]),
    @frame.Series::from_strings("s", ["y", "x"]),
  ]).unwrap()
  let by_int = sort_by(df, SortSpec::asc("i")).unwrap()
  assert_eq(by_int.get(0, "i"), Ok(@types.Scalar::Int(1)))
  let by_float = sort_by(df, SortSpec::asc("f")).unwrap()
  assert_eq(by_float.get(0, "f"), Ok(@types.Scalar::Float(1.0)))
  let by_bool = sort_by(df, SortSpec::asc("b")).unwrap()
  assert_eq(by_bool.get(0, "b"), Ok(@types.Scalar::Bool(false)))
  let by_string = sort_by(df, SortSpec::asc("s")).unwrap()
  assert_eq(by_string.get(0, "s"), Ok(@types.Scalar::String("x")))
}

// ── Cross-API equivalence ────────────────────────────────────────────

///|
test "sort_by(spec) == sort_by_many([spec]) for any spec" {
  let df = sort_df()
  let single = sort_by(df, SortSpec::desc("b")).unwrap()
  let many = sort_by_many(df, [SortSpec::desc("b")]).unwrap()
  assert_eq(single, many)
}

///|
test "sort_by is idempotent — sorting an already-sorted frame is a no-op" {
  let df = sort_df()
  let once = sort_by(df, SortSpec::asc("a")).unwrap()
  let twice = sort_by(once, SortSpec::asc("a")).unwrap()
  assert_eq(once, twice)
}
