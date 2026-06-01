// Blackbox tests for `Series` (structural surface). Statistics live in
// `series_stats_test.mbt`.

// ── Constructors ─────────────────────────────────────────────────────

///|
test "new / from_builtin wrap an existing column" {
  let col = @column.BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let a = Series::new("age", col)
  let b = Series::from_builtin("age", col)
  assert_eq(a.name(), "age")
  assert_eq(a.dtype(), @types.DataType::Int)
  assert_eq(a.len(), 3)
  assert_eq(a.null_count(), 1)
  // `from_builtin` is purely a naming alias — the two values are equal.
  assert_eq(a, b)
}

///|
test "from_ints / from_int_options" {
  let raw = Series::from_ints("x", [1, 2, 3])
  assert_eq(raw.dtype(), @types.DataType::Int)
  assert_eq(raw.len(), 3)
  assert_eq(raw.null_count(), 0)
  let opt = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(opt.null_count(), 1)
  assert_eq(opt.get(1), @types.Scalar::Null)
}

///|
test "from_floats / from_float_options" {
  let raw = Series::from_floats("x", [1.5, 2.5])
  assert_eq(raw.dtype(), @types.DataType::Float)
  assert_eq(raw.null_count(), 0)
  let opt = Series::from_float_options("x", [None, Some(1.0)])
  assert_eq(opt.null_count(), 1)
}

///|
test "from_bools / from_bool_options" {
  let raw = Series::from_bools("flag", [true, false, true])
  assert_eq(raw.dtype(), @types.DataType::Bool)
  let opt = Series::from_bool_options("flag", [Some(true), None, None])
  assert_eq(opt.null_count(), 2)
}

///|
test "from_strings / from_string_options" {
  let raw = Series::from_strings("name", ["a", "b"])
  assert_eq(raw.dtype(), @types.DataType::String)
  let opt = Series::from_string_options("name", [Some("x"), None])
  assert_eq(opt.len(), 2)
  assert_eq(opt.null_count(), 1)
}

///|
test "structural equality compares name + storage" {
  assert_eq(Series::from_ints("a", [1, 2]), Series::from_ints("a", [1, 2]))
  // Same content, different name → not equal.
  assert_not_eq(Series::from_ints("a", [1, 2]), Series::from_ints("b", [1, 2]))
  // Same name, different content → not equal.
  assert_not_eq(Series::from_ints("a", [1, 2]), Series::from_ints("a", [1, 3]))
}

// ── Inspection ───────────────────────────────────────────────────────

///|
test "is_empty true on zero-length, false otherwise" {
  let empty = Series::from_ints("x", [])
  assert_true(empty.is_empty())
  assert_eq(empty.len(), 0)
  let one = Series::from_ints("x", [0])
  assert_false(one.is_empty())
}

///|
test "null_rate covers empty / no-null / mixed / all-null" {
  // Empty: 0 / 0 collapses to 0.0 (avoid NaN propagation).
  let empty = Series::from_int_options("x", [])
  assert_eq(empty.null_rate(), (0.0 : Double))
  // No nulls.
  let dense = Series::from_ints("x", [1, 2, 3, 4])
  assert_eq(dense.null_rate(), (0.0 : Double))
  // Mixed.
  let mixed = Series::from_int_options("x", [Some(1), None, Some(3), None])
  assert_eq(mixed.null_rate(), (0.5 : Double))
  // All-null.
  let all_null = Series::from_int_options("x", [None, None])
  assert_eq(all_null.null_rate(), (1.0 : Double))
}

