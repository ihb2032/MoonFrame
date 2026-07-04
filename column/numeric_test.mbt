// Blackbox tests for the full `NumericColumn` (PLAN_v0.3.md §3 S1). The
// all-valid numeric backend has a real, testable difference from
// `BuiltinColumn`, not an empty abstraction:
//   • construction / sub-views store only the data array (no validity
//     `Bitmap`), so `null_count` is structural (`0`) with no popcount;
//   • reductions fold the raw array with no validity materialisation/branch;
//   • `to_builtin` widening is exactly `BuiltinColumn::from_ints` /
//     `from_floats` (the bitmap allocation the numeric path avoided), and is
//     value-preserving.
// Reductions inherit v0.2 / Polars NaN semantics: `NaN` propagates through
// `sum` / `mean` (it is a value, not missing) but is skipped by `min` /
// `max` (treated as missing, like `sort`).

// ── Construction + inspection ─────────────────────────────────────────

///|
test "from_int64s / from_doubles: structural all-valid, no bitmap" {
  let i = NumericColumn::from_int64s([10, 20, 30])
  assert_eq(i.len(), 3)
  assert_eq(i.dtype(), @types.DataType::Int)
  // null_count is 0 by construction — no validity buffer to consult.
  assert_eq(i.null_count(), 0)
  assert_false(i.is_empty())
  let f = NumericColumn::from_doubles([1.5, 2.5])
  assert_eq(f.len(), 2)
  assert_eq(f.dtype(), @types.DataType::Float)
  assert_eq(f.null_count(), 0)
  assert_false(f.is_empty())
  assert_true(NumericColumn::from_int64s([]).is_empty())
  assert_true(NumericColumn::from_doubles([]).is_empty())
}

///|
// Defensive copy: `from_int64s` / `from_doubles` copy their input, so the
// column is independent of the caller's array.
test "from_int64s / from_doubles copy their input" {
  let ints : Array[Int64] = [1, 2, 3]
  let ic = NumericColumn::from_int64s(ints)
  ints[0] = 99
  assert_eq(ic.get(0), @types.Scalar::Int(1))
  let flts : Array[Double] = [1.5, 2.5]
  let fc = NumericColumn::from_doubles(flts)
  flts[0] = 9.9
  assert_eq(fc.get(0), @types.Scalar::Float(1.5))
}

///|
test "data() exposes the shared raw array as ColumnData" {
  assert_eq(
    NumericColumn::from_int64s([1, 2, 3]).data(),
    ColumnData::Int([1, 2, 3]),
  )
  assert_eq(
    NumericColumn::from_doubles([1.0, 2.0]).data(),
    ColumnData::Float([1.0, 2.0]),
  )
}

// ── is_null / get ─────────────────────────────────────────────────────

///|
test "is_null: bounds check only, value structurally false" {
  let i = NumericColumn::from_int64s([7, 8])
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
  assert_false(NumericColumn::from_doubles([1.5]).is_null(0))
}

///|
test "get: reads value per dtype, OOB raises (no null branch)" {
  let i = NumericColumn::from_int64s([7, 8, 9])
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
  let f = NumericColumn::from_doubles([1.5, 2.5])
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
  let i = NumericColumn::from_int64s([10, 20, 30, 40]).slice(1, 3)
  assert_eq(i.len(), 2)
  assert_eq(i.null_count(), 0)
  assert_eq(i.get(0), @types.Scalar::Int(20))
  assert_eq(i.get(1), @types.Scalar::Int(30))
  let f = NumericColumn::from_doubles([1.0, 2.0, 3.0]).slice(0, 2)
  assert_eq(f.len(), 2)
  assert_eq(f.get(1), @types.Scalar::Float(2.0))
  // start == end → empty.
  assert_true(NumericColumn::from_int64s([1, 2, 3]).slice(2, 2).is_empty())
}

///|
test "slice: invalid bounds report the actual offender (Builtin check order)" {
  let col = NumericColumn::from_int64s([1, 2, 3])
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
  // Float column reaches the same start > end check.
  assert_true(
    (Ok(NumericColumn::from_doubles([1.0, 2.0]).slice(1, 0)) catch {
      e => Err(e)
    })
    is Err(InvalidOperation(_)),
  )
}

