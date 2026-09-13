// Whitebox tests for the full `NumericColumn`. The
// all-valid numeric backend has a real, testable difference from
// `BuiltinColumn`, not an empty abstraction:
//   • construction / sub-views store only the data array (no validity
//     `Bitmap`), so `null_count` is structural (`0`) with no popcount;
//   • `to_builtin` widening is exactly `BuiltinColumn::from_ints` /
//     `from_floats` (the bitmap allocation the numeric path avoided), and is
//     value-preserving.
// The reduction fast path is tested in `numeric_reduce_wbtest.mbt`.

// ── Construction + inspection ─────────────────────────────────────────

///|
test "from_ints / from_floats: structural all-valid, no bitmap" {
  let i = NumericColumn::from_ints([10, 20, 30])
  assert_eq(i.len(), 3)
  assert_eq(i.dtype(), @types.DataType::Int)
  // null_count is 0 by construction — no validity buffer to consult.
  assert_eq(i.null_count(), 0)
  assert_false(i.is_empty())
  let f = NumericColumn::from_floats([1.5, 2.5])
  assert_eq(f.len(), 2)
  assert_eq(f.dtype(), @types.DataType::Float)
  assert_eq(f.null_count(), 0)
  assert_false(f.is_empty())
  assert_true(NumericColumn::from_ints([]).is_empty())
  assert_true(NumericColumn::from_floats([]).is_empty())
}

///|
// Defensive copy: `from_ints` / `from_floats` copy their input, so the
// column is independent of the caller's array.
test "from_ints / from_floats copy their input" {
  let ints : Array[Int64] = [1, 2, 3]
  let ic = NumericColumn::from_ints(ints)
  ints[0] = 99
  assert_eq(ic.get(0), @types.Scalar::Int(1))
  let flts : Array[Double] = [1.5, 2.5]
  let fc = NumericColumn::from_floats(flts)
  flts[0] = 9.9
  assert_eq(fc.get(0), @types.Scalar::Float(1.5))
}

///|
test "data() exposes the shared raw array as ColumnData" {
  assert_eq(
    NumericColumn::from_ints([1, 2, 3]).data(),
    ColumnData::Int([1, 2, 3]),
  )
  assert_eq(
    NumericColumn::from_floats([1.0, 2.0]).data(),
    ColumnData::Float([1.0, 2.0]),
  )
}

// ── is_null / get ─────────────────────────────────────────────────────

