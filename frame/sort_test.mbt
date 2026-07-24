// Blackbox tests for `DataFrame::sort`. Each key is an
// `(Expr, order, null_order)` tuple; a single-key sort passes a
// one-element array and a multi-key sort lists several. The bare
// `col(name)` keys here also pin the historical name-keyed sort
// behavior — the sort verb took plain String keys before v0.5, and a
// list of `col` references reproduces that name-keyed sort row-for-row.
// Computed keys (sorting by a value that never lands in the output) get
// their own section near the end.
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

// ── Order / null-placement semantics, exercised behaviorally ─────────

///|
test "sort ascending with NullsLast puts smaller values first, nulls last" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(2), None, Some(1), Some(3)]),
  ])
  let out = df.sort([(@expr.col("a"), Asc, NullsLast)])
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(3, "a"), @types.Scalar::Null)
}

///|
test "sort descending with NullsLast reverses the value order, nulls last" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(2), None, Some(1), Some(3)]),
  ])
  let out = df.sort([(@expr.col("a"), Desc, NullsLast)])
  assert_eq(out.item(0, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(3, "a"), @types.Scalar::Null)
}

///|
test "sort NullsFirst moves missing values to the head, either direction" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(2), None, Some(1)]),
  ])
  // asc + NullsFirst — value order still ascending, but null moves
  // to the head.
  let out_asc = df.sort([(@expr.col("a"), Asc, NullsFirst)])
  assert_eq(out_asc.item(0, "a"), @types.Scalar::Null)
  assert_eq(out_asc.item(1, "a"), @types.Scalar::Int(1))
  assert_eq(out_asc.item(2, "a"), @types.Scalar::Int(2))
  // desc + NullsFirst — value order descends but null still leads.
  let out_desc = df.sort([(@expr.col("a"), Desc, NullsFirst)])
  assert_eq(out_desc.item(0, "a"), @types.Scalar::Null)
  assert_eq(out_desc.item(1, "a"), @types.Scalar::Int(2))
  assert_eq(out_desc.item(2, "a"), @types.Scalar::Int(1))
}

// ── Fixture ──────────────────────────────────────────────────────────

