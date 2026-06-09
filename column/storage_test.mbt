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

// ── is_null: both backends ────────────────────────────────────────────

///|
test "is_null: Builtin reports the null, Numeric is always valid; both bounds-check" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None]),
  )
  let numeric = ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2]))
  assert_eq(builtin.is_null(0), false)
  assert_eq(builtin.is_null(1), true)
  assert_eq(numeric.is_null(0), false)
  assert_eq(numeric.is_null(1), false)
  assert_eq(try? builtin.is_null(9), Err(@types.DataError::IndexOutOfBounds(9)))
  assert_eq(try? numeric.is_null(9), Err(@types.DataError::IndexOutOfBounds(9)))
}

// ── slice / take: backend-preserving on both arms ─────────────────────

///|
test "slice keeps the backend on both arms" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None, Some(3), Some(4)]),
  )
  let numeric = ColumnStorage::from_numeric(
    NumericColumn::from_int64s([1, 2, 3, 4]),
  )
  let b = builtin.slice(1, 3)
  let n = numeric.slice(1, 3)
  assert_eq(b.kind(), StorageKind::Builtin)
  assert_eq(n.kind(), StorageKind::Numeric)
  assert_eq(b.get(0), @types.Scalar::Null)
  assert_eq(b.get(1), @types.Scalar::Int(3))
  assert_eq(n.data(), ColumnData::Int([2, 3]))
  // Bounds diagnostics forward from the underlying column.
  assert_eq(
    try? numeric.slice(0, 9),
    Err(@types.DataError::IndexOutOfBounds(9)),
  )
}

///|
test "slice_total keeps the backend, shares validity, and is total" {
  // Builtin arm: zero-copy validity view; the null inside the window must be
  // counted (offset-0 sub-window null_count, exercised at the storage layer).
  let b = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None, Some(3)]),
  )
  let bs = b.slice_total(0, 2)
  assert_eq(bs.kind(), StorageKind::Builtin)
  assert_eq(bs.len(), 2)
  assert_eq(bs.null_count(), 1)
  // Numeric arm stays Numeric for both Int and Float backings.
  let ni = ColumnStorage::from_numeric(NumericColumn::from_int64s([10, 20, 30]))
  let nis = ni.slice_total(1, 3)
  assert_eq(nis.kind(), StorageKind::Numeric)
  assert_eq(nis.len(), 2)
  assert_eq(nis.get(0), @types.Scalar::Int(20))
  let nf = ColumnStorage::from_numeric(NumericColumn::from_doubles([1.0, 2.0]))
  assert_eq(nf.slice_total(0, 1).get(0), @types.Scalar::Float(1.0))
}

///|
test "slice_total clamps out-of-range bounds instead of raising" {
  let b = ColumnStorage::from_builtin(BuiltinColumn::from_ints([1, 2, 3]))
  // start < 0 -> 0 and end > len -> len: the whole column.
  assert_eq(b.slice_total(-2, 99).len(), 3)
  // start > len -> len: an empty tail slice.
  assert_eq(b.slice_total(5, 7).len(), 0)
  // end < start -> empty (end lifted to start).
  assert_eq(b.slice_total(2, 1).len(), 0)
}

///|
test "take keeps the backend on both arms" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None, Some(3)]),
  )
  let numeric = ColumnStorage::from_numeric(
    NumericColumn::from_int64s([10, 20, 30]),
  )
  let b = builtin.take([2, 1, 0])
  let n = numeric.take([2, 0])
  assert_eq(b.kind(), StorageKind::Builtin)
  assert_eq(n.kind(), StorageKind::Numeric)
  assert_eq(b.get(1), @types.Scalar::Null)
  assert_eq(n.data(), ColumnData::Int([30, 10]))
  assert_eq(try? numeric.take([5]), Err(@types.DataError::IndexOutOfBounds(5)))
}

// ── Typed accessors: both arms ────────────────────────────────────────