///|
test "take: gathers per dtype, OOB reports first offender" {
  let i = NumericColumn::from_int64s([10, 20, 30]).take([2, 0, 0])
  assert_eq(i.len(), 3)
  assert_eq(i.get(0), @types.Scalar::Int(30))
  assert_eq(i.get(1), @types.Scalar::Int(10))
  assert_eq(i.get(2), @types.Scalar::Int(10))
  let f = NumericColumn::from_doubles([1.0, 2.0]).take([1, 0])
  assert_eq(f.get(0), @types.Scalar::Float(2.0))
  assert_eq(f.get(1), @types.Scalar::Float(1.0))
  // Empty index array → empty column, dtype preserved.
  let e = NumericColumn::from_doubles([1.0]).take([])
  assert_true(e.is_empty())
  assert_eq(e.dtype(), @types.DataType::Float)
  // Out-of-bounds reports the first offending index.
  assert_eq(
    Ok(NumericColumn::from_int64s([1, 2]).take([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(NumericColumn::from_int64s([1, 2]).take([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── Typed accessors ───────────────────────────────────────────────────

///|
test "int_values / float_values: raw array + synthesised all-valid bitmap" {
  let (iv, ivalid) = NumericColumn::from_int64s([1, 2, 3]).int_values()
  assert_eq(iv, [1, 2, 3])
  // No stored bitmap — validity is synthesised all-valid, sized to the column.
  assert_eq(ivalid.to_bools(), [true, true, true])
  assert_eq(ivalid.null_count(), 0)
  let (fv, fvalid) = NumericColumn::from_doubles([1.5, 2.5]).float_values()
  assert_eq(fv, [(1.5 : Double), (2.5 : Double)])
  assert_eq(fvalid.to_bools(), [true, true])
}

///|
test "typed accessors reject the wrong dtype (numeric column has no Bool/String)" {
  let i = NumericColumn::from_int64s([1])
  let f = NumericColumn::from_doubles([1.0])
  // Cross-numeric mismatch.
  assert_true(
    (Ok(f.int_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(i.float_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  // bool_values / string_values always mismatch — it is numeric by
  // construction (both backing dtypes exercised).
  assert_true(
    (Ok(i.bool_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(f.bool_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(i.string_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(f.string_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
}

// ── Materialise ───────────────────────────────────────────────────────

///|
test "to_builtin: equals from_ints / from_floats (the bitmap alloc avoided)" {
  let xs : Array[Int64] = [3, 1, 4, 1, 5]
  let widened_i = NumericColumn::from_int64s(xs).to_builtin()
  // The numeric column carried no bitmap; widening materialises exactly the
  // all-valid Builtin column — `derive(Eq)` proves it cell-for-cell.
  assert_eq(widened_i, BuiltinColumn::from_ints(xs))
  assert_eq(widened_i.null_count(), 0)
  let ys : Array[Double] = [2.0, 7.0, 1.0]
  let widened_f = NumericColumn::from_doubles(ys).to_builtin()
  assert_eq(widened_f, BuiltinColumn::from_floats(ys))
  assert_eq(widened_f.dtype(), @types.DataType::Float)
  assert_eq(widened_f.null_count(), 0)
}

///|
test "to_string_column: renders each cell via the Builtin path" {
  assert_eq(
    NumericColumn::from_int64s([1, 2, -3]).to_string_column().data(),
    ColumnData::String(["1", "2", "-3"]),
  )
  let f = NumericColumn::from_doubles([1.5, 2.5]).to_string_column()
  assert_eq(f.dtype(), @types.DataType::String)
  assert_eq(f.null_count(), 0)
  // Agrees with widening first, then stringifying the Builtin column.
  assert_eq(f, BuiltinColumn::from_floats([1.5, 2.5]).to_string_column())
}

// ── Reductions: sum (all-valid fast path) ─────────────────────────────

///|
test "sum: folds raw array per dtype, total, identity on empty" {
  assert_eq(
    NumericColumn::from_int64s([1, 2, 3, 4]).sum(),
    @types.Scalar::Int(10),
  )
  // Empty → additive identity, no raise (unlike Series::sum on non-numeric).
  assert_eq(NumericColumn::from_int64s([]).sum(), @types.Scalar::Int(0))
  // Accumulates in Int64 — a sum past the 32-bit ceiling does not overflow.
  assert_eq(
    NumericColumn::from_int64s([2147483647, 2147483647, 2147483647]).sum(),
    @types.Scalar::Int(6442450941),
  )
  assert_eq(
    NumericColumn::from_doubles([1.5, 2.5, 4.0]).sum(),
    @types.Scalar::Float(8.0),
  )
  assert_eq(NumericColumn::from_doubles([]).sum(), @types.Scalar::Float(0.0))
}

///|
test "sum: Float NaN propagates (NaN is a value, not missing)" {
  let nan : Double = @double.not_a_number
  match NumericColumn::from_doubles([1.0, nan, 2.0]).sum() {
    @types.Scalar::Float(v) => assert_true(v.is_nan())
    _ => assert_true(false)
  }
}

///|
test "sum equals the widened BuiltinColumn's reduction (cross-check)" {
  // The numeric fast path must agree value-for-value with reducing the
  // materialised Builtin column over its valid cells.
  let xs : Array[Int64] = [5, -3, 8, 0, 12]
  let numeric_sum = NumericColumn::from_int64s(xs).sum()
  let (data, validity) = NumericColumn::from_int64s(xs)
    .to_builtin()
    .int_values()
  let valid = validity.to_bools()
  let mut acc : Int64 = 0
  for i in 0..<data.length() {
    if valid[i] {
      acc = acc + data[i]
    }
  }
  assert_eq(numeric_sum, @types.Scalar::Int(acc))
}

// ── Reductions: mean (raises on empty) ────────────────────────────────

///|
test "mean: arithmetic mean per dtype, as Double" {
  assert_eq(NumericColumn::from_int64s([1, 2, 3]).mean(), 2.0)
  assert_eq(NumericColumn::from_int64s([2, 4]).mean(), 3.0)
  assert_eq(NumericColumn::from_doubles([1.0, 2.0, 6.0]).mean(), 3.0)
}

///|
test "mean: large Int64 values accumulate in Double, no Int64 wrap" {
  // 2^62 + 2^62 = 2^63 wraps an Int64 accumulator to Int64::MIN; the mean must
  // remain 2^62 rather than flipping negative.
  let two_62 : Int64 = 4611686018427387904
  assert_eq(
    NumericColumn::from_int64s([two_62, two_62]).mean(),
    two_62.to_double(),
  )
}

///|
test "mean: empty column raises InvalidOperation (0/0 is undefined)" {
  assert_eq(
    Ok(NumericColumn::from_int64s([]).mean()) catch {
      e => Err(e)
    },
    Err(@types.DataError::InvalidOperation("mean of empty column")),
  )
  assert_eq(
    Ok(NumericColumn::from_doubles([]).mean()) catch {
      e => Err(e)
    },
    Err(@types.DataError::InvalidOperation("mean of empty column")),
  )
}

///|
test "mean: Float NaN propagates to a NaN mean" {
  let nan : Double = @double.not_a_number
  assert_true(NumericColumn::from_doubles([1.0, nan]).mean().is_nan())
}

// ── Reductions: min / max (skip NaN, total) ───────────────

///|
test "min / max: Int, both fold branches, empty → Null" {
  let col = NumericColumn::from_int64s([3, 1, 2])
  // min: None→Some(3); 1<3 replaces; 2<1 keeps — exercises both fold arms.
  assert_eq(col.min(), @types.Scalar::Int(1))
  assert_eq(col.max(), @types.Scalar::Int(3))
  // Empty column → Null on both reductions.
  assert_eq(NumericColumn::from_int64s([]).min(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_int64s([]).max(), @types.Scalar::Null)
}

///|
test "min / max: Float skips NaN, all-NaN / empty → Null" {
  let nan : Double = @double.not_a_number
  let col = NumericColumn::from_doubles([3.0, nan, 1.0, 2.0])
  // NaN is skipped (treated as missing), unlike sum / mean where it
  // propagates — exactly Polars' regular min / max.
  assert_eq(col.min(), @types.Scalar::Float(1.0))
  assert_eq(col.max(), @types.Scalar::Float(3.0))
  // Every cell skipped → Null (all-NaN, and empty).
  assert_eq(NumericColumn::from_doubles([nan, nan]).min(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_doubles([nan, nan]).max(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_doubles([]).min(), @types.Scalar::Null)
  assert_eq(NumericColumn::from_doubles([]).max(), @types.Scalar::Null)
}

// ── Eq derive ─────────────────────────────────────────────────────────

///|
test "Eq derive: structural, dtype-discriminated" {
  assert_eq(
    NumericColumn::from_int64s([1, 2]),
    NumericColumn::from_int64s([1, 2]),
  )
  assert_not_eq(
    NumericColumn::from_int64s([1, 2]),
    NumericColumn::from_int64s([1, 3]),
  )
  assert_eq(
    NumericColumn::from_doubles([1.0, 2.0]),
    NumericColumn::from_doubles([1.0, 2.0]),
  )
  // Int-backed vs Float-backed differ in the NumericData arm.
  assert_not_eq(
    NumericColumn::from_int64s([1, 2]),
    NumericColumn::from_doubles([1.0, 2.0]),
  )
}

///|
test "from_ints / from_floats alias the raw constructors" {
  assert_eq(
    NumericColumn::from_ints([1, 2]),
    NumericColumn::from_int64s([1, 2]),
  )
  assert_eq(
    NumericColumn::from_floats([1.5, 2.5]),
    NumericColumn::from_doubles([1.5, 2.5]),
  )
  // The alias inherits the defensive copy: mutating the caller's array
  // afterwards leaves the column unchanged.
  let values : Array[Int64] = [1, 2]
  let col = NumericColumn::from_ints(values)
  values.push(3)
  assert_eq(col, NumericColumn::from_int64s([1, 2]))
}
