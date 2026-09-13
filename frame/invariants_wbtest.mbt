// Whitebox tests for `check_invariants`. We deliberately build
// ill-formed `DataFrame` literals by reaching past the public
// constructors so each error branch in the spec is exercised. Public
// API alone can never reach these branches — that's the whole point
// of the spec — so this file is the only home for them.

// ── INV1: schema-columns arity mismatch ─────────────────────────────

///|
test "check_invariants reports INV1 when schema and columns lengths disagree" {
  let bad = DataFrame::{
    // Schema says two columns, columns vector has one.
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1, 2, 3])],
    nrows: 3,
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV1"))
}

// ── INV2: column length != nrows ────────────────────────────────────

///|
test "check_invariants reports INV2 when a column's length disagrees with nrows" {
  let bad = DataFrame::{
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1, 2, 3])],
    nrows: 99, // deliberate mismatch
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV2"))
}

// ── INV3: schema field name != column name ──────────────────────────

///|
test "check_invariants reports INV3 when schema field name does not match column name" {
  let bad = DataFrame::{
    schema: @types.Schema::Schema([
      @types.Field::Field("renamed", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("original", [1, 2, 3])],
    nrows: 3,
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV3"))
}

// ── INV4: schema field dtype != column dtype ────────────────────────

///|
test "check_invariants reports INV4 when schema dtype does not match column dtype" {
  let bad = DataFrame::{
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Float),
    ]),
    columns: [Series::from_ints("a", [1, 2, 3])], // dtype Int, not Float
    nrows: 3,
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV4"))
}

// ── INV5: a negative row count ──────────────────────────────────────

///|
test "check_invariants reports INV5 when nrows is negative" {
  let bad = DataFrame::{
    // With no columns, INV2 is vacuous and `nrows` alone carries the height —
    // so a negative count is caught here and nowhere else.
    schema: @types.Schema::Schema([]),
    columns: [],
    nrows: -1,
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV5"))
}

///|
test "check_invariants accepts a column-less frame that carries rows" {
  // The shape INV5 used to reject: `N×0` is what a projection to zero
  // columns leaves behind, and it is well-formed.
  let empty_rows = DataFrame::{
    schema: @types.Schema::Schema([]),
    columns: [],
    nrows: 3,
  }
  assert_true(empty_rows.check_invariants() is Ok(_))
  assert_eq(empty_rows.shape(), (3, 0))
}
