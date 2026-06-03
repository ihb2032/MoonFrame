// Blackbox tests for `DataFrame::join` / `inner_join` / `left_join`.
//
// Invariants asserted across the happy-path tests:
//   (1) check_invariants() == Ok(()) — every join result routes through
//       DataFrame::new, so it must satisfy the structural spec.
//   (2) output column order = left columns (original) then right non-key
//       columns (original), key columns appearing once from the left; a
//       right non-key column colliding with a left name gains the suffix.
//   (3) row order = left rows in order; within a left row, right matches
//       in ascending right-row order. Unmatched left rows (Left join) come
//       in their left position with null right columns.

// ── Fixtures ─────────────────────────────────────────────────────────

///|
/// Employees with a foreign key `dept_id`. Row 3 (Dave) points at dept 99,
/// which has no matching department — the unmatched-left case.
fn employees() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("emp_id", [1, 2, 3, 4]),
    Series::from_strings("name", ["Alice", "Bob", "Carol", "Dave"]),
    Series::from_ints("dept_id", [10, 20, 10, 99]),
  ])
}

///|
/// Departments keyed by `dept_id`. Dept 30 (HR) has no employee — the
/// unmatched-right case (always dropped by inner / left).
fn departments() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("dept_id", [10, 20, 30]),
    Series::from_strings("dept_name", ["Eng", "Sales", "HR"]),
  ])
}

// ── Inner join, single key ───────────────────────────────────────────

///|
test "inner join keeps only matched rows, in left order" {
  let out = employees().join(departments(), JoinOptions::on(["dept_id"]))
  assert_eq(out.check_invariants(), Ok(()))
  // Key column appears once (from the left), right non-key column appended.
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  // Dave (dept 99) drops; HR (dept 30) never appears. Left order preserved.
  assert_eq(out.shape(), (3, 4))
  assert_eq(out.get(0, "name"), @types.Scalar::String("Alice"))
  assert_eq(out.get(0, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.get(1, "name"), @types.Scalar::String("Bob"))
  assert_eq(out.get(1, "dept_name"), @types.Scalar::String("Sales"))
  assert_eq(out.get(2, "name"), @types.Scalar::String("Carol"))
  assert_eq(out.get(2, "dept_name"), @types.Scalar::String("Eng"))
  // The key column keeps the left dtype.
  assert_eq(out.get_column("dept_id").dtype(), @types.DataType::Int)
}

///|
test "inner_join convenience equals join with default options" {
  let viamethod = employees().inner_join(departments(), ["dept_id"])
  let viaoptions = employees().join(departments(), JoinOptions::on(["dept_id"]))
  assert_eq(viamethod, viaoptions)
}

// ── Left join, single key ────────────────────────────────────────────

///|
test "left join keeps every left row, nulling unmatched right columns" {
  let out = employees().left_join(departments(), ["dept_id"])
  assert_eq(out.check_invariants(), Ok(()))
  // A left join does NOT coalesce by default (Polars), so the right key is
  // kept as `dept_id_right` (null where the left row had no match), letting
  // matched and unmatched rows be told apart.
  assert_eq(out.columns(), [
    "emp_id", "name", "dept_id", "dept_id_right", "dept_name",
  ])
  // All four employees survive; Dave (dept 99) has no match.
  assert_eq(out.shape(), (4, 5))
  assert_eq(out.get(0, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.get(1, "dept_name"), @types.Scalar::String("Sales"))
  assert_eq(out.get(2, "dept_name"), @types.Scalar::String("Eng"))
  // Matched rows carry the right key; Dave's right key + dept_name are null.
  assert_eq(out.get(0, "dept_id_right"), @types.Scalar::Int(10))
  assert_eq(out.get(3, "name"), @types.Scalar::String("Dave"))
  assert_eq(out.get(3, "dept_id"), @types.Scalar::Int(99)) // left key kept
  assert_eq(out.get(3, "dept_id_right"), @types.Scalar::Null) // no match
  assert_eq(out.get(3, "dept_name"), @types.Scalar::Null)
  // The nulled right column keeps its source dtype.
  assert_eq(out.get_column("dept_name").dtype(), @types.DataType::String)
}

///|
test "left join with coalesce=true merges the key into one column" {
  // Opting back into coalescing reproduces the inner-join key layout: the
  // key appears once (the left's value, always present on a left row).
  let out = employees().join(
    departments(),
    JoinOptions::on(["dept_id"]).with_how(JoinType::Left).with_coalesce(true),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  assert_eq(out.shape(), (4, 4))
  assert_eq(out.get(3, "dept_id"), @types.Scalar::Int(99))
  assert_eq(out.get(3, "dept_name"), @types.Scalar::Null)
}

///|
test "left_join convenience equals join with how = Left" {
  let viamethod = employees().left_join(departments(), ["dept_id"])
  let viaoptions = employees().join(
    departments(),
    JoinOptions::on(["dept_id"]).with_how(JoinType::Left),
  )
  assert_eq(viamethod, viaoptions)
}

///|
test "inner join with coalesce=false keeps both key columns" {
  // The opt-out direction: force a non-coalescing inner join, so the right
  // key is kept (suffixed). Every row matched, so the two key columns hold
  // equal values.
  let out = employees().join(
    departments(),
    JoinOptions::on(["dept_id"]).with_coalesce(false),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), [
    "emp_id", "name", "dept_id", "dept_id_right", "dept_name",
  ])
  assert_eq(out.shape(), (3, 5))
  assert_eq(out.get(0, "dept_id"), @types.Scalar::Int(10))
  assert_eq(out.get(0, "dept_id_right"), @types.Scalar::Int(10))
}

// ── One-to-many + row-order determinism ──────────────────────────────

///|
test "a left row matching several right rows fans out in right-row order" {
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", [1, 1, 2]),
    Series::from_ints("rv", [10, 20, 30]),
  ])
  let out = left.inner_join(right, ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "rv"])
  // k=1 fans out to rv 10 then rv 20 (ascending right-row order), then k=2.
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.get(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.get(0, "rv"), @types.Scalar::Int(10))
  assert_eq(out.get(1, "lv"), @types.Scalar::String("a"))
  assert_eq(out.get(1, "rv"), @types.Scalar::Int(20))
  assert_eq(out.get(2, "lv"), @types.Scalar::String("b"))
  assert_eq(out.get(2, "rv"), @types.Scalar::Int(30))
}

