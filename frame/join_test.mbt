// Blackbox tests for `DataFrame::join`.
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
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Key column appears once (from the left), right non-key column appended.
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  // Dave (dept 99) drops; HR (dept 30) never appears. Left order preserved.
  assert_eq(out.shape(), (3, 4))
  assert_eq(out.item(0, "name"), @types.Scalar::String("Alice"))
  assert_eq(out.item(0, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.item(1, "name"), @types.Scalar::String("Bob"))
  assert_eq(out.item(1, "dept_name"), @types.Scalar::String("Sales"))
  assert_eq(out.item(2, "name"), @types.Scalar::String("Carol"))
  assert_eq(out.item(2, "dept_name"), @types.Scalar::String("Eng"))
  // The key column keeps the left dtype.
  assert_eq(out.get_column("dept_id").dtype(), @types.DataType::Int)
}

// ── Left join, single key ────────────────────────────────────────────

///|
test "left join keeps every left row, nulling unmatched right columns" {
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")]).with_how(JoinType::Left),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // A left join coalesces the key by default (Polars): `dept_id` appears once,
  // carrying the left value (always present on a left row).
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  // All four employees survive; Dave (dept 99) has no match.
  assert_eq(out.shape(), (4, 4))
  assert_eq(out.item(0, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.item(1, "dept_name"), @types.Scalar::String("Sales"))
  assert_eq(out.item(2, "dept_name"), @types.Scalar::String("Eng"))
  // The coalesced key holds the match value; Dave keeps his left key, with a
  // null dept_name.
  assert_eq(out.item(0, "dept_id"), @types.Scalar::Int(10))
  assert_eq(out.item(3, "name"), @types.Scalar::String("Dave"))
  assert_eq(out.item(3, "dept_id"), @types.Scalar::Int(99)) // left key kept
  assert_eq(out.item(3, "dept_name"), @types.Scalar::Null)
  // The nulled right column keeps its source dtype.
  assert_eq(out.get_column("dept_name").dtype(), @types.DataType::String)
}

///|
test "left join with coalesce=true merges the key into one column" {
  // Opting back into coalescing reproduces the inner-join key layout: the
  // key appears once (the left's value, always present on a left row).
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")])
    .with_how(JoinType::Left)
    .with_coalesce(true),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  assert_eq(out.shape(), (4, 4))
  assert_eq(out.item(3, "dept_id"), @types.Scalar::Int(99))
  assert_eq(out.item(3, "dept_name"), @types.Scalar::Null)
}

///|
test "inner join with coalesce=false keeps both key columns" {
  // The opt-out direction: force a non-coalescing inner join, so the right
  // key is kept (suffixed). Every row matched, so the two key columns hold
  // equal values.
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")]).with_coalesce(false),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), [
    "emp_id", "name", "dept_id", "dept_id_right", "dept_name",
  ])
  assert_eq(out.shape(), (3, 5))
  assert_eq(out.item(0, "dept_id"), @types.Scalar::Int(10))
  assert_eq(out.item(0, "dept_id_right"), @types.Scalar::Int(10))
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
  let out = left.join(right, JoinOptions::on([@expr.col("k")]))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "rv"])
  // k=1 fans out to rv 10 then rv 20 (ascending right-row order), then k=2.
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(10))
  assert_eq(out.item(1, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(1, "rv"), @types.Scalar::Int(20))
  assert_eq(out.item(2, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(2, "rv"), @types.Scalar::Int(30))
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
  let out = left.join(right, JoinOptions::on([@expr.col("a"), @expr.col("b")]))
  assert_eq(out.check_invariants(), Ok(()))
  // Both key columns appear once, in left order, then the right non-key.
  assert_eq(out.columns(), ["a", "b", "lv", "rv"])
  assert_eq(out.shape(), (3, 4))
  // (x,1)->100, (x,2)->300, (y,1)->200; left order preserved.
  assert_eq(out.item(0, "lv"), @types.Scalar::String("p"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(100))
  assert_eq(out.item(1, "lv"), @types.Scalar::String("q"))
  assert_eq(out.item(1, "rv"), @types.Scalar::Int(300))
  assert_eq(out.item(2, "lv"), @types.Scalar::String("r"))
  assert_eq(out.item(2, "rv"), @types.Scalar::Int(200))
}

///|
test "join: multi-key composite is injective across field boundaries" {
  // ("a","bc") vs ("ab","c"): naive concatenation would collide and join
  // them spuriously; the composite key-cell tuple keeps them apart.
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
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k1"), @expr.col("k2")]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Only ("a","bc") matches; ("ab","c") must NOT.
  assert_eq(out.shape(), (1, 4))
  assert_eq(out.item(0, "lv"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(9))
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
  let out = left.join(right, JoinOptions::on([@expr.col("id")]))
  assert_eq(out.check_invariants(), Ok(()))
  // Left "value" keeps its name; right "value" becomes "value_right".
  assert_eq(out.columns(), ["id", "value", "value_right"])
  assert_eq(out.item(0, "value"), @types.Scalar::Int(100))
  assert_eq(out.item(0, "value_right"), @types.Scalar::Int(9))
  assert_eq(out.item(1, "value"), @types.Scalar::Int(200))
  assert_eq(out.item(1, "value_right"), @types.Scalar::Int(8))
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
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("id")]).with_suffix("_r"),
  )
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
    Ok(left.join(right, JoinOptions::on([@expr.col("id")]))) catch {
      e => Err(e)
    },
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
  let out = left_nullable().join(
    right_nullable(),
    JoinOptions::on([@expr.col("k")]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Only k=1 and k=2 match; the two null-keyed rows are dropped.
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "lv"), @types.Scalar::String("c"))
  assert_eq(out.item(1, "rv"), @types.Scalar::String("z"))
}

