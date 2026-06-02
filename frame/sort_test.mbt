// Blackbox tests for `DataFrame::sort_by` (single-key and multi-key via
// the `IntoSortSpecs` trait — `sort_by(spec)` and `sort_by([spec, ...])`
// share one method).
//
// Invariants asserted on every successful sort:
//   (1) check_invariants() == Ok(()) — formal spec from invariants.mbt
//   (2) result.schema() == df.schema() — sort is row-only, columns
//       (names, dtypes, order) survive verbatim
//   (3) result.columns() == df.columns() — column order is stable
//   (4) result.shape() == df.shape() — sort is a permutation, not a
//       projection
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
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(2), None, Some(1), Some(3)]),
  ])
  let out = df.sort_by(SortSpec::asc("a"))
  assert_eq(out.get(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(1, "a"), @types.Scalar::Int(2))
  assert_eq(out.get(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.get(3, "a"), @types.Scalar::Null)
}

///|
test "SortSpec::desc produces descending order with NullsLast as default" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(2), None, Some(1), Some(3)]),
  ])
  let out = df.sort_by(SortSpec::desc("a"))
  assert_eq(out.get(0, "a"), @types.Scalar::Int(3))
  assert_eq(out.get(1, "a"), @types.Scalar::Int(2))
  assert_eq(out.get(2, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(3, "a"), @types.Scalar::Null)
}

///|
test "SortSpec::with_null_order overrides null placement without touching the direction" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(2), None, Some(1)]),
  ])
  // asc + NullsFirst — value order still ascending, but null moves
  // to the head.
  let out_asc = df.sort_by(SortSpec::asc("a").with_null_order(NullsFirst))
  assert_eq(out_asc.get(0, "a"), @types.Scalar::Null)
  assert_eq(out_asc.get(1, "a"), @types.Scalar::Int(1))
  assert_eq(out_asc.get(2, "a"), @types.Scalar::Int(2))
  // desc + NullsFirst — value order descends but null still leads.
  let out_desc = df.sort_by(SortSpec::desc("a").with_null_order(NullsFirst))
  assert_eq(out_desc.get(0, "a"), @types.Scalar::Null)
  assert_eq(out_desc.get(1, "a"), @types.Scalar::Int(2))
  assert_eq(out_desc.get(2, "a"), @types.Scalar::Int(1))
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
fn sort_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [3, 1, 4, 1, 5]),
    Series::from_float_options("b", [
      Some((2.5 : Double)),
      None,
      Some((1.5 : Double)),
      Some((4.5 : Double)),
      None,
    ]),
    Series::from_strings("s", ["pear", "apple", "fig", "date", "berry"]),
    Series::from_bools("t", [true, false, true, false, true]),
  ])
}

// ── Single-key sort: Int ─────────────────────────────────────────────