///|
test "is_null returns the validity for in-bounds, IndexOutOfBounds otherwise" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(s.is_null(0), false)
  assert_eq(s.is_null(1), true)
  assert_eq(try? s.is_null(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(try? s.is_null(3), Err(@types.DataError::IndexOutOfBounds(3)))
}

///|
test "get returns Scalar / Null / IndexOutOfBounds" {
  let s = Series::from_int_options("x", [Some(7), None])
  assert_eq(s.get(0), @types.Scalar::Int(7))
  assert_eq(s.get(1), @types.Scalar::Null)
  assert_eq(try? s.get(5), Err(@types.DataError::IndexOutOfBounds(5)))
}

///|
test "storage exposes the underlying column unchanged" {
  let col = @column.BuiltinColumn::from_strings(["x", "y"])
  let s = Series::from_builtin("c", col)
  assert_eq(s.storage(), col)
}

// ── rename ───────────────────────────────────────────────────────────

///|
test "rename returns a new series with the new name, sharing storage" {
  let s = Series::from_ints("a", [1, 2])
  let r = s.rename("b")
  assert_eq(r.name(), "b")
  // Original unaffected.
  assert_eq(s.name(), "a")
  assert_eq(r.storage(), s.storage())
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-series preserving name + nulls" {
  let s = Series::from_int_options("x", [Some(10), None, Some(30), Some(40)])
  let part = s.slice(1, 3)
  assert_eq(part.name(), "x")
  assert_eq(part.len(), 2)
  assert_eq(part.get(0), @types.Scalar::Null)
  assert_eq(part.get(1), @types.Scalar::Int(30))
}

///|
test "slice bubbles column-level errors" {
  let s = Series::from_ints("x", [1, 2, 3])
  assert_eq(try? s.slice(-1, 2), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(try? s.slice(0, 5), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_true((try? s.slice(2, 1)) is Err(InvalidOperation(_)))
}

// ── take ─────────────────────────────────────────────────────────────

///|
test "take gathers with duplicates and preserves nulls" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  let out = s.take([2, 1, 0, 1])
  assert_eq(out.name(), "x")
  assert_eq(out.len(), 4)
  assert_eq(out.get(0), @types.Scalar::Int(3))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(3), @types.Scalar::Null)
}

///|
test "take with empty index array returns empty series" {
  let s = Series::from_ints("x", [1, 2])
  let out = s.take([])
  assert_true(out.is_empty())
  assert_eq(out.name(), "x")
  assert_eq(out.dtype(), @types.DataType::Int)
}

///|
test "take out-of-bounds reports the first offender" {
  let s = Series::from_ints("x", [1, 2])
  assert_eq(try? s.take([0, 5]), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_eq(try? s.take([-1]), Err(@types.DataError::IndexOutOfBounds(-1)))
}

// ── drop_nulls ───────────────────────────────────────────────────────

///|
test "drop_nulls removes every null, shrinking length" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None, Some(5)])
  let cleaned = s.drop_nulls()
  assert_eq(cleaned.name(), "x")
  assert_eq(cleaned.len(), 3)
  assert_eq(cleaned.null_count(), 0)
  assert_eq(cleaned.get(0), @types.Scalar::Int(1))
  assert_eq(cleaned.get(1), @types.Scalar::Int(3))
  assert_eq(cleaned.get(2), @types.Scalar::Int(5))
}

///|
test "drop_nulls is a no-op when there are no nulls" {
  let s = Series::from_ints("x", [1, 2, 3])
  let out = s.drop_nulls()
  assert_eq(out, s)
}

///|
test "drop_nulls on all-null produces an empty series" {
  let s = Series::from_int_options("x", [None, None])
  let out = s.drop_nulls()
  assert_eq(out.len(), 0)
  assert_eq(out.dtype(), @types.DataType::Int)
}

///|
test "drop_nulls on empty series returns empty series" {
  let s = Series::from_int_options("x", [])
  let out = s.drop_nulls()
  assert_true(out.is_empty())
}

// ── fill_null ────────────────────────────────────────────────────────

///|
test "fill_null on Int series fills nulls with the given Int" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None])
  let out = s.fill_null(@types.Scalar::Int(0))
  assert_eq(out.null_count(), 0)
  assert_eq(out.get(0), @types.Scalar::Int(1))
  assert_eq(out.get(1), @types.Scalar::Int(0))
  assert_eq(out.get(2), @types.Scalar::Int(3))
  assert_eq(out.get(3), @types.Scalar::Int(0))
}

///|
test "fill_null on Float series fills nulls with the given Float" {
  let s = Series::from_float_options("x", [None, Some(2.5)])
  let out = s.fill_null(@types.Scalar::Float(1.5))
  assert_eq(out.get(0), @types.Scalar::Float(1.5))
  assert_eq(out.get(1), @types.Scalar::Float(2.5))
}