///|
test "left join keeps a null-keyed left row with null right columns" {
  let out = left_nullable().join(
    right_nullable(),
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Left),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Left join coalesces the key; all three left rows survive.
  assert_eq(out.columns(), ["k", "lv", "rv"])
  // The null-keyed left row (row 1) stays null and matches nothing, even
  // though the right frame also has a null-keyed row (null != null).
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.item(0, "k"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "k"), @types.Scalar::Null) // left key, was null
  assert_eq(out.item(1, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(1, "rv"), @types.Scalar::Null) // no match
  assert_eq(out.item(2, "k"), @types.Scalar::Int(2))
  assert_eq(out.item(2, "rv"), @types.Scalar::String("z"))
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
  let out = left.join(right, JoinOptions::on([@expr.col("k")]))
  assert_eq(out.check_invariants(), Ok(()))
  // NaN (row 0) matches the right NaN; 1.0 matches 1.0. Two rows, in left
  // order. (NaN cells aren't asserted by value — NaN != NaN under Eq.)
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(100))
  assert_eq(out.item(1, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(1, "rv"), @types.Scalar::Int(200))
}

///|
test "right join coalesces the key to the right frame's value (signed zero)" {
  // -0.0 (left) and +0.0 (right) fold to the same join key, so the single pair
  // matches. A Right join keeps every right row and must surface the RIGHT
  // side's key value per the coalesce contract. -0.0 and +0.0 are == as
  // scalars, so observe the sign bit through division: 1/+0.0 = +inf,
  // 1/-0.0 = -inf.
  let left = DataFrame::new([
    Series::from_floats("k", [-0.0]),
    Series::from_ints("lv", [1]),
  ])
  let right = DataFrame::new([
    Series::from_floats("k", [0.0]),
    Series::from_ints("rv", [2]),
  ])
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Right),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (1, 3))
  let k = match out.item(0, "k") {
    @types.Scalar::Float(v) => v
    _ => -1.0
  }
  // After the fix k = +0.0 → 1/k = +inf > 0; before it was the left's -0.0.
  assert_eq(1.0 / k > 0.0, true)
}

// ── Cross join (how = Cross) ─────────────────────────────────────────

///|
test "cross join produces the Cartesian product" {
  let left = DataFrame::new([Series::from_strings("lv", ["a", "b"])])
  let right = DataFrame::new([Series::from_ints("rv", [10, 20, 30])])
  let out = left.join(right, JoinOptions::cross())
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["lv", "rv"])
  // 2 x 3 = 6 rows: each left row paired with every right row, in order.
  assert_eq(out.shape(), (6, 2))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(10))
  assert_eq(out.item(2, "rv"), @types.Scalar::Int(30))
  assert_eq(out.item(3, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(3, "rv"), @types.Scalar::Int(10))
  assert_eq(out.item(5, "rv"), @types.Scalar::Int(30))
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
  assert_eq(out.item(0, "x"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "x_r"), @types.Scalar::Int(10))
}

///|
test "cross join with an empty operand is empty" {
  let left = DataFrame::new([Series::from_ints("lv", [1, 2])])
  let right = DataFrame::new([Series::from_ints("rv", [])])
  // n x 0 = 0 rows, schema preserved.
  assert_eq(left.join(right, JoinOptions::cross()).shape(), (0, 2))
  assert_eq(right.join(left, JoinOptions::cross()).shape(), (0, 2))
}