// ── Multi key ────────────────────────────────────────────────────────

///|
test "multi-key join matches on the key tuple" {
  let left = DataFrame::new([
    Series::from_strings("a", ["x", "x", "y"]),
    Series::from_ints("b", [1, 2, 1]),
    Series::from_strings("lv", ["p", "q", "r"]),
  ])
  let right = DataFrame::new([
    Series::from_strings("a", ["x", "y", "x"]),
    Series::from_ints("b", [1, 1, 2]),
    Series::from_ints("rv", [100, 200, 300]),
  ])
  let out = left.inner_join(right, ["a", "b"])
  assert_eq(out.check_invariants(), Ok(()))
  // Both key columns appear once, in left order, then the right non-key.
  assert_eq(out.columns(), ["a", "b", "lv", "rv"])
  assert_eq(out.shape(), (3, 4))
  // (x,1)->100, (x,2)->300, (y,1)->200; left order preserved.
  assert_eq(out.get(0, "lv"), @types.Scalar::String("p"))
  assert_eq(out.get(0, "rv"), @types.Scalar::Int(100))
  assert_eq(out.get(1, "lv"), @types.Scalar::String("q"))
  assert_eq(out.get(1, "rv"), @types.Scalar::Int(300))
  assert_eq(out.get(2, "lv"), @types.Scalar::String("r"))
  assert_eq(out.get(2, "rv"), @types.Scalar::Int(200))
}

///|
test "multi-key composite is injective across field boundaries" {
  // ("a","bc") vs ("ab","c"): naive concatenation would collide and join
  // them spuriously; the length-prefixed composite keeps them apart.
  let left = DataFrame::new([
    Series::from_strings("k1", ["a", "ab"]),
    Series::from_strings("k2", ["bc", "c"]),
    Series::from_ints("lv", [1, 2]),
  ])
  let right = DataFrame::new([
    Series::from_strings("k1", ["a"]),
    Series::from_strings("k2", ["bc"]),
    Series::from_ints("rv", [9]),
  ])
  let out = left.inner_join(right, ["k1", "k2"])
  assert_eq(out.check_invariants(), Ok(()))
  // Only ("a","bc") matches; ("ab","c") must NOT.
  assert_eq(out.shape(), (1, 4))
  assert_eq(out.get(0, "lv"), @types.Scalar::Int(1))
  assert_eq(out.get(0, "rv"), @types.Scalar::Int(9))
}