///|
test "sort_by Int ascending reorders rows by the key" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::asc("a"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.shape(), df.shape())
  // a sorted ascending: 1, 1, 3, 4, 5 — and the two 1s keep their
  // original relative order (stability) so the tiebreaker `s` reads
  // "apple" (row 1) then "date" (row 3).
  assert_eq(out.get(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(1, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.get(3, "a"), @types.Scalar::Int(4))
  assert_eq(out.get(4, "a"), @types.Scalar::Int(5))
  // Stability witness via the secondary column `s`.
  assert_eq(out.get(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.get(1, "s"), @types.Scalar::String("date"))
}

///|
test "sort_by Int descending mirrors the ascending order" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::desc("a"))
  assert_eq(out.check_invariants(), Ok(()))
  // a sorted descending: 5, 4, 3, 1, 1. Stability still holds on
  // the two 1s (apple before date — original row order).
  assert_eq(out.get(0, "a"), @types.Scalar::Int(5))
  assert_eq(out.get(1, "a"), @types.Scalar::Int(4))
  assert_eq(out.get(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.get(3, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(4, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(3, "s"), @types.Scalar::String("apple"))
  assert_eq(out.get(4, "s"), @types.Scalar::String("date"))
}

// ── Single-key sort: Float with nulls ────────────────────────────────

///|
test "sort_by Float ascending places nulls last by default" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::asc("b"))
  assert_eq(out.check_invariants(), Ok(()))
  // b values: 2.5, Null, 1.5, 4.5, Null → asc/NullsLast = 1.5, 2.5,
  // 4.5, Null, Null.
  assert_eq(out.get(0, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.get(1, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.get(2, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.get(3, "b"), @types.Scalar::Null)
  assert_eq(out.get(4, "b"), @types.Scalar::Null)
  // Stability between the two nulls (original rows 1 and 4 → s =
  // "apple" then s = "berry").
  assert_eq(out.get(3, "s"), @types.Scalar::String("apple"))
  assert_eq(out.get(4, "s"), @types.Scalar::String("berry"))
}

///|
test "sort_by Float NullsFirst pushes missing values to the top" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::asc("b").with_null_order(NullsFirst))
  assert_eq(out.check_invariants(), Ok(()))
  // asc/NullsFirst = Null, Null, 1.5, 2.5, 4.5.
  assert_eq(out.get(0, "b"), @types.Scalar::Null)
  assert_eq(out.get(1, "b"), @types.Scalar::Null)
  assert_eq(out.get(2, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.get(3, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.get(4, "b"), @types.Scalar::Float(4.5))
  // Stability among the nulls preserves original order.
  assert_eq(out.get(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.get(1, "s"), @types.Scalar::String("berry"))
}

///|
test "sort_by Float with equal values preserves original order (stability)" {
  // The Float comparator's value-equal arm only fires when two
  // non-null, non-NaN floats compare equal. Two 1.0s in the fixture
  // exercise that arm; stability requires their original ordering to
  // survive (tag "b" before tag "c").
  let df = DataFrame::new([
    Series::from_floats("v", [3.0, 1.0, 1.0, 2.0]),
    Series::from_strings("tag", ["a", "b", "c", "d"]),
  ])
  let out = df.sort_by(SortSpec::asc("v"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "v"), @types.Scalar::Float(1.0))
  assert_eq(out.get(1, "v"), @types.Scalar::Float(1.0))
  assert_eq(out.get(0, "tag"), @types.Scalar::String("b"))
  assert_eq(out.get(1, "tag"), @types.Scalar::String("c"))
  assert_eq(out.get(2, "v"), @types.Scalar::Float(2.0))
  assert_eq(out.get(3, "v"), @types.Scalar::Float(3.0))
}

///|
test "sort_by Float descending NullsLast" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::desc("b"))
  assert_eq(out.check_invariants(), Ok(()))
  // desc/NullsLast = 4.5, 2.5, 1.5, Null, Null.
  assert_eq(out.get(0, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.get(1, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.get(2, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.get(3, "b"), @types.Scalar::Null)
  assert_eq(out.get(4, "b"), @types.Scalar::Null)
}

///|
test "sort_by Float descending NullsFirst" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::desc("b").with_null_order(NullsFirst))
  assert_eq(out.check_invariants(), Ok(()))
  // desc/NullsFirst = Null, Null, 4.5, 2.5, 1.5.
  assert_eq(out.get(0, "b"), @types.Scalar::Null)
  assert_eq(out.get(1, "b"), @types.Scalar::Null)
  assert_eq(out.get(2, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.get(3, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.get(4, "b"), @types.Scalar::Float(1.5))
}

// ── Single-key sort: String ──────────────────────────────────────────

///|
test "sort_by String ascending is lexicographic" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::asc("s"))
  assert_eq(out.check_invariants(), Ok(()))
  // "apple" < "berry" < "date" < "fig" < "pear".
  assert_eq(out.get(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.get(1, "s"), @types.Scalar::String("berry"))
  assert_eq(out.get(2, "s"), @types.Scalar::String("date"))
  assert_eq(out.get(3, "s"), @types.Scalar::String("fig"))
  assert_eq(out.get(4, "s"), @types.Scalar::String("pear"))
  // And `a` follows along: 1, 5, 1, 4, 3.
  assert_eq(out.get(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(4, "a"), @types.Scalar::Int(3))
}

///|
test "sort_by String descending reverses the lexicographic order" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::desc("s"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "s"), @types.Scalar::String("pear"))
  assert_eq(out.get(4, "s"), @types.Scalar::String("apple"))
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
  let df = DataFrame::new([Series::from_strings("s", ["abd", "ab", "abc"])])
  let out = df.sort_by(SortSpec::asc("s"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "s"), @types.Scalar::String("ab"))
  assert_eq(out.get(1, "s"), @types.Scalar::String("abc"))
  assert_eq(out.get(2, "s"), @types.Scalar::String("abd"))
}

// ── Single-key sort: Bool ────────────────────────────────────────────

///|
test "sort_by Bool ascending puts false before true (stable)" {
  let df = sort_df()
  let out = df.sort_by(SortSpec::asc("t"))
  assert_eq(out.check_invariants(), Ok(()))
  // t = [true, false, true, false, true].
  // asc: false, false, true, true, true. Stable: rows 1, 3, then
  // 0, 2, 4 (in their original relative order).
  assert_eq(out.get(0, "t"), @types.Scalar::Bool(false))
  assert_eq(out.get(1, "t"), @types.Scalar::Bool(false))
  assert_eq(out.get(2, "t"), @types.Scalar::Bool(true))
  assert_eq(out.get(3, "t"), @types.Scalar::Bool(true))
  assert_eq(out.get(4, "t"), @types.Scalar::Bool(true))
  assert_eq(out.get(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.get(1, "s"), @types.Scalar::String("date"))
  assert_eq(out.get(2, "s"), @types.Scalar::String("pear"))
  assert_eq(out.get(3, "s"), @types.Scalar::String("fig"))
  assert_eq(out.get(4, "s"), @types.Scalar::String("berry"))
}

// ── Multi-key sort ───────────────────────────────────────────────────

///|
test "sort_by multi-key: secondary key only matters for tied primaries" {
  // Two-column fixture: a has ties (X, X, Y, Y), b distinguishes.
  let df = DataFrame::new([
    Series::from_strings("a", ["X", "X", "Y", "Y"]),
    Series::from_ints("b", [2, 1, 2, 1]),
  ])
  let out = df.sort_by([SortSpec::asc("a"), SortSpec::asc("b")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get(0, "a"), @types.Scalar::String("X"))
  assert_eq(out.get(0, "b"), @types.Scalar::Int(1))
  assert_eq(out.get(1, "a"), @types.Scalar::String("X"))
  assert_eq(out.get(1, "b"), @types.Scalar::Int(2))
  assert_eq(out.get(2, "a"), @types.Scalar::String("Y"))
  assert_eq(out.get(2, "b"), @types.Scalar::Int(1))
  assert_eq(out.get(3, "a"), @types.Scalar::String("Y"))
  assert_eq(out.get(3, "b"), @types.Scalar::Int(2))
}

///|
test "sort_by multi-key: primary asc + secondary desc" {
  let df = DataFrame::new([
    Series::from_strings("dept", ["eng", "eng", "ops", "ops", "ops"]),
    Series::from_ints("salary", [100, 200, 50, 150, 75]),
  ])
  let out = df.sort_by([SortSpec::asc("dept"), SortSpec::desc("salary")])
  assert_eq(out.check_invariants(), Ok(()))
  // Within eng (sorted asc), salaries desc: 200, 100.
  assert_eq(out.get(0, "dept"), @types.Scalar::String("eng"))
  assert_eq(out.get(0, "salary"), @types.Scalar::Int(200))
  assert_eq(out.get(1, "salary"), @types.Scalar::Int(100))
  // Within ops, salaries desc: 150, 75, 50.
  assert_eq(out.get(2, "dept"), @types.Scalar::String("ops"))
  assert_eq(out.get(2, "salary"), @types.Scalar::Int(150))
  assert_eq(out.get(3, "salary"), @types.Scalar::Int(75))
  assert_eq(out.get(4, "salary"), @types.Scalar::Int(50))
}

///|
test "sort_by multi-key: empty specs is an identity sort" {
  let df = sort_df()
  let out = df.sort_by(([] : Array[SortSpec]))
  assert_eq(out.check_invariants(), Ok(()))
  // Stability turns "no keys, every comparison ties" into the
  // identity permutation.
  assert_eq(out, df)
}

// ── Stability stress: all keys equal ─────────────────────────────────

///|
test "sort_by on an all-equal column is the identity (stability)" {
  let df = DataFrame::new([
    Series::from_ints("k", [7, 7, 7, 7, 7]),
    Series::from_strings("tag", ["a", "b", "c", "d", "e"]),
  ])
  let out = df.sort_by(SortSpec::asc("k"))
  assert_eq(out.check_invariants(), Ok(()))
  // Every row tied → original order preserved.
  assert_eq(out, df)
}

// ── Edge cases: empty / single-row / all-null ────────────────────────

///|
test "sort_by on a 0x0 frame returns the same 0x0 frame" {
  let df = DataFrame::new([])
  let out = df.sort_by(([] : Array[SortSpec]))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "sort_by on a 0-row frame preserves the schema and stays empty" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let out = df.sort_by(SortSpec::asc("a"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "sort_by on a single-row frame is the identity" {
  let df = DataFrame::new([Series::from_ints("a", [42])])
  let out = df.sort_by(SortSpec::desc("a"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "sort_by on an all-null Int column is a stable identity" {
  let df = DataFrame::new([
    Series::from_int_options("a", [None, None, None]),
    Series::from_strings("s", ["x", "y", "z"]),
  ])
  let out = df.sort_by(SortSpec::asc("a"))
  assert_eq(out.check_invariants(), Ok(()))
  // Every row is missing → null-vs-null is a tie → stability preserves
  // the original order regardless of NullsFirst / NullsLast.
  assert_eq(out, df)
  // Same outcome with NullsFirst.
  let out_first = df.sort_by(SortSpec::asc("a").with_null_order(NullsFirst))
  assert_eq(out_first, df)
}

// ── NaN handling: Float NaN is treated as null ───────────────────────

///|
test "sort_by Float treats NaN identically to Null (NullsLast)" {
  let nan = (0.0 : Double) / (0.0 : Double)
  let df = DataFrame::new([
    Series::from_float_options("v", [
      Some((1.0 : Double)),
      Some(nan),
      Some((2.0 : Double)),
      None,
    ]),
    Series::from_strings("s", ["one", "nan", "two", "null"]),
  ])
  let out = df.sort_by(SortSpec::asc("v"))
  assert_eq(out.check_invariants(), Ok(()))
  // Reals first (1.0, 2.0) then NaN-and-Null bucket in original order
  // (nan came before null in the source).
  assert_eq(out.get(0, "v"), @types.Scalar::Float(1.0))
  assert_eq(out.get(0, "s"), @types.Scalar::String("one"))
  assert_eq(out.get(1, "v"), @types.Scalar::Float(2.0))
  assert_eq(out.get(1, "s"), @types.Scalar::String("two"))
  // Position 2: the NaN. Reading it back as Scalar yields a non-null
  // Float because the validity bit is still 1 — NaN is *valid* in
  // Arrow terms, the sort treats it as missing only for ordering.
  assert_eq(out.get(2, "s"), @types.Scalar::String("nan"))
  let v2 = out.get(2, "v")
  match v2 {
    @types.Scalar::Float(f) => assert_true(f.is_nan())
    _ => abort("unreachable: NaN slot should still read back as Scalar::Float")
  }
  // Position 3: the actual Null.
  assert_eq(out.get(3, "v"), @types.Scalar::Null)
  assert_eq(out.get(3, "s"), @types.Scalar::String("null"))
}

///|
test "sort_by Float NullsFirst groups NaN with Null at the top" {
  let nan = (0.0 : Double) / (0.0 : Double)
  let df = DataFrame::new([
    Series::from_float_options("v", [Some((1.0 : Double)), Some(nan), None]),
    Series::from_strings("s", ["one", "nan", "null"]),
  ])
  let out = df.sort_by(SortSpec::asc("v").with_null_order(NullsFirst))
  assert_eq(out.check_invariants(), Ok(()))
  // NullsFirst groups NaN + Null at the start (stable: nan first,
  // then null).
  assert_eq(out.get(0, "s"), @types.Scalar::String("nan"))
  assert_eq(out.get(1, "s"), @types.Scalar::String("null"))
  assert_eq(out.get(2, "v"), @types.Scalar::Float(1.0))
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "sort_by rejects an unknown column with ColumnNotFound" {
  let df = sort_df()
  assert_eq(
    try? df.sort_by(SortSpec::asc("missing")),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The input frame stays well-formed (the validator runs before any
  // mutation could happen).
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "sort_by multi-key surfaces ColumnNotFound on the first offending spec" {
  let df = sort_df()
  // The first spec is fine; the second has the missing name.
  assert_eq(
    try? df.sort_by([SortSpec::asc("a"), SortSpec::asc("missing")]),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "sort_by exercises the build_sort_key dispatch on each dtype" {
  // The dispatch in `build_sort_key` cascades through the four typed
  // accessors. To cover every cascade step, sort once per dtype —
  // `Int` hits the first arm, `Float` the second, `Bool` the third,
  // and `String` the terminal arm.
  let df = DataFrame::new([
    Series::from_ints("i", [2, 1]),
    Series::from_floats("f", [(2.0 : Double), (1.0 : Double)]),
    Series::from_bools("b", [true, false]),
    Series::from_strings("s", ["y", "x"]),
  ])
  let by_int = df.sort_by(SortSpec::asc("i"))
  assert_eq(by_int.get(0, "i"), @types.Scalar::Int(1))
  let by_float = df.sort_by(SortSpec::asc("f"))
  assert_eq(by_float.get(0, "f"), @types.Scalar::Float(1.0))
  let by_bool = df.sort_by(SortSpec::asc("b"))
  assert_eq(by_bool.get(0, "b"), @types.Scalar::Bool(false))
  let by_string = df.sort_by(SortSpec::asc("s"))
  assert_eq(by_string.get(0, "s"), @types.Scalar::String("x"))
}

// ── IntoSortSpecs: single spec and one-element array agree ───────────

///|
test "sort_by(spec) == sort_by([spec]) for any spec" {
  let df = sort_df()
  let single = df.sort_by(SortSpec::desc("b"))
  let many = df.sort_by([SortSpec::desc("b")])
  assert_eq(single, many)
}

///|
test "sort_by is idempotent — sorting an already-sorted frame is a no-op" {
  let df = sort_df()
  let once = df.sort_by(SortSpec::asc("a"))
  let twice = once.sort_by(SortSpec::asc("a"))
  assert_eq(once, twice)
}

///|
test "sort_by gathers a nullable Bool column including its null cell" {
  // `sort_by` routes through `DataFrame::take` → `gather_series`, which
  // must copy a Bool column's *null* cell (not only its valid cells) when
  // that row is permuted. Sorting by `k` moves the `None` flag into the
  // lead row, exercising the null arm of the Bool gather.
  let df = DataFrame::new([
    Series::from_int_options("k", [Some(2), Some(1)]),
    Series::from_bool_options("flag", [Some(true), None]),
  ])
  let out = df.sort_by(SortSpec::asc("k"))
  // k ascends → row (k=1, flag=None) leads, (k=2, flag=true) follows.
  assert_eq(out.get(0, "flag"), @types.Scalar::Null)
  assert_eq(out.get(1, "flag"), @types.Scalar::Bool(true))
}