///|
test "cross join rejects key columns" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [2])])
  // Passing keys to a cross join is a usage error (Polars rejects it too).
  assert_true(
    (Ok(
      left.join(
        right,
        JoinOptions::on([@expr.col("k")]).with_how(JoinType::Cross),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a non-cross join with an empty key list is rejected" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [2])])
  // Empty `on` no longer silently cross-joins — it must be `how = Cross`.
  assert_true(
    (Ok(left.join(right, JoinOptions::on([]))) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(left.join(right, JoinOptions::on([]).with_how(JoinType::Left))) catch {
      e => Err(e)
    })
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
  let out = left.join(right, JoinOptions::on([@expr.col("k")]))
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
  let out = left.join(right, JoinOptions::on([@expr.col("k")]))
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
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Left),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Nothing matches; the coalesced key keeps the left value and rv is null.
  assert_eq(out.columns(), ["k", "lv", "rv"])
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.item(0, "k"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Null)
  assert_eq(out.item(1, "rv"), @types.Scalar::Null)
  // The all-null gathered right column still carries its source dtype.
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
  // Inner and left both coalesce the key now, so each is 3 columns.
  assert_eq(left.join(right, JoinOptions::on([@expr.col("k")])).shape(), (0, 3))
  assert_eq(
    left
    .join(right, JoinOptions::on([@expr.col("k")]).with_how(JoinType::Left))
    .shape(),
    (0, 3),
  )
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
  let inner = left.join(right, JoinOptions::on([@expr.col("k")]))
  assert_eq(inner.check_invariants(), Ok(()))
  assert_eq(inner.columns(), ["k", "lv", "ri", "rf", "rb"])
  assert_eq(inner.shape(), (2, 5))
  assert_eq(inner.item(0, "ri"), @types.Scalar::Int(7))
  assert_eq(inner.item(0, "rf"), @types.Scalar::Float(1.5))
  assert_eq(inner.item(0, "rb"), @types.Scalar::Bool(true))
  // k=2 matched, but the right cells are null at the source.
  assert_eq(inner.item(1, "ri"), @types.Scalar::Null)
  assert_eq(inner.item(1, "rf"), @types.Scalar::Null)
  assert_eq(inner.item(1, "rb"), @types.Scalar::Null)
  assert_eq(inner.get_column("ri").dtype(), @types.DataType::Int)
  assert_eq(inner.get_column("rf").dtype(), @types.DataType::Float)
  assert_eq(inner.get_column("rb").dtype(), @types.DataType::Bool)
  // Left join: k=3 is unmatched, so ri/rf/rb are null via the None branch;
  // the coalesced key keeps the left value (3).
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Left),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "ri", "rf", "rb"])
  assert_eq(out.shape(), (3, 5))
  assert_eq(out.item(2, "lv"), @types.Scalar::String("c"))
  assert_eq(out.item(2, "k"), @types.Scalar::Int(3))
  assert_eq(out.item(2, "ri"), @types.Scalar::Null)
  assert_eq(out.item(2, "rf"), @types.Scalar::Null)
  assert_eq(out.item(2, "rb"), @types.Scalar::Null)
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "join raises ColumnNotFound for a key missing on the left" {
  assert_eq(
    Ok(employees().join(departments(), JoinOptions::on([@expr.col("nope")]))) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nope")),
  )
}

///|
test "join raises ColumnNotFound for a key present left but missing right" {
  // "name" exists in employees but not in departments — the right check
  // fires for it.
  assert_eq(
    Ok(employees().join(departments(), JoinOptions::on([@expr.col("name")]))) catch {
      e => Err(e)
    },
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
    (Ok(left.join(right, JoinOptions::on([@expr.col("k")]))) catch {
      e => Err(e)
    })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

///|
test "left_on / right_on TypeMismatch names both sides' keys" {
  let left = DataFrame::new([
    Series::from_ints("lk", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_strings("rk", ["1", "2"]),
    Series::from_ints("rv", [10, 20]),
  ])
  // Differently-named keys with mismatched dtypes: the diagnostic names both
  // the left and the right key (an `on` join shares one name).
  assert_eq(
    Ok(
      left.join(
        right,
        JoinOptions::left_on([@expr.col("lk")]).with_right_on([@expr.col("rk")]),
      ),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "join key \"lk\" (left) / \"rk\" (right) has dtype Int on the left but String on the right",
        ),
      ),
    ),
  )
}

// ── Right join, single key ───────────────────────────────────────────

///|
test "right join keeps every right row, nulling unmatched left columns" {
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")]).with_how(JoinType::Right),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Mirror of left: column order is still left then right, and a right join
  // coalesces the key by default — the single `dept_id` takes the right value
  // on an unmatched-left (right-only) row.
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  // Row set = every right department, in right order. Eng (dept 10) fans out
  // to its two employees in ascending left-row order (Alice then Carol),
  // then Sales (dept 20), then HR (dept 30) with no employee.
  assert_eq(out.shape(), (4, 4))
  assert_eq(out.item(0, "name"), @types.Scalar::String("Alice"))
  assert_eq(out.item(0, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.item(1, "name"), @types.Scalar::String("Carol"))
  assert_eq(out.item(1, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.item(2, "name"), @types.Scalar::String("Bob"))
  assert_eq(out.item(2, "dept_name"), @types.Scalar::String("Sales"))
  // HR has no employee: the left non-key columns are null, while the coalesced
  // key carries the right row's value (30) and dept_name is "HR".
  assert_eq(out.item(3, "emp_id"), @types.Scalar::Null)
  assert_eq(out.item(3, "name"), @types.Scalar::Null)
  assert_eq(out.item(3, "dept_id"), @types.Scalar::Int(30)) // coalesced from right
  assert_eq(out.item(3, "dept_name"), @types.Scalar::String("HR"))
  // The all-null gathered left columns still carry their source dtype.
  assert_eq(out.get_column("emp_id").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("name").dtype(), @types.DataType::String)
}

///|
test "right join with coalesce=true takes the key from the right side" {
  // Coalescing a right join keeps the key once, from the always-present
  // right side — so the unmatched HR row carries dept 30 in the single key.
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")])
    .with_how(JoinType::Right)
    .with_coalesce(true),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  assert_eq(out.shape(), (4, 4))
  assert_eq(out.item(0, "dept_id"), @types.Scalar::Int(10))
  // HR: no employee, but the coalesced key still shows dept 30 (right side).
  assert_eq(out.item(3, "name"), @types.Scalar::Null)
  assert_eq(out.item(3, "dept_id"), @types.Scalar::Int(30))
  assert_eq(out.item(3, "dept_name"), @types.Scalar::String("HR"))
}

// ── Outer (full) join, single key ────────────────────────────────────

///|
test "outer join keeps unmatched rows from both sides" {
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")]).with_how(JoinType::Outer),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Full outer does NOT coalesce by default — both keys kept.
  assert_eq(out.columns(), [
    "emp_id", "name", "dept_id", "dept_id_right", "dept_name",
  ])
  // Left rows first (Alice, Bob, Carol matched; Dave unmatched-left), then
  // the unmatched right row (HR).
  assert_eq(out.shape(), (5, 5))
  assert_eq(out.item(0, "name"), @types.Scalar::String("Alice"))
  assert_eq(out.item(0, "dept_name"), @types.Scalar::String("Eng"))
  assert_eq(out.item(1, "name"), @types.Scalar::String("Bob"))
  assert_eq(out.item(2, "name"), @types.Scalar::String("Carol"))
  // Dave (dept 99) unmatched-left: right key + dept_name null.
  assert_eq(out.item(3, "name"), @types.Scalar::String("Dave"))
  assert_eq(out.item(3, "dept_id"), @types.Scalar::Int(99))
  assert_eq(out.item(3, "dept_id_right"), @types.Scalar::Null)
  assert_eq(out.item(3, "dept_name"), @types.Scalar::Null)
  // HR unmatched-right (appended last): left columns null.
  assert_eq(out.item(4, "emp_id"), @types.Scalar::Null)
  assert_eq(out.item(4, "name"), @types.Scalar::Null)
  assert_eq(out.item(4, "dept_id"), @types.Scalar::Null)
  assert_eq(out.item(4, "dept_id_right"), @types.Scalar::Int(30))
  assert_eq(out.item(4, "dept_name"), @types.Scalar::String("HR"))
}

///|
test "outer join with coalesce=true takes the present side per row" {
  // The full-outer coalesce semantic: the single key takes the left value
  // where the left row is present (matched / unmatched-left) and the right
  // value otherwise (an unmatched-right row).
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")])
    .with_how(JoinType::Outer)
    .with_coalesce(true),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["emp_id", "name", "dept_id", "dept_name"])
  assert_eq(out.shape(), (5, 4))
  // Matched rows: key from either side (equal).
  assert_eq(out.item(0, "dept_id"), @types.Scalar::Int(10))
  // Dave unmatched-left: key from the (present) left side = 99.
  assert_eq(out.item(3, "name"), @types.Scalar::String("Dave"))
  assert_eq(out.item(3, "dept_id"), @types.Scalar::Int(99))
  assert_eq(out.item(3, "dept_name"), @types.Scalar::Null)
  // HR unmatched-right: left absent, so the key comes from the right = 30.
  assert_eq(out.item(4, "name"), @types.Scalar::Null)
  assert_eq(out.item(4, "dept_id"), @types.Scalar::Int(30))
  assert_eq(out.item(4, "dept_name"), @types.Scalar::String("HR"))
}

// ── Coalesced-key merge across all four dtypes ───────────────────────

///|
/// A coalesced outer join exercises every branch of the per-row key merge
/// for one dtype: a matched row (value from the present base/left side), an
/// unmatched-**right** row (base null → value filled from the right), and a
/// null-keyed unmatched-**left** row (both sides null → key stays null).
/// Run once per dtype (Int / Float / Bool / String) so the merge's four
/// storage arms are all covered. The left key carries the null (row 1, which
/// matches nothing), the right key the extra value (row "2", unmatched).
fn coalesce_probe(
  left_key : Series,
  right_key : Series,
) -> DataFrame raise @types.DataError {
  let left = DataFrame::new([left_key, Series::from_strings("v_l", ["a", "b"])])
  let right = DataFrame::new([
    right_key,
    Series::from_strings("v_r", ["x", "y"]),
  ])
  left.join(
    right,
    JoinOptions::on([@expr.col("k")])
    .with_how(JoinType::Outer)
    .with_coalesce(true),
  )
}

///|
test "coalesced outer key merge over an Int key" {
  let out = coalesce_probe(
    Series::from_int_options("k", [Some(1), None]),
    Series::from_ints("k", [1, 2]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "v_l", "v_r"])
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.get_column("k").dtype(), @types.DataType::Int)
  // row 0 matched (key from left), row 1 unmatched-left null key, row 2
  // unmatched-right (key filled from the right).
  assert_eq(out.item(0, "k"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "v_l"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "v_r"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "k"), @types.Scalar::Null)
  assert_eq(out.item(1, "v_l"), @types.Scalar::String("b"))
  assert_eq(out.item(1, "v_r"), @types.Scalar::Null)
  assert_eq(out.item(2, "k"), @types.Scalar::Int(2))
  assert_eq(out.item(2, "v_l"), @types.Scalar::Null)
  assert_eq(out.item(2, "v_r"), @types.Scalar::String("y"))
}

///|
test "coalesced outer key merge over a Float key" {
  let out = coalesce_probe(
    Series::from_float_options("k", [Some(1.0), None]),
    Series::from_floats("k", [1.0, 2.0]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("k").dtype(), @types.DataType::Float)
  assert_eq(out.item(0, "k"), @types.Scalar::Float(1.0))
  assert_eq(out.item(1, "k"), @types.Scalar::Null)
  assert_eq(out.item(2, "k"), @types.Scalar::Float(2.0))
}

///|
test "coalesced outer key merge over a Bool key" {
  let out = coalesce_probe(
    Series::from_bool_options("k", [Some(true), None]),
    Series::from_bools("k", [true, false]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("k").dtype(), @types.DataType::Bool)
  assert_eq(out.item(0, "k"), @types.Scalar::Bool(true))
  assert_eq(out.item(1, "k"), @types.Scalar::Null)
  assert_eq(out.item(2, "k"), @types.Scalar::Bool(false))
}

///|
test "coalesced outer key merge over a String key" {
  let out = coalesce_probe(
    Series::from_string_options("k", [Some("p"), None]),
    Series::from_strings("k", ["p", "q"]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("k").dtype(), @types.DataType::String)
  assert_eq(out.item(0, "k"), @types.Scalar::String("p"))
  assert_eq(out.item(1, "k"), @types.Scalar::Null)
  assert_eq(out.item(2, "k"), @types.Scalar::String("q"))
}

// ── Right / Outer multi key ──────────────────────────────────────────

///|
test "outer join on a key tuple keeps unmatched rows from both sides" {
  let left = DataFrame::new([
    Series::from_strings("a", ["x", "x", "y"]),
    Series::from_ints("b", [1, 2, 1]),
    Series::from_strings("lv", ["p", "q", "r"]),
  ])
  let right = DataFrame::new([
    Series::from_strings("a", ["x", "y", "z"]),
    Series::from_ints("b", [1, 1, 2]),
    Series::from_ints("rv", [100, 200, 300]),
  ])
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("a"), @expr.col("b")]).with_how(JoinType::Outer),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Both keys kept (no coalesce by default), each suffixed on the right.
  assert_eq(out.columns(), ["a", "b", "lv", "a_right", "b_right", "rv"])
  // (x,1) matches; (x,2) unmatched-left; (y,1) matches; (z,2) unmatched-right.
  assert_eq(out.shape(), (4, 6))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("p"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(100))
  assert_eq(out.item(1, "lv"), @types.Scalar::String("q"))
  assert_eq(out.item(1, "a_right"), @types.Scalar::Null) // (x,2) unmatched-left
  assert_eq(out.item(1, "rv"), @types.Scalar::Null)
  assert_eq(out.item(2, "lv"), @types.Scalar::String("r"))
  assert_eq(out.item(2, "rv"), @types.Scalar::Int(200))
  // (z,2) unmatched-right: left columns null, right key suffixes carry it.
  assert_eq(out.item(3, "a"), @types.Scalar::Null)
  assert_eq(out.item(3, "b"), @types.Scalar::Null)
  assert_eq(out.item(3, "a_right"), @types.Scalar::String("z"))
  assert_eq(out.item(3, "b_right"), @types.Scalar::Int(2))
  assert_eq(out.item(3, "rv"), @types.Scalar::Int(300))
}

///|
test "right join on a key tuple keeps every right row" {
  let left = DataFrame::new([
    Series::from_strings("a", ["x", "y"]),
    Series::from_ints("b", [1, 1]),
    Series::from_strings("lv", ["p", "r"]),
  ])
  let right = DataFrame::new([
    Series::from_strings("a", ["x", "z"]),
    Series::from_ints("b", [1, 2]),
    Series::from_ints("rv", [100, 300]),
  ])
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("a"), @expr.col("b")]).with_how(JoinType::Right),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["a", "b", "lv", "rv"])
  // (x,1) matches l0; (z,2) has no left row — its coalesced keys come from
  // the right.
  assert_eq(out.shape(), (2, 4))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("p"))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(100))
  assert_eq(out.item(1, "a"), @types.Scalar::String("z")) // coalesced from right
  assert_eq(out.item(1, "b"), @types.Scalar::Int(2))
  assert_eq(out.item(1, "lv"), @types.Scalar::Null) // (z,2) no left match
  assert_eq(out.item(1, "rv"), @types.Scalar::Int(300))
}

