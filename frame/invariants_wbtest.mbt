// Whitebox tests for `check_invariants`. We deliberately build
// ill-formed `DataFrame` literals by reaching past the public
// constructors so each error branch in the spec is exercised. Public
// API alone can never reach these branches — that's the whole point
// of the spec — so this file is the only home for them.

// ── INV1: schema-columns arity mismatch ─────────────────────────────

///|
test "check_invariants reports INV1 when schema and columns lengths disagree" {
  let bad : DataFrame = {
    // Schema says two columns, columns vector has one.
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1, 2, 3])],
    nrows: 3,
    name_to_index: { "a": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV1"))
}

// ── INV2: column length != nrows ────────────────────────────────────

///|
test "check_invariants reports INV2 when a column's length disagrees with nrows" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1, 2, 3])],
    nrows: 99, // deliberate mismatch
    name_to_index: { "a": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV2"))
}

// ── INV3: schema field name != column name ──────────────────────────

///|
test "check_invariants reports INV3 when schema field name does not match column name" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("renamed", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("original", [1, 2, 3])],
    nrows: 3,
    name_to_index: { "renamed": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV3"))
}

// ── INV4: schema field dtype != column dtype ────────────────────────

///|
test "check_invariants reports INV4 when schema dtype does not match column dtype" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Float),
    ]),
    columns: [Series::from_ints("a", [1, 2, 3])], // dtype Int, not Float
    nrows: 3,
    name_to_index: { "a": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV4"))
}

// ── INV5: name_to_index size mismatch ───────────────────────────────

///|
test "check_invariants reports INV5 when name_to_index size disagrees with columns" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1]), Series::from_ints("b", [2])],
    nrows: 1,
    // Missing the "b" entry — size is 1 but ncols is 2.
    name_to_index: { "a": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV5"))
}

// ── INV6 (a): cache entry index out of range ────────────────────────

///|
test "check_invariants reports INV6 when a cache entry points out of range" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1])],
    nrows: 1,
    // Index 7 is out of [0, 1).
    name_to_index: { "a": 7 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV6"))
}

///|
test "check_invariants reports INV6 when a cache entry points to a negative index" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1])],
    nrows: 1,
    name_to_index: { "a": -3 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV6"))
}

// ── INV6 (b): cache name does not match target column name ──────────

///|
test "check_invariants reports INV6 when a cache key does not match its target column" {
  let bad : DataFrame = {
    schema: @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::Int),
    ]),
    columns: [Series::from_ints("a", [1]), Series::from_ints("b", [2])],
    nrows: 1,
    // "a" → 1 is wrong; columns[1].name() == "b".
    name_to_index: { "a": 1, "b": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV6"))
}

// ── INV7: a negative row count ──────────────────────────────────────

///|
test "check_invariants reports INV7 when nrows is negative" {
  let bad : DataFrame = {
    // With no columns, INV2 is vacuous and `nrows` alone carries the height —
    // so a negative count is caught here and nowhere else.
    schema: @types.Schema::Schema([]),
    columns: [],
    nrows: -1,
    name_to_index: Map([]),
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV7"))
}

///|
test "check_invariants accepts a column-less frame that carries rows" {
  // The shape INV7 used to reject: `N×0` is what a projection to zero
  // columns leaves behind, and it is well-formed.
  let empty_rows : DataFrame = {
    schema: @types.Schema::Schema([]),
    columns: [],
    nrows: 3,
    name_to_index: Map([]),
  }
  assert_true(empty_rows.check_invariants() is Ok(_))
  assert_eq(empty_rows.shape(), (3, 0))
}