///|
test "is_null: bounds check only, value structurally false" {
  let i = NumericColumn::from_ints([7, 8])
  assert_false(i.is_null(0))
  assert_false(i.is_null(1))
  // No null slot exists — only out-of-bounds raises.
  assert_eq(
    Ok(i.is_null(-1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(i.is_null(2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(2)),
  )
  // Float column reads the same way.
  assert_false(NumericColumn::from_floats([1.5]).is_null(0))
}

///|
test "get: reads value per dtype, OOB raises (no null branch)" {
  let i = NumericColumn::from_ints([7, 8, 9])
  assert_eq(i.get(0), @types.Scalar::Int(7))
  assert_eq(i.get(2), @types.Scalar::Int(9))
  assert_eq(
    Ok(i.get(-1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(i.get(3)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(3)),
  )
  let f = NumericColumn::from_floats([1.5, 2.5])
  assert_eq(f.get(1), @types.Scalar::Float(2.5))
  assert_eq(
    Ok(f.get(9)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(9)),
  )
  assert_eq(
    Ok(f.get(-5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-5)),
  )
}

// ── slice / take (no bitmap to repack) ────────────────────────────────

///|
test "slice: sub-range per dtype stays all-valid" {
  let i = NumericColumn::from_ints([10, 20, 30, 40]).slice(1, 3)
  assert_eq(i.len(), 2)
  assert_eq(i.null_count(), 0)
  assert_eq(i.get(0), @types.Scalar::Int(20))
  assert_eq(i.get(1), @types.Scalar::Int(30))
  let f = NumericColumn::from_floats([1.0, 2.0, 3.0]).slice(0, 2)
  assert_eq(f.len(), 2)
  assert_eq(f.get(1), @types.Scalar::Float(2.0))
  // start == end → empty.
  assert_true(NumericColumn::from_ints([1, 2, 3]).slice(2, 2).is_empty())
}

///|
test "slice: invalid bounds report the actual offender (Builtin check order)" {
  let col = NumericColumn::from_ints([1, 2, 3])
  assert_eq(
    Ok(col.slice(-1, 2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(col.slice(0, 5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_true(
    (Ok(col.slice(2, 1)) catch { e => Err(e) }) is Err(InvalidOperation(_)),
  )
  // A negative `end` is out of range, not a misordered pair.
  assert_eq(
    Ok(col.slice(0, -1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  // Float column reaches the same start > end check.
  assert_true(
    (Ok(NumericColumn::from_floats([1.0, 2.0]).slice(1, 0)) catch {
      e => Err(e)
    })
    is Err(InvalidOperation(_)),
  )
}

///|
test "take: gathers per dtype, OOB reports first offender" {
  let i = NumericColumn::from_ints([10, 20, 30]).take([2, 0, 0])
  assert_eq(i.len(), 3)
  assert_eq(i.get(0), @types.Scalar::Int(30))
  assert_eq(i.get(1), @types.Scalar::Int(10))
  assert_eq(i.get(2), @types.Scalar::Int(10))
  let f = NumericColumn::from_floats([1.0, 2.0]).take([1, 0])
  assert_eq(f.get(0), @types.Scalar::Float(2.0))
  assert_eq(f.get(1), @types.Scalar::Float(1.0))
  // Empty index array → empty column, dtype preserved.
  let e = NumericColumn::from_floats([1.0]).take([])
  assert_true(e.is_empty())
  assert_eq(e.dtype(), @types.DataType::Float)
  // Out-of-bounds reports the first offending index.
  assert_eq(
    Ok(NumericColumn::from_ints([1, 2]).take([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(NumericColumn::from_ints([1, 2]).take([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── Materialise ───────────────────────────────────────────────────────

///|
test "to_builtin: equals from_ints / from_floats (the bitmap alloc avoided)" {
  let xs : Array[Int64] = [3, 1, 4, 1, 5]
  let widened_i = NumericColumn::from_ints(xs).to_builtin()
  // The numeric column carried no bitmap; widening materialises exactly the
  // all-valid Builtin column — this package's structural `Eq`
  // (`equality_wbtest.mbt`) proves it cell-for-cell.
  assert_eq(widened_i, BuiltinColumn::from_ints(xs))
  assert_eq(widened_i.null_count(), 0)
  let ys : Array[Double] = [2.0, 7.0, 1.0]
  let widened_f = NumericColumn::from_floats(ys).to_builtin()
  assert_eq(widened_f, BuiltinColumn::from_floats(ys))
  assert_eq(widened_f.dtype(), @types.DataType::Float)
  assert_eq(widened_f.null_count(), 0)
}

// ── Structural equality ───────────────────────────────────────────────

///|
test "structural equality: cell-wise, dtype-discriminated" {
  assert_eq(NumericColumn::from_ints([1, 2]), NumericColumn::from_ints([1, 2]))
  assert_not_eq(
    NumericColumn::from_ints([1, 2]),
    NumericColumn::from_ints([1, 3]),
  )
  assert_eq(
    NumericColumn::from_floats([1.0, 2.0]),
    NumericColumn::from_floats([1.0, 2.0]),
  )
  // Int-backed vs Float-backed differ in the NumericData arm.
  assert_not_eq(
    NumericColumn::from_ints([1, 2]),
    NumericColumn::from_floats([1.0, 2.0]),
  )
}

///|
test "from_ints / from_floats build equal columns from equal input" {
  assert_eq(NumericColumn::from_ints([1, 2]), NumericColumn::from_ints([1, 2]))
  assert_eq(
    NumericColumn::from_floats([1.5, 2.5]),
    NumericColumn::from_floats([1.5, 2.5]),
  )
  // The defensive copy again, on the equality path: mutating the caller's
  // array afterwards leaves the column unchanged.
  let values : Array[Int64] = [1, 2]
  let col = NumericColumn::from_ints(values)
  values.push(3)
  assert_eq(col, NumericColumn::from_ints([1, 2]))
}