// ── Right / Outer null keys: null matches nothing ────────────────────

///|
test "right join: a null right key matches nothing, kept with null left" {
  let out = left_nullable().join(
    right_nullable(),
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Right),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "rv"])
  // Every right row survives, in right order. The null-keyed right row (1)
  // matches nothing — not even the left's null-keyed row (null != null) — so
  // its coalesced key stays null.
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "k"), @types.Scalar::Null) // right key was null
  assert_eq(out.item(1, "lv"), @types.Scalar::Null) // left absent
  assert_eq(out.item(1, "rv"), @types.Scalar::String("y"))
  assert_eq(out.item(2, "lv"), @types.Scalar::String("c"))
  assert_eq(out.item(2, "rv"), @types.Scalar::String("z"))
}

///|
test "outer join: null keys on both sides each stay unmatched" {
  let out = left_nullable().join(
    right_nullable(),
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Outer),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "k_right", "rv"])
  // k=1 and k=2 match; the two null-keyed rows (left row 1, right row 1)
  // each surface unmatched — left's first (in place), right's appended last.
  assert_eq(out.shape(), (4, 4))
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x")) // k=1 matched
  assert_eq(out.item(1, "k"), @types.Scalar::Null) // left null key, unmatched
  assert_eq(out.item(1, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(1, "rv"), @types.Scalar::Null)
  assert_eq(out.item(2, "rv"), @types.Scalar::String("z")) // k=2 matched
  assert_eq(out.item(3, "lv"), @types.Scalar::Null) // right null key, appended
  assert_eq(out.item(3, "rv"), @types.Scalar::String("y"))
}