///|
test "int_values / float_values: both arms, with synthesised validity on Numeric" {
  let bi = ColumnStorage::from_builtin(BuiltinColumn::from_ints([1, 2]))
  let ni = ColumnStorage::from_numeric(NumericColumn::from_int64s([3, 4]))
  let (ba, bv) = bi.int_values()
  let (na, nv) = ni.int_values()
  assert_eq(ba, [1, 2])
  assert_eq(bv.to_bools(), [true, true])
  assert_eq(na, [3, 4])
  assert_eq(nv.to_bools(), [true, true])
  let bf = ColumnStorage::from_builtin(BuiltinColumn::from_floats([1.5]))
  let nf = ColumnStorage::from_numeric(NumericColumn::from_doubles([2.5]))
  assert_eq(bf.float_values().0, [1.5])
  assert_eq(nf.float_values().0, [2.5])
  // Cross-type request raises through either backend.
  assert_true(
    (try? ni.float_values()) is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (try? bi.float_values()) is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "bool_values / string_values: Builtin success, Numeric always TypeMismatch" {
  let bb = ColumnStorage::from_builtin(BuiltinColumn::from_bools([true, false]))
  let bs = ColumnStorage::from_builtin(BuiltinColumn::from_strings(["x", "y"]))
  let n = ColumnStorage::from_numeric(NumericColumn::from_int64s([1]))
  assert_eq(bb.bool_values().0, [true, false])
  assert_eq(bs.string_values().0, ["x", "y"])
  assert_true((try? n.bool_values()) is Err(@types.DataError::TypeMismatch(_)))
  assert_true(
    (try? n.string_values()) is Err(@types.DataError::TypeMismatch(_)),
  )
}

// ── Materialise: to_builtin / to_string_column on both arms ────────────

///|
test "to_builtin widens Numeric losslessly and is identity on Builtin" {
  let raw = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let builtin = ColumnStorage::from_builtin(raw)
  let numeric = ColumnStorage::from_numeric(
    NumericColumn::from_int64s([1, 2, 3]),
  )
  // Builtin arm is identity.
  assert_eq(builtin.to_builtin(), raw)
  // Numeric arm widens to an all-valid BuiltinColumn equal to from_ints.
  assert_eq(numeric.to_builtin(), BuiltinColumn::from_ints([1, 2, 3]))
}

///|
test "to_string_column renders both arms to a String column" {
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(7), None]),
  )
  let numeric = ColumnStorage::from_numeric(NumericColumn::from_doubles([1.5]))
  let sb = builtin.to_string_column()
  let sn = numeric.to_string_column()
  assert_eq(sb.dtype(), @types.DataType::String)
  assert_eq(sb.get(0), @types.Scalar::String("7"))
  assert_eq(sb.get(1), @types.Scalar::Null)
  assert_eq(sn.get(0), @types.Scalar::String("1.5"))
}

// ── Cross-dtype transforms borrow the Builtin road ────────────────────

///|
test "cast / to_int / to_float route through Builtin (result is Builtin-backed)" {
  let numeric = ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2]))
  let builtin = ColumnStorage::from_builtin(
    BuiltinColumn::from_floats([1.5, 2.5]),
  )
  // A numeric source comes back Builtin-backed (the documented discipline).
  let as_float = numeric.to_float()
  assert_eq(as_float.kind(), StorageKind::Builtin)
  assert_eq(as_float.dtype(), @types.DataType::Float)
  assert_eq(as_float.get(0), @types.Scalar::Float(1.0))
  let as_int = builtin.to_int()
  assert_eq(as_int.kind(), StorageKind::Builtin)
  assert_eq(as_int.get(1), @types.Scalar::Int(2))
  // cast dispatches by target; String target renders, Bool target unsupported.
  assert_eq(
    numeric.cast(@types.DataType::String).get(0),
    @types.Scalar::String("1"),
  )
  assert_true(
    (try? numeric.cast(@types.DataType::Bool))
    is Err(@types.DataError::Unsupported(_)),
  )
}

// ── Converge onto Numeric: the five states ────────────────────────────

///|
test "to_numeric: already-Numeric is returned unchanged" {
  let n = ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2]))
  assert_eq(n.to_numeric(), n)
  assert_eq(n.to_numeric().kind(), StorageKind::Numeric)
}

///|
test "to_numeric: all-valid Int / Float Builtin moves to the fast path" {
  let i = ColumnStorage::from_builtin(BuiltinColumn::from_ints([1, 2, 3]))
  let f = ColumnStorage::from_builtin(BuiltinColumn::from_floats([1.5, 2.5]))
  let ni = i.to_numeric()
  let nf = f.to_numeric()
  assert_eq(ni.kind(), StorageKind::Numeric)
  assert_eq(nf.kind(), StorageKind::Numeric)
  assert_eq(
    ni,
    ColumnStorage::from_numeric(NumericColumn::from_int64s([1, 2, 3])),
  )
  assert_eq(
    nf,
    ColumnStorage::from_numeric(NumericColumn::from_doubles([1.5, 2.5])),
  )
  // Round-trips losslessly back through to_builtin.
  assert_eq(ni.to_builtin(), BuiltinColumn::from_ints([1, 2, 3]))
}

///|
test "to_numeric: a column with nulls raises InvalidOperation" {
  let s = ColumnStorage::from_builtin(
    BuiltinColumn::from_int_options([Some(1), None, Some(3)]),
  )
  assert_true(
    (try? s.to_numeric()) is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "to_numeric: a non-numeric column raises TypeMismatch" {
  let str = ColumnStorage::from_builtin(BuiltinColumn::from_strings(["a", "b"]))
  let boolc = ColumnStorage::from_builtin(BuiltinColumn::from_bools([true]))
  assert_true((try? str.to_numeric()) is Err(@types.DataError::TypeMismatch(_)))
  assert_true(
    (try? boolc.to_numeric()) is Err(@types.DataError::TypeMismatch(_)),
  )
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
