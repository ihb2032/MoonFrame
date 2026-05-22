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
    schema: @types.Schema::new([
      @types.Field::new("a", @types.DataType::Int),
      @types.Field::new("b", @types.DataType::Int),
    ]).unwrap(),
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
    schema: @types.Schema::new([@types.Field::new("a", @types.DataType::Int)]).unwrap(),
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
    schema: @types.Schema::new([
      @types.Field::new("renamed", @types.DataType::Int),
    ]).unwrap(),
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
    schema: @types.Schema::new([@types.Field::new("a", @types.DataType::Float)]).unwrap(),
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
    schema: @types.Schema::new([
      @types.Field::new("a", @types.DataType::Int),
      @types.Field::new("b", @types.DataType::Int),
    ]).unwrap(),
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
    schema: @types.Schema::new([@types.Field::new("a", @types.DataType::Int)]).unwrap(),
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
    schema: @types.Schema::new([@types.Field::new("a", @types.DataType::Int)]).unwrap(),
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
    schema: @types.Schema::new([
      @types.Field::new("a", @types.DataType::Int),
      @types.Field::new("b", @types.DataType::Int),
    ]).unwrap(),
    columns: [Series::from_ints("a", [1]), Series::from_ints("b", [2])],
    nrows: 1,
    // "a" → 1 is wrong; columns[1].name() == "b".
    name_to_index: { "a": 1, "b": 0 },
  }
  assert_true(bad.check_invariants() is Err(msg) && msg.has_prefix("INV6"))
}