// ── Right / Outer suffix + empty frames ──────────────────────────────

///|
test "right join suffixes a right non-key column clashing with a left name" {
  let left = DataFrame::new([
    Series::from_ints("id", [1, 2]),
    Series::from_ints("value", [100, 200]),
  ])
  let right = DataFrame::new([
    Series::from_ints("id", [1, 3]),
    Series::from_ints("value", [9, 8]),
  ])
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("id")]).with_how(JoinType::Right),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["id", "value", "value_right"])
  // id=1 matches l0; id=3 has no left row.
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.item(0, "value"), @types.Scalar::Int(100))
  assert_eq(out.item(0, "value_right"), @types.Scalar::Int(9))
  assert_eq(out.item(1, "id"), @types.Scalar::Int(3)) // coalesced from right
  assert_eq(out.item(1, "value"), @types.Scalar::Null) // left absent
  assert_eq(out.item(1, "value_right"), @types.Scalar::Int(8))
}

///|
test "right join with a 0-row left frame keeps all right rows, null left" {
  let left = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_strings("lv", []),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_strings("rv", ["x", "y"]),
  ])
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Right),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["k", "lv", "rv"])
  // No left rows, so every right row is unmatched: lv is null and the
  // coalesced key takes the right value.
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.item(0, "k"), @types.Scalar::Int(1)) // coalesced from right
  assert_eq(out.item(0, "lv"), @types.Scalar::Null)
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "k"), @types.Scalar::Int(2))
}