///|
test "fill_null on Bool series fills nulls with the given Bool" {
  let s = Series::from_bool_options("x", [Some(true), None, None])
  let out = s.fill_null(@types.Scalar::Bool(false))
  assert_eq(out.get(0), @types.Scalar::Bool(true))
  assert_eq(out.get(1), @types.Scalar::Bool(false))
  assert_eq(out.get(2), @types.Scalar::Bool(false))
}

///|
test "fill_null on String series fills nulls with the given String" {
  let s = Series::from_string_options("x", [Some("a"), None])
  let out = s.fill_null(@types.Scalar::String("z"))
  assert_eq(out.get(0), @types.Scalar::String("a"))
  assert_eq(out.get(1), @types.Scalar::String("z"))
}

///|
test "fill_null rejects Scalar::Null fill values" {
  let s = Series::from_int_options("x", [Some(1), None])
  assert_true((try? s.fill_null(@types.Scalar::Null)) is Err(TypeMismatch(_)))
}

///|
test "fill_null rejects dtype-mismatched Int fill" {
  let s = Series::from_floats("x", [1.0])
  assert_true((try? s.fill_null(@types.Scalar::Int(0))) is Err(TypeMismatch(_)))
}

///|
test "fill_null rejects dtype-mismatched Float fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (try? s.fill_null(@types.Scalar::Float(0.0))) is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched Bool fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (try? s.fill_null(@types.Scalar::Bool(true))) is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched String fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (try? s.fill_null(@types.Scalar::String("z"))) is Err(TypeMismatch(_)),
  )
}

// ── cast / to_int / to_float / to_string_series ──────────────────────

///|
test "cast dispatches by target dtype" {
  let s = Series::from_ints("x", [1, 2, 3])
  assert_eq(s.cast(@types.DataType::Int).dtype(), @types.DataType::Int)
  assert_eq(s.cast(@types.DataType::Float).dtype(), @types.DataType::Float)
  assert_eq(s.cast(@types.DataType::String).dtype(), @types.DataType::String)
  assert_true((try? s.cast(@types.DataType::Bool)) is Err(Unsupported(_)))
  assert_true((try? s.cast(@types.DataType::Null)) is Err(Unsupported(_)))
}

///|
test "to_int identity / Float→Int / Bool→Int / String→Int" {
  let i = Series::from_ints("x", [1, 2])
  assert_eq(i.to_int(), i)
  let f = Series::from_floats("x", [1.5, 2.7])
  let f_to_i = f.to_int()
  assert_eq(f_to_i.get(0), @types.Scalar::Int(1))
  let b = Series::from_bools("x", [true, false])
  let b_to_i = b.to_int()
  assert_eq(b_to_i.get(0), @types.Scalar::Int(1))
  assert_eq(b_to_i.get(1), @types.Scalar::Int(0))
  let bad = Series::from_strings("x", ["nope"])
  assert_true((try? bad.to_int()) is Err(ParseError(_)))
}

///|
test "to_float identity / Int→Float / Bool→Float / String→Float" {
  let f = Series::from_floats("x", [1.0])
  assert_eq(f.to_float(), f)
  let i = Series::from_ints("x", [3])
  assert_eq(i.to_float().get(0), @types.Scalar::Float(3.0))
  let b = Series::from_bools("x", [true, false])
  let b_to_f = b.to_float()
  assert_eq(b_to_f.get(0), @types.Scalar::Float(1.0))
  assert_eq(b_to_f.get(1), @types.Scalar::Float(0.0))
  let bad = Series::from_strings("x", ["x"])
  assert_true((try? bad.to_float()) is Err(ParseError(_)))
}

///|
test "to_string_series renders value-style across dtypes" {
  let i = Series::from_int_options("x", [Some(7), None])
  let s_i = i.to_string_series()
  assert_eq(s_i.get(0), @types.Scalar::String("7"))
  assert_eq(s_i.get(1), @types.Scalar::Null)
  let f = Series::from_floats("x", [1.5])
  assert_eq(f.to_string_series().get(0), @types.Scalar::String("1.5"))
  let b = Series::from_bools("x", [true, false])
  let s_b = b.to_string_series()
  assert_eq(s_b.get(0), @types.Scalar::String("true"))
  assert_eq(s_b.get(1), @types.Scalar::String("false"))
  let s = Series::from_strings("x", ["already"])
  assert_eq(s.to_string_series(), s)
}
