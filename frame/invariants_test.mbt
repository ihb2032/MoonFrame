// Grounding tests for the `check_invariants` specification:
// prove that every P5 constructor (`new`, `empty`, `from_rows`) and
// every P5 structural transform (`head`, `tail`, `slice`, `take`)
// yields a DataFrame that satisfies the invariants. If any of these
// regress, every downstream op test that relies on `check_invariants`
// would too — so this file is the canary.

// ── Constructors preserve invariants ─────────────────────────────────

///|
test "check_invariants holds for DataFrame::new with several columns" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
    Series::from_float_options("c", [Some(1.5), None, Some(2.5)]),
  ])
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "check_invariants holds for the zero-column frame" {
  let df = DataFrame::new([])
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "check_invariants holds for empty(schema) with every dtype" {
  let schema = @types.Schema::new([
    @types.Field("i", @types.DataType::Int),
    @types.Field("f", @types.DataType::Float),
    @types.Field("b", @types.DataType::Bool),
    @types.Field("s", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "check_invariants holds for from_rows with nulls" {
  let schema = @types.Schema::new([
    @types.Field("i", @types.DataType::Int),
    @types.Field("s", @types.DataType::String),
  ])
  let df = DataFrame::from_rows(schema, [
    [@types.Scalar::Int(1), @types.Scalar::String("a")],
    [@types.Scalar::Null, @types.Scalar::Null],
  ])
  assert_eq(df.check_invariants(), Ok(()))
}

// ── Structural transforms preserve invariants ────────────────────────

///|
test "check_invariants holds after head / tail / slice / take" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  assert_eq(df.head(2).check_invariants(), Ok(()))
  assert_eq(df.tail(2).check_invariants(), Ok(()))
  assert_eq(df.slice(1, 3).check_invariants(), Ok(()))
  assert_eq(df.take([3, 0, 0]).check_invariants(), Ok(()))
  // Clamping edges still produce well-formed frames.
  assert_eq(df.head(0).check_invariants(), Ok(()))
  assert_eq(df.head(100).check_invariants(), Ok(()))
  assert_eq(df.tail(-1).check_invariants(), Ok(()))
  assert_eq(df.slice(2, 2).check_invariants(), Ok(()))
  assert_eq(df.take([]).check_invariants(), Ok(()))
}

// ── Error-message shape sanity ───────────────────────────────────────
// Inducing an invariant violation requires building a malformed
// `DataFrame` directly, which only same-package code can do — see
// `invariants_wbtest.mbt`, whose white-box tests construct illegal
// frames via struct literals and assert each INV1–INV7 error branch.
// The black-box tests here instead confirm the happy path stays `Ok(())`.