// ── Suffix on colliding right column ─────────────────────────────────

///|
test "a right non-key column colliding with a left name gets the suffix" {
  let left = DataFrame::new([
    Series::from_ints("id", [1, 2]),
    Series::from_ints("value", [100, 200]),
  ])
  let right = DataFrame::new([
    Series::from_ints("id", [1, 2]),
    Series::from_ints("value", [9, 8]),
  ])
  let out = left.inner_join(right, ["id"])
  assert_eq(out.check_invariants(), Ok(()))
  // Left "value" keeps its name; right "value" becomes "value_right".
  assert_eq(out.columns(), ["id", "value", "value_right"])
  assert_eq(out.get(0, "value"), @types.Scalar::Int(100))
  assert_eq(out.get(0, "value_right"), @types.Scalar::Int(9))
  assert_eq(out.get(1, "value"), @types.Scalar::Int(200))
  assert_eq(out.get(1, "value_right"), @types.Scalar::Int(8))
}

///|
test "with_suffix customises the collision suffix" {
  let left = DataFrame::new([
    Series::from_ints("id", [1]),
    Series::from_ints("value", [100]),
  ])
  let right = DataFrame::new([
    Series::from_ints("id", [1]),
    Series::from_ints("value", [9]),
  ])
  let out = left.join(right, JoinOptions::on(["id"]).with_suffix("_r"))
  assert_eq(out.columns(), ["id", "value", "value_r"])
}

///|
test "a suffix that still collides surfaces as DuplicateColumn" {
  // Left already has both "value" and "value_right"; suffixing the right
  // "value" to "value_right" collides again, caught by DataFrame::new.
  let left = DataFrame::new([
    Series::from_ints("id", [1]),
    Series::from_ints("value", [100]),
    Series::from_ints("value_right", [7]),
  ])
  let right = DataFrame::new([
    Series::from_ints("id", [1]),
    Series::from_ints("value", [9]),
  ])
  assert_eq(
    try? left.inner_join(right, ["id"]),
    Err(@types.DataError::DuplicateColumn("value_right")),
  )
}

// ── Null keys: null matches nothing ──────────────────────────────────

///|
/// Both frames carry a null key cell. Unlike `group_by`, a null key
/// matches nothing — so the null rows never pair up, even with each other.
fn left_nullable() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("k", [Some(1), None, Some(2)]),
    Series::from_strings("lv", ["a", "b", "c"]),
  ])
}

///|
fn right_nullable() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_int_options("k", [Some(1), None, Some(2)]),
    Series::from_strings("rv", ["x", "y", "z"]),
  ])
}

///|
test "inner join drops rows with a null key on either side" {
  let out = left_nullable().inner_join(right_nullable(), ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  // Only k=1 and k=2 match; the two null-keyed rows are dropped.
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.get(0, "rv"), @types.Scalar::String("x"))
  assert_eq(out.get(1, "lv"), @types.Scalar::String("c"))
  assert_eq(out.get(1, "rv"), @types.Scalar::String("z"))
}

