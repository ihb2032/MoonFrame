// Blackbox tests for the `ColumnStorage` seam (S0 spike, PLAN_v0.3.md §3
// S0). Two validation jobs:
//
//   • point 1 — coverage gate × closed enum: every accessor's `match` is
//     called on BOTH a Builtin-backed and a Numeric-backed storage, so both
//     arms execute and `moon coverage analyze` reports no dead arm.
//   • point 2 — `Series.storage` flip is mechanical: `read_like_ops`
//     reproduces, verbatim, the read pattern the four ops files use through
//     `.storage()` (`drop_nulls` / `group_by` / `join` / `sort`). It takes a
//     `ColumnStorage` (not a `BuiltinColumn`), proving the only edit those
//     sites need is the storage type — the `.validity().to_bools()` and
//     `match .data() { ... }` body is unchanged.

///|
/// The exact read shape of `frame/sort.mbt::build_sort_key` (and the
/// `.validity().to_bools()` + `match .data()` reads in `group_by` / `join` /
/// `drop_nulls`), but parameterised over `ColumnStorage`. That it compiles
/// and runs against `ColumnStorage` is the empirical proof of point 2: the
/// flip needs only the parameter/return type swapped, not the logic. Returns
/// the dtype tag and the per-row missing mask (`Null`, plus `NaN` for
/// `Float`) those sites compute.
fn read_like_ops(storage : @column.ColumnStorage) -> (String, Array[Bool]) {
  let valid = storage.validity().to_bools()
  match storage.data() {
    ColumnData::Int(a) => ("Int", Array::makei(a.length(), i => !valid[i]))
    ColumnData::Float(a) =>
      ("Float", Array::makei(a.length(), i => !valid[i] || a[i].is_nan()))
    ColumnData::Bool(a) => ("Bool", Array::makei(a.length(), i => !valid[i]))
    ColumnData::String(a) =>
      ("String", Array::makei(a.length(), i => !valid[i]))
  }
}

// ── point 1: both arms of every accessor ──────────────────────────────

///|
test "kind / dtype / len / is_empty: both backends" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None, Some(3)]),
  )
  let numeric = ColumnStorage::from_numeric(
    NumericColumn::from_int64s([1, 2, 3]),
  )
  assert_eq(builtin.kind(), StorageKind::Builtin)
  assert_eq(numeric.kind(), StorageKind::Numeric)
  assert_eq(builtin.dtype(), @types.DataType::Int)
  assert_eq(numeric.dtype(), @types.DataType::Int)
  assert_eq(builtin.len(), 3)
  assert_eq(numeric.len(), 3)
  assert_true(!builtin.is_empty())
  assert_true(
    ColumnStorage::from_numeric(NumericColumn::from_int64s([])).is_empty(),
  )
}

///|
test "null_count / validity: Numeric arm synthesises an all-valid bitmap" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None, Some(3)]),
  )
  let numeric = ColumnStorage::from_numeric(
    NumericColumn::from_int64s([1, 2, 3]),
  )
  // Builtin arm forwards the real bitmap (1 null); Numeric arm forwards 0.
  assert_eq(builtin.null_count(), 1)
  assert_eq(numeric.null_count(), 0)
  // The Builtin bitmap reflects the null at index 1.
  assert_eq(builtin.validity().to_bools(), [true, false, true])
  // The Numeric arm has no stored bitmap — validity() builds an all-valid
  // one sized to the column (the one place the backends diverge).
  assert_eq(numeric.validity().to_bools(), [true, true, true])
  assert_eq(numeric.validity().null_count(), 0)
}

///|
test "data / get: both backends" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_strings(["x", "y"]),
  )
  let numeric = ColumnStorage::from_numeric(
    NumericColumn::from_int64s([10, 20]),
  )
  // data() forwards to the underlying ColumnData on each arm.
  assert_eq(builtin.data(), ColumnData::String(["x", "y"]))
  assert_eq(numeric.data(), ColumnData::Int([10, 20]))
  // get() forwards on each arm; OOB raises through either.
  assert_eq(builtin.get(0), @types.Scalar::String("x"))
  assert_eq(numeric.get(1), @types.Scalar::Int(20))
  assert_eq(try? builtin.get(9), Err(@types.DataError::IndexOutOfBounds(9)))
  assert_eq(try? numeric.get(9), Err(@types.DataError::IndexOutOfBounds(9)))
}

///|
test "from_builtin null cell surfaces through get" {
  let s = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None]),
  )
  assert_eq(s.get(0), @types.Scalar::Int(1))
  assert_eq(s.get(1), @types.Scalar::Null)
}

// ── point 2: the 4-ops read pattern runs verbatim on ColumnStorage ─────

///|
test "read_like_ops: every ColumnData arm via a Builtin backend" {
  // All four ColumnData arms of `build_sort_key`'s body, reached through a
  // ColumnStorage. Null (and NaN for Float) map to a `true` missing slot.
  let (tag_i, miss_i) = read_like_ops(
    ColumnStorage::from_builtin(
      BuiltinColumn::from_int_options([Some(1), None]),
    ),
  )
  assert_eq(tag_i, "Int")
  assert_eq(miss_i, [false, true])
  let nan = (0.0 : Double) / 0.0
  let (tag_f, miss_f) = read_like_ops(
    ColumnStorage::from_builtin(
      BuiltinColumn::from_float_options([Some(1.5), Some(nan), None]),
    ),
  )
  assert_eq(tag_f, "Float")
  // index 0 present; index 1 NaN → missing; index 2 null → missing.
  assert_eq(miss_f, [false, true, true])
  let (tag_b, miss_b) = read_like_ops(
    ColumnStorage::from_builtin(
      BuiltinColumn::from_bool_options([Some(true), None]),
    ),
  )
  assert_eq(tag_b, "Bool")
  assert_eq(miss_b, [false, true])
  let (tag_s, miss_s) = read_like_ops(
    ColumnStorage::from_builtin(
      BuiltinColumn::from_string_options([None, Some("z")]),
    ),
  )
  assert_eq(tag_s, "String")
  assert_eq(miss_s, [true, false])
}

///|
test "read_like_ops: Numeric backend reads through the same chain" {
  // A Numeric-backed storage flows through the identical `.validity()` +
  // `.data()` reads; all-valid → no missing slots.
  let (tag, miss) = read_like_ops(
    ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2, 3])),
  )
  assert_eq(tag, "Int")
  assert_eq(miss, [false, false, false])
}

// ── Eq derive ─────────────────────────────────────────────────────────

///|
test "Eq derive" {
  let a = ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2]))
  assert_eq(a, ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2])))
  assert_not_eq(
    a,
    ColumnStorage::from_builtin(BuiltinColumn::from_ints([1, 2])),
  )
  assert_eq(StorageKind::Builtin, StorageKind::Builtin)
  assert_not_eq(StorageKind::Builtin, StorageKind::Numeric)
}