///|
test "outer join of two 0-row frames is empty with the joined schema" {
  let left = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_strings("lv", []),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", []),
    Series::from_ints("rv", []),
  ])
  // No coalesce by default, so both keys are kept (4 cols), zero rows.
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Outer),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 4))
  assert_eq(out.columns(), ["k", "lv", "k_right", "rv"])
  // Coalesced outer over empty frames keeps the key once (3 cols), 0 rows.
  let merged = left.join(
    right,
    JoinOptions::on([@expr.col("k")])
    .with_how(JoinType::Outer)
    .with_coalesce(true),
  )
  assert_eq(merged.shape(), (0, 3))
  assert_eq(merged.columns(), ["k", "lv", "rv"])
}

///|
test "a right join with an empty key list is rejected" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [2])])
  // The Right planner guards an empty `on` the same way the others do.
  assert_true(
    (Ok(left.join(right, JoinOptions::on([]).with_how(JoinType::Right))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "right / outer join raise ColumnNotFound for a missing key" {
  // The shared key resolver fires for both planners (left frame checked
  // before right): "nope" is absent on the left.
  assert_true(
    (Ok(
      employees().join(
        departments(),
        JoinOptions::on([@expr.col("nope")]).with_how(JoinType::Right),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ColumnNotFound("nope")),
  )
  assert_true(
    (Ok(
      employees().join(
        departments(),
        JoinOptions::on([@expr.col("nope")]).with_how(JoinType::Outer),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ColumnNotFound("nope")),
  )
}

///|
test "right / outer join raise TypeMismatch when a key dtype differs" {
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  // Right "k" is a String column — the shared resolver rejects the join
  // before any row work, the same as for inner / left.
  let right = DataFrame::new([
    Series::from_strings("k", ["1", "2"]),
    Series::from_ints("rv", [10, 20]),
  ])
  assert_true(
    (Ok(
      left.join(
        right,
        JoinOptions::on([@expr.col("k")]).with_how(JoinType::Right),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  assert_true(
    (Ok(
      left.join(
        right,
        JoinOptions::on([@expr.col("k")]).with_how(JoinType::Outer),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

// ── Duplicate key in `on` (aligns with group_by / select) ────────────

///|
test "join raises DuplicateColumn for a key repeated in `on`" {
  // `["dept_id", "dept_id"]` would otherwise resolve the same column twice
  // and silently behave as the single key `["dept_id"]`. Like
  // `group_by([col("id"), col("id")])`, the repeat is rejected. Both resolver call
  // sites are covered: inner (the Inner / Left / Outer planner) and right.
  assert_eq(
    Ok(
      employees().join(
        departments(),
        JoinOptions::on([@expr.col("dept_id"), @expr.col("dept_id")]),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("dept_id")),
  )
  assert_eq(
    Ok(
      employees().join(
        departments(),
        JoinOptions::on([@expr.col("dept_id"), @expr.col("dept_id")]).with_how(
          JoinType::Right,
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("dept_id")),
  )
  assert_eq(
    Ok(
      employees().join(
        departments(),
        JoinOptions::on([@expr.col("dept_id"), @expr.col("dept_id")]).with_how(
          JoinType::Outer,
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("dept_id")),
  )
}

///|
test "a repeated MISSING key surfaces as ColumnNotFound, not DuplicateColumn" {
  // The duplicate check runs before the column lookups, so a missing key
  // still fails at its first appearance — matching `group_by`'s contract
  // that a missing key beats a later duplicate.
  assert_eq(
    Ok(
      employees().join(
        departments(),
        JoinOptions::on([@expr.col("nope"), @expr.col("nope")]),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nope")),
  )
}

// ── Output column backend preserved (Q2: no silent Numeric demotion) ──

///|
test "join keeps all-valid numeric output columns on the Numeric fast path" {
  // Every column is an all-valid numeric `Series` (the `from_ints` /
  // `from_floats` constructors land on `Numeric`). An inner join injects no
  // `None` on either side, so each gathered column — including the coalesced
  // key — re-converges to `Numeric` rather than demoting to `Builtin`,
  // matching filter / sort / take / drop_nulls / fill_null.
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_floats("lv", [1.5, 2.5]),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_ints("rv", [10, 20]),
  ])
  let out = left.join(right, JoinOptions::on([@expr.col("k")]))
  assert_eq(out.columns(), ["k", "lv", "rv"])
  assert_eq(out.storage_kinds(), [
    @column.StorageKind::Numeric, // coalesced key (left Numeric, all matched)
    @column.StorageKind::Numeric, // left non-key
    @column.StorageKind::Numeric, // right non-key, no None injected
  ])
  // Values are unchanged by the backend choice.
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(10))
  // A cross join likewise injects no None: every numeric column stays Numeric.
  let crossed = DataFrame::new([Series::from_ints("a", [1, 2])]).join(
    DataFrame::new([Series::from_floats("b", [3.0])]),
    JoinOptions::cross(),
  )
  assert_eq(crossed.storage_kinds(), [
    @column.StorageKind::Numeric,
    @column.StorageKind::Numeric,
  ])
}

///|
test "join demotes only the columns that pick up an unmatched-row null" {
  // Dave (dept 99) is unmatched, so the left join injects a `None` into the
  // right columns at his row — those become nullable and stay `Builtin`. The
  // left columns (always present) keep their `Numeric` backend. With coalesce
  // turned off, the kept right key `dept_id_right` is the clearest witness: it
  // gathers a null at Dave and demotes to `Builtin`, while the left key
  // `dept_id` (every row present) stays `Numeric`.
  let out = employees().join(
    departments(),
    JoinOptions::on([@expr.col("dept_id")])
    .with_how(JoinType::Left)
    .with_coalesce(false),
  )
  assert_eq(out.columns(), [
    "emp_id", "name", "dept_id", "dept_id_right", "dept_name",
  ])
  assert_eq(
    out.get_column("emp_id").storage_kind(),
    @column.StorageKind::Numeric,
  )
  // Left key, every left row present → no None.
  assert_eq(
    out.get_column("dept_id").storage_kind(),
    @column.StorageKind::Numeric,
  )
  // Right key gathered over output rows: null at Dave → nullable → Builtin.
  assert_eq(
    out.get_column("dept_id_right").storage_kind(),
    @column.StorageKind::Builtin,
  )
  // `name` / `dept_name` are String columns — always Builtin.
  assert_eq(out.get_column("name").storage_kind(), @column.StorageKind::Builtin)
}

///|
test "a right numeric column with no unmatched-left rows stays Numeric" {
  // Every left row matches, so `right_rows` carries no `None`: the gathered
  // right key and right non-key numeric columns stay on the `Numeric` fast
  // path even though the join could have injected nulls.
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_ints("lv", [5, 6]),
  ])
  let right = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_ints("rv", [10, 20]),
  ])
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("k")]).with_how(JoinType::Left),
  )
  assert_eq(out.columns(), ["k", "lv", "rv"])
  assert_eq(out.storage_kinds(), [
    @column.StorageKind::Numeric, // coalesced key, all matched → no None
    @column.StorageKind::Numeric, // left non-key
    @column.StorageKind::Numeric, // right non-key, all matched → no None
  ])
}

///|
test "join leaves a Builtin (nullable) source column on Builtin" {
  // A source column carrying a null is `Builtin`; preserving the backend
  // keeps it there (there is no all-valid Numeric form to move to). The
  // gathered output is still correct — only the representation is unchanged.
  let left = DataFrame::new([
    Series::from_ints("k", [1, 2]),
    Series::from_int_options("lv", [Some(5), None]), // Builtin (has a null)
  ])
  let right = DataFrame::new([Series::from_ints("k", [1, 2])])
  let out = left.join(right, JoinOptions::on([@expr.col("k")]))
  assert_eq(out.get_column("lv").storage_kind(), @column.StorageKind::Builtin)
  assert_eq(out.item(0, "lv"), @types.Scalar::Int(5))
  assert_eq(out.item(1, "lv"), @types.Scalar::Null)
}

// ── Expression keys: left_on / right_on and derived keys ─────────────

///|
test "left_on / right_on join on differently-named columns, keeping both" {
  let left = DataFrame::new([
    Series::from_ints("lk", [1, 2, 3]),
    Series::from_strings("lv", ["a", "b", "c"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("rk", [2, 3, 4]),
    Series::from_ints("rv", [20, 30, 40]),
  ])
  let out = left.join(
    right,
    JoinOptions::left_on([@expr.col("lk")]).with_right_on([@expr.col("rk")]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // left_on / right_on never coalesce — both differently-named key columns
  // are kept (no suffix needed, the names differ).
  assert_eq(out.columns(), ["lk", "lv", "rk", "rv"])
  // lk=1 and rk=4 are unmatched (inner); lk=2↔rk=2, lk=3↔rk=3, left order.
  assert_eq(out.shape(), (2, 4))
  assert_eq(out.item(0, "lk"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(0, "rk"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(20))
  assert_eq(out.item(1, "lk"), @types.Scalar::Int(3))
  assert_eq(out.item(1, "rv"), @types.Scalar::Int(30))
}

///|
test "left_on may repeat a column for a multi-condition join" {
  // `left_on([a, a]).right_on([b, c])` means `a == b AND a == c` — a valid
  // multi-condition join (Polars allows it). The repeated left key must not be
  // rejected as DuplicateColumn: the left and right key columns carry their own
  // names, so there is no output-column collision (the dedup is `on`-only).
  let left = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("lv", ["p", "q", "r"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("b", [2, 9]),
    Series::from_ints("c", [2, 8]),
    Series::from_strings("rv", ["x", "y"]),
  ])
  let out = left.join(
    right,
    JoinOptions::left_on([@expr.col("a"), @expr.col("a")]).with_right_on([
      @expr.col("b"),
      @expr.col("c"),
    ]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Only left a=2 satisfies a == b AND a == c (right row b=2, c=2).
  assert_eq(out.columns(), ["a", "lv", "b", "c", "rv"])
  assert_eq(out.shape(), (1, 5))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("q"))
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x"))
}

///|
test "left_on / right_on with a derived right key matches on the value" {
  let left = DataFrame::new([
    Series::from_ints("cents", [100, 250, 300]),
    Series::from_strings("item", ["a", "b", "c"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("dollars", [1, 3]),
    Series::from_strings("tier", ["x", "y"]),
  ])
  // Match left `cents` against right `dollars * 100`: 100↔1, 300↔3; 250 drops.
  let out = left.join(
    right,
    JoinOptions::left_on([@expr.col("cents")]).with_right_on([
      @expr.col("dollars") * @expr.lit_int(100),
    ]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // The derived key contributes no column; the frames' own columns survive.
  assert_eq(out.columns(), ["cents", "item", "dollars", "tier"])
  assert_eq(out.shape(), (2, 4))
  assert_eq(out.item(0, "cents"), @types.Scalar::Int(100))
  assert_eq(out.item(0, "item"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "dollars"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "tier"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "cents"), @types.Scalar::Int(300))
  assert_eq(out.item(1, "tier"), @types.Scalar::String("y"))
}

///|
// Two distinct derived keys rooted at the same source column share a leftmost
// name ("ts") but are different keys. They must not collide as
// `DuplicateColumn` — a derived key produces no output column, so there is no
// name clash to prevent. Only bare `col` keys are deduplicated.
test "two derived keys over one source column join without a false DuplicateColumn" {
  let left = DataFrame::new([
    Series::from_ints("ts", [3, 4]),
    Series::from_strings("litem", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("ka", [4, 5]),
    Series::from_ints("kb", [6, 8]),
    Series::from_strings("ritem", ["x", "y"]),
  ])
  // Keys: ts + 1 = [4, 5] and ts * 2 = [6, 8]; both name "ts" but differ.
  let out = left.join(
    right,
    JoinOptions::left_on([
      @expr.col("ts") + @expr.lit_int(1),
      @expr.col("ts") * @expr.lit_int(2),
    ]).with_right_on([@expr.col("ka"), @expr.col("kb")]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["ts", "litem", "ka", "kb", "ritem"])
  assert_eq(out.shape(), (2, 5))
  assert_eq(out.item(0, "litem"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "ritem"), @types.Scalar::String("x"))
  assert_eq(out.item(1, "litem"), @types.Scalar::String("b"))
  assert_eq(out.item(1, "ritem"), @types.Scalar::String("y"))
}

///|
test "a derived `on` key turns off coalescing, keeping both source columns" {
  let left = DataFrame::new([
    Series::from_ints("x", [1, 2, 3]),
    Series::from_strings("lv", ["a", "b", "c"]),
  ])
  let right = DataFrame::new([
    Series::from_ints("x", [2, 3]),
    Series::from_ints("rv", [20, 30]),
  ])
  // `on([x * 2])` is a derived (non-bare-`col`) key, so coalescing is off:
  // the right `x` is kept, suffixed, rather than merged into the left's.
  let opts = JoinOptions::on([@expr.col("x") * @expr.lit_int(2)])
  let out = left.join(right, opts)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["x", "lv", "x_right", "rv"])
  assert_eq(out.shape(), (2, 4))
  assert_eq(out.item(0, "x"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("b"))
  assert_eq(out.item(0, "x_right"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "rv"), @types.Scalar::Int(20))
  assert_eq(out.item(1, "x"), @types.Scalar::Int(3))
  assert_eq(out.item(1, "rv"), @types.Scalar::Int(30))
  // A derived key cannot name a single column, so even an explicit
  // `with_coalesce(true)` leaves both key columns in place.
  let forced = left.join(right, opts.with_coalesce(true))
  assert_eq(forced.columns(), ["x", "lv", "x_right", "rv"])
}

///|
test "left_on / right_on keys: a null key matches nothing" {
  let left = DataFrame::new([
    Series::from_int_options("lk", [Some(1), None]),
    Series::from_strings("lv", ["a", "b"]),
  ])
  let right = DataFrame::new([
    Series::from_int_options("rk", [Some(1), None]),
    Series::from_strings("rv", ["x", "y"]),
  ])
  let out = left.join(
    right,
    JoinOptions::left_on([@expr.col("lk")]).with_right_on([@expr.col("rk")]),
  )
  assert_eq(out.check_invariants(), Ok(()))
  // Only lk=1 ↔ rk=1 pairs; the null-keyed rows match nothing (null != null),
  // not even each other.
  assert_eq(out.columns(), ["lk", "lv", "rk", "rv"])
  assert_eq(out.shape(), (1, 4))
  assert_eq(out.item(0, "lv"), @types.Scalar::String("a"))
  assert_eq(out.item(0, "rv"), @types.Scalar::String("x"))
}

///|
test "join rejects mixing `on` with `left_on` / `right_on`" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [1])])
  // Giving both is a usage error (Polars accepts only one form).
  assert_true(
    (Ok(
      left.join(
        right,
        JoinOptions::on([@expr.col("k")]).with_right_on([@expr.col("k")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "join rejects unequal-length left_on / right_on" {
  let left = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_ints("b", [2]),
  ])
  let right = DataFrame::new([Series::from_ints("c", [1])])
  // Two left keys, one right key: the pairing is undefined.
  assert_true(
    (Ok(
      left.join(
        right,
        JoinOptions::left_on([@expr.col("a"), @expr.col("b")]).with_right_on([
          @expr.col("c"),
        ]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // `left_on` with no `right_on` is the 1-vs-0 case of the same rule.
  assert_true(
    (Ok(left.join(right, JoinOptions::left_on([@expr.col("a")]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