///|
test "left join keeps a null-keyed left row with null right columns" {
  let out = left_nullable().left_join(right_nullable(), ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  // Left join keeps the right key (k_right); all three left rows survive.
  assert_eq(out.columns(), ["k", "lv", "k_right", "rv"])
  // The null-keyed left row (row 1) gets null k_right + rv even though the
  // right frame also has a null-keyed row (null != null).
  assert_eq(out.shape(), (3, 4))
  assert_eq(out.get(0, "k_right"), @types.Scalar::Int(1))
  assert_eq(out.get(0, "rv"), @types.Scalar::String("x"))
  assert_eq(out.get(1, "k"), @types.Scalar::Null) // left key, was null
  assert_eq(out.get(1, "lv"), @types.Scalar::String("b"))
  assert_eq(out.get(1, "k_right"), @types.Scalar::Null) // no match
  assert_eq(out.get(1, "rv"), @types.Scalar::Null)
  assert_eq(out.get(2, "k_right"), @types.Scalar::Int(2))
  assert_eq(out.get(2, "rv"), @types.Scalar::String("z"))
}

// ── Float NaN keys match (consistency with group_by) ─────────────────

///|
test "Float NaN keys match each other (group_by-consistent, not pandas)" {
  let nan : Double = @double.not_a_number
  let left = DataFrame::new([
    Series::from_floats("k", [nan, 1.0]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_floats("k", [nan, 1.0]),
    Series::from_ints("rv", [100, 200]),
  ])
  let out = left.inner_join(right, ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  // NaN (row 0) matches the right NaN; 1.0 matches 1.0. Two rows, in left
  // order. (NaN cells aren't asserted by value — NaN != NaN under Eq.)
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.get(0, "rv"), @types.Scalar::Int(100))
  assert_eq(out.get(1, "lv"), @types.Scalar::String("b"))
  assert_eq(out.get(1, "rv"), @types.Scalar::Int(200))
}

// ── Cross join (how = Cross) ─────────────────────────────────────────

///|
test "cross_join produces the Cartesian product" {
  let left = DataFrame::new([Series::from_strings("lv", ["a", "b"])])
  let right = DataFrame::new([Series::from_ints("rv", [10, 20, 30])])
  let out = left.cross_join(right)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["lv", "rv"])
  // 2 x 3 = 6 rows: each left row paired with every right row, in order.
  assert_eq(out.shape(), (6, 2))
  assert_eq(out.get(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.get(0, "rv"), @types.Scalar::Int(10))
  assert_eq(out.get(2, "rv"), @types.Scalar::Int(30))
  assert_eq(out.get(3, "lv"), @types.Scalar::String("b"))
  assert_eq(out.get(3, "rv"), @types.Scalar::Int(10))
  assert_eq(out.get(5, "rv"), @types.Scalar::Int(30))
  // The convenience method equals the explicit options form.
  assert_eq(out, left.join(right, JoinOptions::cross()))
}

///|
test "cross join suffixes a right column clashing with a left name" {
  // No keys, so a shared column name is resolved purely by the suffix.
  let left = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([Series::from_ints("x", [10, 20])])
  let out = left.join(right, JoinOptions::cross().with_suffix("_r"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["x", "lv", "x_r"])
  assert_eq(out.shape(), (4, 3))
  assert_eq(out.get(0, "x"), @types.Scalar::Int(1))
  assert_eq(out.get(0, "x_r"), @types.Scalar::Int(10))
}

///|
test "cross join with an empty operand is empty" {
  let left = DataFrame::new([Series::from_ints("lv", [1, 2])])
  let right = DataFrame::new([Series::from_ints("rv", [])])
  // n x 0 = 0 rows, schema preserved.
  assert_eq(left.cross_join(right).shape(), (0, 2))
  assert_eq(right.cross_join(left).shape(), (0, 2))
}

///|
test "cross join rejects key columns" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [2])])
  // Passing keys to a cross join is a usage error (Polars rejects it too).
  assert_true(
    (try? left.join(right, JoinOptions::on(["k"]).with_how(JoinType::Cross)))
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a non-cross join with an empty key list is rejected" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [2])])
  // Empty `on` no longer silently cross-joins — it must be `how = Cross`.
  assert_true(
    (try? left.inner_join(right, []))
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (try? left.join(right, JoinOptions::on([]).with_how(JoinType::Left)))
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

// ── Empty / degenerate frames ────────────────────────────────────────

///|
test "inner join with a 0-row left frame yields 0 rows, full schema" {
  let left = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_strings("lv", []),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", [1]),
    Series::from_strings("rv", ["x"]),
  ])
  let out = left.inner_join(right, ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 3))
  assert_eq(out.columns(), ["k", "lv", "rv"])
}

///|
test "inner join with a 0-row right frame matches nothing" {
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_strings("rv", []),
  ])
  let out = left.inner_join(right, ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 3))
}