///|
/// Five-row, four-column fixture covering Int / Float-with-null /
/// String / Bool so each sort key flavor has a dedicated column to
/// exercise. Row ordering inside `a` is intentionally non-monotonic to
/// make the ascending result observable.
fn sort_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
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
test "sort Int ascending reorders rows by the key" {
  let df = sort_df()
  let out = df.sort([(@expr.col("a"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.shape(), df.shape())
  // a sorted ascending: 1, 1, 3, 4, 5 — and the two 1s keep their
  // original relative order (stability) so the tiebreaker `s` reads
  // "apple" (row 1) then "date" (row 3).
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(3, "a"), @types.Scalar::Int(4))
  assert_eq(out.item(4, "a"), @types.Scalar::Int(5))
  // Stability witness via the secondary column `s`.
  assert_eq(out.item(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.item(1, "s"), @types.Scalar::String("date"))
}

///|
test "sort Int descending mirrors the ascending order" {
  let df = sort_df()
  let out = df.sort([(@expr.col("a"), Desc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // a sorted descending: 5, 4, 3, 1, 1. Stability still holds on
  // the two 1s (apple before date — original row order).
  assert_eq(out.item(0, "a"), @types.Scalar::Int(5))
  assert_eq(out.item(1, "a"), @types.Scalar::Int(4))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(3, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(4, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(3, "s"), @types.Scalar::String("apple"))
  assert_eq(out.item(4, "s"), @types.Scalar::String("date"))
}

// ── Single-key sort: Float with nulls ────────────────────────────────

///|
test "sort Float ascending places nulls last by default" {
  let df = sort_df()
  let out = df.sort([(@expr.col("b"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // b values: 2.5, Null, 1.5, 4.5, Null → asc/NullsLast = 1.5, 2.5,
  // 4.5, Null, Null.
  assert_eq(out.item(0, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.item(1, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.item(2, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.item(3, "b"), @types.Scalar::Null)
  assert_eq(out.item(4, "b"), @types.Scalar::Null)
  // Stability between the two nulls (original rows 1 and 4 → s =
  // "apple" then s = "berry").
  assert_eq(out.item(3, "s"), @types.Scalar::String("apple"))
  assert_eq(out.item(4, "s"), @types.Scalar::String("berry"))
}

///|
test "sort Float NullsFirst pushes missing values to the top" {
  let df = sort_df()
  let out = df.sort([(@expr.col("b"), Asc, NullsFirst)])
  assert_eq(out.check_invariants(), Ok(()))
  // asc/NullsFirst = Null, Null, 1.5, 2.5, 4.5.
  assert_eq(out.item(0, "b"), @types.Scalar::Null)
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
  assert_eq(out.item(2, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.item(3, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.item(4, "b"), @types.Scalar::Float(4.5))
  // Stability among the nulls preserves original order.
  assert_eq(out.item(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.item(1, "s"), @types.Scalar::String("berry"))
}

///|
test "sort Float with equal values preserves original order (stability)" {
  // The Float comparator's value-equal arm only fires when two
  // non-null, non-NaN floats compare equal. Two 1.0s in the fixture
  // exercise that arm; stability requires their original ordering to
  // survive (tag "b" before tag "c").
  let df = DataFrame::DataFrame([
    Series::from_floats("v", [3.0, 1.0, 1.0, 2.0]),
    Series::from_strings("tag", ["a", "b", "c", "d"]),
  ])
  let out = df.sort([(@expr.col("v"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "v"), @types.Scalar::Float(1.0))
  assert_eq(out.item(1, "v"), @types.Scalar::Float(1.0))
  assert_eq(out.item(0, "tag"), @types.Scalar::String("b"))
  assert_eq(out.item(1, "tag"), @types.Scalar::String("c"))
  assert_eq(out.item(2, "v"), @types.Scalar::Float(2.0))
  assert_eq(out.item(3, "v"), @types.Scalar::Float(3.0))
}

///|
test "sort Float descending NullsLast" {
  let df = sort_df()
  let out = df.sort([(@expr.col("b"), Desc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // desc/NullsLast = 4.5, 2.5, 1.5, Null, Null.
  assert_eq(out.item(0, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.item(1, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.item(2, "b"), @types.Scalar::Float(1.5))
  assert_eq(out.item(3, "b"), @types.Scalar::Null)
  assert_eq(out.item(4, "b"), @types.Scalar::Null)
}

///|
test "sort Float descending NullsFirst" {
  let df = sort_df()
  let out = df.sort([(@expr.col("b"), Desc, NullsFirst)])
  assert_eq(out.check_invariants(), Ok(()))
  // desc/NullsFirst = Null, Null, 4.5, 2.5, 1.5.
  assert_eq(out.item(0, "b"), @types.Scalar::Null)
  assert_eq(out.item(1, "b"), @types.Scalar::Null)
  assert_eq(out.item(2, "b"), @types.Scalar::Float(4.5))
  assert_eq(out.item(3, "b"), @types.Scalar::Float(2.5))
  assert_eq(out.item(4, "b"), @types.Scalar::Float(1.5))
}

// ── Single-key sort: String ──────────────────────────────────────────

///|
test "sort String ascending is lexicographic" {
  let df = sort_df()
  let out = df.sort([(@expr.col("s"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // "apple" < "berry" < "date" < "fig" < "pear".
  assert_eq(out.item(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.item(1, "s"), @types.Scalar::String("berry"))
  assert_eq(out.item(2, "s"), @types.Scalar::String("date"))
  assert_eq(out.item(3, "s"), @types.Scalar::String("fig"))
  assert_eq(out.item(4, "s"), @types.Scalar::String("pear"))
  // And `a` follows along: 1, 5, 1, 4, 3.
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(4, "a"), @types.Scalar::Int(3))
}

///|
test "sort String descending reverses the lexicographic order" {
  let df = sort_df()
  let out = df.sort([(@expr.col("s"), Desc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "s"), @types.Scalar::String("pear"))
  assert_eq(out.item(4, "s"), @types.Scalar::String("apple"))
}

///|
test "sort String breaks length ties lexicographically (shorter wins on prefix match)" {
  // The fixture is intentionally chosen so the merge sort exercises
  // both length-tiebreak branches of `compare_string_lex`:
  //   * "abc" vs "ab"  → equal on the first two chars, then la > lb
  //     → the longer string sorts after.
  //   * "ab"  vs "abc" → equal on the first two chars, then la < lb
  //     → the shorter string sorts before.
  // A naive sort that compared by length first (MoonBit's built-in
  // `<` on `String`) would put "ab" before "abd" *and* before "abc",
  // not catching the char-by-char difference between "abc" and "abd".
  let df = DataFrame::DataFrame([
    Series::from_strings("s", ["abd", "ab", "abc"]),
  ])
  let out = df.sort([(@expr.col("s"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "s"), @types.Scalar::String("ab"))
  assert_eq(out.item(1, "s"), @types.Scalar::String("abc"))
  assert_eq(out.item(2, "s"), @types.Scalar::String("abd"))
}

// ── Single-key sort: Bool ────────────────────────────────────────────

///|
test "sort Bool ascending puts false before true (stable)" {
  let df = sort_df()
  let out = df.sort([(@expr.col("t"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // t = [true, false, true, false, true].
  // asc: false, false, true, true, true. Stable: rows 1, 3, then
  // 0, 2, 4 (in their original relative order).
  assert_eq(out.item(0, "t"), @types.Scalar::Bool(false))
  assert_eq(out.item(1, "t"), @types.Scalar::Bool(false))
  assert_eq(out.item(2, "t"), @types.Scalar::Bool(true))
  assert_eq(out.item(3, "t"), @types.Scalar::Bool(true))
  assert_eq(out.item(4, "t"), @types.Scalar::Bool(true))
  assert_eq(out.item(0, "s"), @types.Scalar::String("apple"))
  assert_eq(out.item(1, "s"), @types.Scalar::String("date"))
  assert_eq(out.item(2, "s"), @types.Scalar::String("pear"))
  assert_eq(out.item(3, "s"), @types.Scalar::String("fig"))
  assert_eq(out.item(4, "s"), @types.Scalar::String("berry"))
}

// ── Multi-key sort ───────────────────────────────────────────────────

///|
test "sort multi-key: secondary key only matters for tied primaries" {
  // Two-column fixture: a has ties (X, X, Y, Y), b distinguishes.
  let df = DataFrame::DataFrame([
    Series::from_strings("a", ["X", "X", "Y", "Y"]),
    Series::from_ints("b", [2, 1, 2, 1]),
  ])
  let out = df.sort([
    (@expr.col("a"), Asc, NullsLast),
    (@expr.col("b"), Asc, NullsLast),
  ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "a"), @types.Scalar::String("X"))
  assert_eq(out.item(0, "b"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "a"), @types.Scalar::String("X"))
  assert_eq(out.item(1, "b"), @types.Scalar::Int(2))
  assert_eq(out.item(2, "a"), @types.Scalar::String("Y"))
  assert_eq(out.item(2, "b"), @types.Scalar::Int(1))
  assert_eq(out.item(3, "a"), @types.Scalar::String("Y"))
  assert_eq(out.item(3, "b"), @types.Scalar::Int(2))
}

///|
test "sort multi-key: primary asc + secondary desc" {
  let df = DataFrame::DataFrame([
    Series::from_strings("dept", ["eng", "eng", "ops", "ops", "ops"]),
    Series::from_ints("salary", [100, 200, 50, 150, 75]),
  ])
  let out = df.sort([
    (@expr.col("dept"), Asc, NullsLast),
    (@expr.col("salary"), Desc, NullsLast),
  ])
  assert_eq(out.check_invariants(), Ok(()))
  // Within eng (sorted asc), salaries desc: 200, 100.
  assert_eq(out.item(0, "dept"), @types.Scalar::String("eng"))
  assert_eq(out.item(0, "salary"), @types.Scalar::Int(200))
  assert_eq(out.item(1, "salary"), @types.Scalar::Int(100))
  // Within ops, salaries desc: 150, 75, 50.
  assert_eq(out.item(2, "dept"), @types.Scalar::String("ops"))
  assert_eq(out.item(2, "salary"), @types.Scalar::Int(150))
  assert_eq(out.item(3, "salary"), @types.Scalar::Int(75))
  assert_eq(out.item(4, "salary"), @types.Scalar::Int(50))
}

///|
test "sort multi-key: empty key set is an identity sort" {
  let df = sort_df()
  let out = df.sort(
    ([] : Array[(@expr.Expr, @types.SortOrder, @types.NullOrder)]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Stability turns "no keys, every comparison ties" into the
  // identity permutation.
  assert_eq(out, df)
}

// ── Stability stress: all keys equal ─────────────────────────────────

///|
test "sort on an all-equal column is the identity (stability)" {
  let df = DataFrame::DataFrame([
    Series::from_ints("k", [7, 7, 7, 7, 7]),
    Series::from_strings("tag", ["a", "b", "c", "d", "e"]),
  ])
  let out = df.sort([(@expr.col("k"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // Every row tied → original order preserved.
  assert_eq(out, df)
}

// ── Edge cases: empty / single-row / all-null ────────────────────────

///|
test "sort on a 0x0 frame returns the same 0x0 frame" {
  let df = DataFrame::DataFrame([])
  let out = df.sort(
    ([] : Array[(@expr.Expr, @types.SortOrder, @types.NullOrder)]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "sort on a 0-row frame preserves the schema and stays empty" {
  let schema = @types.Schema([
    @types.Field("a", @types.DataType::Int),
    @types.Field("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let out = df.sort([(@expr.col("a"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "sort on a single-row frame is the identity" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [42])])
  let out = df.sort([(@expr.col("a"), Desc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "sort on an all-null Int column is a stable identity" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [None, None, None]),
    Series::from_strings("s", ["x", "y", "z"]),
  ])
  let out = df.sort([(@expr.col("a"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // Every row is missing → null-vs-null is a tie → stability preserves
  // the original order regardless of NullsFirst / NullsLast.
  assert_eq(out, df)
  // Same outcome with NullsFirst.
  let out_first = df.sort([(@expr.col("a"), Asc, NullsFirst)])
  assert_eq(out_first, df)
}

// ── NaN handling: Float NaN is treated as null ───────────────────────

///|
test "sort Float treats NaN identically to Null (NullsLast)" {
  let nan = (0.0 : Double) / (0.0 : Double)
  let df = DataFrame::DataFrame([
    Series::from_float_options("v", [
      Some((1.0 : Double)),
      Some(nan),
      Some((2.0 : Double)),
      None,
    ]),
    Series::from_strings("s", ["one", "nan", "two", "null"]),
  ])
  let out = df.sort([(@expr.col("v"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // Reals first (1.0, 2.0) then NaN-and-Null bucket in original order
  // (nan came before null in the source).
  assert_eq(out.item(0, "v"), @types.Scalar::Float(1.0))
  assert_eq(out.item(0, "s"), @types.Scalar::String("one"))
  assert_eq(out.item(1, "v"), @types.Scalar::Float(2.0))
  assert_eq(out.item(1, "s"), @types.Scalar::String("two"))
  // Position 2: the NaN. Reading it back as Scalar yields a non-null
  // Float because the validity bit is still 1 — NaN is *valid* in
  // Arrow terms, the sort treats it as missing only for ordering.
  assert_eq(out.item(2, "s"), @types.Scalar::String("nan"))
  let v2 = out.item(2, "v")
  match v2 {
    @types.Scalar::Float(f) => assert_true(f.is_nan())
    _ => abort("unreachable: NaN slot should still read back as Scalar::Float")
  }
  // Position 3: the actual Null.
  assert_eq(out.item(3, "v"), @types.Scalar::Null)
  assert_eq(out.item(3, "s"), @types.Scalar::String("null"))
}

///|
test "sort Float NullsFirst groups NaN with Null at the top" {
  let nan = (0.0 : Double) / (0.0 : Double)
  let df = DataFrame::DataFrame([
    Series::from_float_options("v", [Some((1.0 : Double)), Some(nan), None]),
    Series::from_strings("s", ["one", "nan", "null"]),
  ])
  let out = df.sort([(@expr.col("v"), Asc, NullsFirst)])
  assert_eq(out.check_invariants(), Ok(()))
  // NullsFirst groups NaN + Null at the start (stable: nan first,
  // then null).
  assert_eq(out.item(0, "s"), @types.Scalar::String("nan"))
  assert_eq(out.item(1, "s"), @types.Scalar::String("null"))
  assert_eq(out.item(2, "v"), @types.Scalar::Float(1.0))
}

///|
test "sort multi-key: NaN in a secondary Float key orders like null within a tied group" {
  let nan = (0.0 : Double) / (0.0 : Double)
  // A single tied primary group (`g` all "A") so the secondary Float key `v`
  // decides every position: reals sort ascending, then the NaN/null bucket
  // (NullsLast) in source order — NaN must order exactly like null, even as a
  // tiebreaker key.
  let df = DataFrame::DataFrame([
    Series::from_strings("g", ["A", "A", "A", "A"]),
    Series::from_float_options("v", [
      Some(nan),
      Some((2.0 : Double)),
      None,
      Some((1.0 : Double)),
    ]),
    Series::from_strings("tag", ["nan", "two", "null", "one"]),
  ])
  let out = df.sort([
    (@expr.col("g"), Asc, NullsLast),
    (@expr.col("v"), Asc, NullsLast),
  ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "tag"), @types.Scalar::String("one")) // 1.0
  assert_eq(out.item(1, "tag"), @types.Scalar::String("two")) // 2.0
  assert_eq(out.item(2, "tag"), @types.Scalar::String("nan")) // NaN, source order
  assert_eq(out.item(3, "tag"), @types.Scalar::String("null")) // null, after NaN
}

// ── Computed keys: sort by a value that never lands in the output ─────

///|
test "sort by a derived key orders rows by the computed value" {
  // The key `a + b` is never materialised into the output — only the
  // permutation it induces is. Rows: (a=1,b=5)→6, (a=4,b=1)→5,
  // (a=2,b=2)→4, (a=3,b=0)→3. Ascending by the sum reverses the rows.
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 4, 2, 3]),
    Series::from_ints("b", [5, 1, 2, 0]),
    Series::from_strings("tag", ["six", "five", "four", "three"]),
  ])
  let out = df.sort([(@expr.col("a") + @expr.col("b"), Asc, NullsLast)])
  assert_eq(out.check_invariants(), Ok(()))
  // Schema is untouched — the `a + b` key produced no column.
  assert_eq(out.columns(), ["a", "b", "tag"])
  assert_eq(out.item(0, "tag"), @types.Scalar::String("three"))
  assert_eq(out.item(1, "tag"), @types.Scalar::String("four"))
  assert_eq(out.item(2, "tag"), @types.Scalar::String("five"))
  assert_eq(out.item(3, "tag"), @types.Scalar::String("six"))
}

///|
test "sort by a derived key descending and as a multi-key tiebreaker" {
  // Primary key `dept`, tiebreaker the negative of `salary` so the
  // higher earner sorts first within a department — a computed key
  // standing in for a `Desc` flag.
  let df = DataFrame::DataFrame([
    Series::from_strings("dept", ["ops", "eng", "ops", "eng"]),
    Series::from_ints("salary", [50, 100, 150, 200]),
  ])
  let out = df.sort([
    (@expr.col("dept"), Asc, NullsLast),
    (-@expr.col("salary"), Asc, NullsLast),
  ])
  assert_eq(out.check_invariants(), Ok(()))
  // eng first (200 then 100), ops next (150 then 50).
  assert_eq(out.item(0, "dept"), @types.Scalar::String("eng"))
  assert_eq(out.item(0, "salary"), @types.Scalar::Int(200))
  assert_eq(out.item(1, "salary"), @types.Scalar::Int(100))
  assert_eq(out.item(2, "dept"), @types.Scalar::String("ops"))
  assert_eq(out.item(2, "salary"), @types.Scalar::Int(150))
  assert_eq(out.item(3, "salary"), @types.Scalar::Int(50))
}

///|
test "sort by a length-1 key (literal / aggregation) is a stable no-op" {
  // A key that reduces to a single cell broadcasts over the frame, so
  // every row shares it: each comparison ties and stability preserves
  // the input order. A literal and an aggregation both reduce this way.
  let df = sort_df()
  let by_literal = df.sort([(@expr.lit_int(7), Asc, NullsLast)])
  assert_eq(by_literal, df)
  let by_agg = df.sort([(@expr.col("a").sum(), Desc, NullsLast)])
  assert_eq(by_agg, df)
  // The broadcast key only ties; an earlier real key still orders, and
  // the scalar tiebreaker leaves that order alone.
  let mixed = df.sort([
    (@expr.col("a"), Asc, NullsLast),
    (@expr.lit_int(0), Asc, NullsLast),
  ])
  assert_eq(mixed, df.sort([(@expr.col("a"), Asc, NullsLast)]))
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "sort rejects an unknown column with ColumnNotFound" {
  let df = sort_df()
  assert_eq(
    Ok(df.sort([(@expr.col("missing"), Asc, NullsLast)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The input frame stays well-formed (evaluation runs before any
  // mutation could happen).
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "sort multi-key surfaces ColumnNotFound on the first offending key" {
  let df = sort_df()
  // The first key is fine; the second has the missing name.
  assert_eq(
    Ok(
      df.sort([
        (@expr.col("a"), Asc, NullsLast),
        (@expr.col("missing"), Asc, NullsLast),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "sort surfaces a structured TypeMismatch from a non-unifiable derived key" {
  // `a + s` adds an Int and a String — the evaluator rejects it before
  // any sort happens, the same structured TypeMismatch the expression engine raises
  // anywhere else.
  let df = sort_df()
  assert_eq(
    Ok(df.sort([(@expr.col("a") + @expr.col("s"), Asc, NullsLast)])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "add",
          @types.DataType::Int,
          @types.DataType::String,
        ),
      ),
    ),
  )
}

///|
test "sort exercises the build_sort_key dispatch on each dtype" {
  // The dispatch in `build_sort_key` cascades through the four typed
  // accessors. To cover every cascade step, sort once per dtype —
  // `Int` hits the first arm, `Float` the second, `Bool` the third,
  // and `String` the terminal arm.
  let df = DataFrame::DataFrame([
    Series::from_ints("i", [2, 1]),
    Series::from_floats("f", [(2.0 : Double), (1.0 : Double)]),
    Series::from_bools("b", [true, false]),
    Series::from_strings("s", ["y", "x"]),
  ])
  let by_int = df.sort([(@expr.col("i"), Asc, NullsLast)])
  assert_eq(by_int.item(0, "i"), @types.Scalar::Int(1))
  let by_float = df.sort([(@expr.col("f"), Asc, NullsLast)])
  assert_eq(by_float.item(0, "f"), @types.Scalar::Float(1.0))
  let by_bool = df.sort([(@expr.col("b"), Asc, NullsLast)])
  assert_eq(by_bool.item(0, "b"), @types.Scalar::Bool(false))
  let by_string = df.sort([(@expr.col("s"), Asc, NullsLast)])
  assert_eq(by_string.item(0, "s"), @types.Scalar::String("x"))
}

///|
test "sort is idempotent — sorting an already-sorted frame is a no-op" {
  let df = sort_df()
  let once = df.sort([(@expr.col("a"), Asc, NullsLast)])
  let twice = once.sort([(@expr.col("a"), Asc, NullsLast)])
  assert_eq(once, twice)
}

///|
test "sort gathers a nullable Bool column including its null cell" {
  // `sort` routes through `DataFrame::gather` → `gather_series`, which
  // must copy a Bool column's *null* cell (not only its valid cells) when
  // that row is permuted. Sorting by `k` moves the `None` flag into the
  // lead row, exercising the null arm of the Bool gather.
  let df = DataFrame::DataFrame([
    Series::from_int_options("k", [Some(2), Some(1)]),
    Series::from_bool_options("flag", [Some(true), None]),
  ])
  let out = df.sort([(@expr.col("k"), Asc, NullsLast)])
  // k ascends → row (k=1, flag=None) leads, (k=2, flag=true) follows.
  assert_eq(out.item(0, "flag"), @types.Scalar::Null)
  assert_eq(out.item(1, "flag"), @types.Scalar::Bool(true))
}