///|
test "left join with a 0-row right frame keeps all left rows, null right" {
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_strings("rv", []),
  ])
  let out = left.left_join(right, ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  // Nothing matches, so the kept right key (k_right) and rv are all null.
  assert_eq(out.columns(), ["k", "lv", "k_right", "rv"])
  assert_eq(out.shape(), (2, 4))
  assert_eq(out.get(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.get(0, "k_right"), @types.Scalar::Null)
  assert_eq(out.get(0, "rv"), @types.Scalar::Null)
  assert_eq(out.get(1, "rv"), @types.Scalar::Null)
  // The all-null gathered right columns still carry their source dtype.
  assert_eq(out.get_column("k_right").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("rv").dtype(), @types.DataType::String)
}

///|
test "join of two 0-row frames is empty with the joined schema" {
  let left = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_strings("lv", []),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_ints("rv", []),
  ])
  // Inner coalesces the key (3 cols); left keeps the right key too (4 cols).
  assert_eq(left.inner_join(right, ["k"]).shape(), (0, 3))
  assert_eq(left.left_join(right, ["k"]).shape(), (0, 4))
}

// ── Right non-key columns of every dtype ─────────────────────────────

///|
/// Int / Float / Bool right non-key columns (String is exercised by the
/// null-key and empty-right fixtures), each with a null source cell. The
/// inner join covers the matched-valid (k=1) and matched-but-null-source
/// (k=2) gather paths; the left join adds the unmatched-`None` path (k=3)
/// for all three dtypes.
test "join gathers Int / Float / Bool right columns: valid, null, unmatched" {
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2, 3]),
    Series::from_strings("lv", ["a", "b", "c"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_int_options("ri", [Some(7), None]),
    Series::from_float_options("rf", [Some(1.5), None]),
    Series::from_bool_options("rb", [Some(true), None]),
  ])
  let inner = left.inner_join(right, ["k"])
  assert_eq(inner.check_invariants(), Ok(()))
  assert_eq(inner.columns(), ["k", "lv", "ri", "rf", "rb"])
  assert_eq(inner.shape(), (2, 5))
  assert_eq(inner.get(0, "ri"), @types.Scalar::Int(7))
  assert_eq(inner.get(0, "rf"), @types.Scalar::Float(1.5))
  assert_eq(inner.get(0, "rb"), @types.Scalar::Bool(true))
  // k=2 matched, but the right cells are null at the source.
  assert_eq(inner.get(1, "ri"), @types.Scalar::Null)
  assert_eq(inner.get(1, "rf"), @types.Scalar::Null)
  assert_eq(inner.get(1, "rb"), @types.Scalar::Null)
  assert_eq(inner.get_column("ri").dtype(), @types.DataType::Int)
  assert_eq(inner.get_column("rf").dtype(), @types.DataType::Float)
  assert_eq(inner.get_column("rb").dtype(), @types.DataType::Bool)
  // Left join: k=3 is unmatched, so k_right/ri/rf/rb are null via the None
  // branch. The kept right key adds a column, hence 6 not 5.
  let out = left.left_join(right, ["k"])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "k_right", "ri", "rf", "rb"])
  assert_eq(out.shape(), (3, 6))
  assert_eq(out.get(2, "lv"), @types.Scalar::String("c"))
  assert_eq(out.get(2, "k_right"), @types.Scalar::Null)
  assert_eq(out.get(2, "ri"), @types.Scalar::Null)
  assert_eq(out.get(2, "rf"), @types.Scalar::Null)
  assert_eq(out.get(2, "rb"), @types.Scalar::Null)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "join raises ColumnNotFound for a key missing on the left" {
  assert_eq(
    try? employees().inner_join(departments(), ["nope"]),
    Err(@types.DataError::ColumnNotFound("nope")),
  )
}

///|
test "join raises ColumnNotFound for a key present left but missing right" {
  // "name" exists in employees but not in departments — the right check
  // fires for it.
  assert_eq(
    try? employees().inner_join(departments(), ["name"]),
    Err(@types.DataError::ColumnNotFound("name")),
  )
}

///|
test "join raises TypeMismatch when a key's dtype differs across frames" {
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  // Right "k" is a String column, so its values could never compare equal
  // to the left Int "k".
  let right = DataFrame::new([
    Series::from_strings("k", ["1", "2"]),
    Series::from_ints("rv", [10, 20]),
  ])
  assert_true(
    (try? left.inner_join(right, ["k"]))
    is Err(@types.DataError::TypeMismatch(_)),
  )
}
