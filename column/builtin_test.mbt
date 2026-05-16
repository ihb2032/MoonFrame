// Blackbox tests for `BuiltinColumn`. Only the public API is used.

// ── Constructors ─────────────────────────────────────────────────────

///|
test "from_ints / from_int_options" {
  let raw = BuiltinColumn::from_ints([1, 2, 3])
  assert_eq(raw.len(), 3)
  assert_eq(raw.dtype(), @types.DataType::Int)
  assert_eq(raw.null_count(), 0)
  let opt = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  assert_eq(opt.len(), 3)
  assert_eq(opt.null_count(), 1)
}

///|
test "from_floats / from_float_options" {
  let raw = BuiltinColumn::from_floats([1.5, 2.5])
  assert_eq(raw.dtype(), @types.DataType::Float)
  assert_eq(raw.null_count(), 0)
  let opt = BuiltinColumn::from_float_options([None, Some(1.0)])
  assert_eq(opt.null_count(), 1)
}

///|
test "from_bools / from_bool_options" {
  let raw = BuiltinColumn::from_bools([true, false, true])
  assert_eq(raw.dtype(), @types.DataType::Bool)
  let opt = BuiltinColumn::from_bool_options([Some(true), None, None])
  assert_eq(opt.null_count(), 2)
}

///|
test "from_strings / from_string_options" {
  let raw = BuiltinColumn::from_strings(["a", "b"])
  assert_eq(raw.dtype(), @types.DataType::String)
  let opt = BuiltinColumn::from_string_options([Some("x"), None])
  assert_eq(opt.len(), 2)
  assert_eq(opt.null_count(), 1)
}

///|
test "is_empty" {
  let empty = BuiltinColumn::from_ints([])
  assert_true(empty.is_empty())
  let non_empty = BuiltinColumn::from_ints([0])
  assert_false(non_empty.is_empty())
}

///|
test "structural equality compares cells, not identity" {
  assert_eq(BuiltinColumn::from_ints([1, 2]), BuiltinColumn::from_ints([1, 2]))
  assert_not_eq(
    BuiltinColumn::from_ints([1, 2]),
    BuiltinColumn::from_ints([1, 3]),
  )
  assert_not_eq(
    BuiltinColumn::from_int_options([Some(1), None]),
    BuiltinColumn::from_int_options([Some(1), Some(1)]),
  )
}

// ── is_null / get ────────────────────────────────────────────────────

///|
test "is_null returns Ok for in-bounds indices" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  assert_eq(col.is_null(0), Ok(false))
  assert_eq(col.is_null(1), Ok(true))
  assert_eq(col.is_null(2), Ok(false))
}

///|
test "is_null out-of-bounds is IndexOutOfBounds" {
  let col = BuiltinColumn::from_ints([1, 2])
  assert_eq(col.is_null(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(col.is_null(2), Err(@types.DataError::IndexOutOfBounds(2)))
}

///|
test "get returns Scalar or Null" {
  let col = BuiltinColumn::from_int_options([Some(7), None])
  assert_eq(col.get(0), Ok(@types.Scalar::Int(7)))
  assert_eq(col.get(1), Ok(@types.Scalar::Null))
}

///|
test "get out-of-bounds is IndexOutOfBounds" {
  let col = BuiltinColumn::from_ints([1])
  assert_eq(col.get(5), Err(@types.DataError::IndexOutOfBounds(5)))
}

///|
test "get covers every dtype" {
  assert_eq(
    BuiltinColumn::from_floats([1.5]).get(0),
    Ok(@types.Scalar::Float(1.5)),
  )
  assert_eq(
    BuiltinColumn::from_bools([true]).get(0),
    Ok(@types.Scalar::Bool(true)),
  )
  assert_eq(
    BuiltinColumn::from_strings(["x"]).get(0),
    Ok(@types.Scalar::String("x")),
  )
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice produces an independent sub-column" {
  let col = BuiltinColumn::from_ints([10, 20, 30, 40])
  let part = col.slice(1, 3).unwrap()
  assert_eq(part.len(), 2)
  assert_eq(part.get(0), Ok(@types.Scalar::Int(20)))
  assert_eq(part.get(1), Ok(@types.Scalar::Int(30)))
}

///|
test "slice with start == end is empty" {
  let col = BuiltinColumn::from_strings(["a", "b", "c"])
  let part = col.slice(2, 2).unwrap()
  assert_true(part.is_empty())
}

///|
test "slice full range equals self length" {
  let col = BuiltinColumn::from_bools([true, false])
  let part = col.slice(0, 2).unwrap()
  assert_eq(part.len(), 2)
}

///|
test "slice invalid bounds is IndexOutOfBounds" {
  let col = BuiltinColumn::from_ints([1, 2, 3])
  assert_true(col.slice(-1, 2) is Err(_))
  assert_true(col.slice(0, 5) is Err(_))
  assert_true(col.slice(2, 1) is Err(_))
}

// ── take ─────────────────────────────────────────────────────────────

///|
test "take gathers in arbitrary order, with duplicates" {
  let col = BuiltinColumn::from_strings(["a", "b", "c"])
  let out = col.take([2, 0, 0, 1]).unwrap()
  assert_eq(out.len(), 4)
  assert_eq(out.get(0), Ok(@types.Scalar::String("c")))
  assert_eq(out.get(1), Ok(@types.Scalar::String("a")))
  assert_eq(out.get(2), Ok(@types.Scalar::String("a")))
  assert_eq(out.get(3), Ok(@types.Scalar::String("b")))
}

///|
test "take with empty index array returns empty column" {
  let col = BuiltinColumn::from_floats([1.0, 2.0])
  let out = col.take([]).unwrap()
  assert_true(out.is_empty())
  assert_eq(out.dtype(), @types.DataType::Float)
}

///|
test "take preserves nulls" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let out = col.take([1, 0, 1]).unwrap()
  assert_eq(out.null_count(), 2)
  assert_eq(out.get(1), Ok(@types.Scalar::Int(1)))
}

///|
test "take out-of-bounds index reports first offender" {
  let col = BuiltinColumn::from_ints([1, 2])
  assert_eq(col.take([0, 5]), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_eq(col.take([-1]), Err(@types.DataError::IndexOutOfBounds(-1)))
}

// ── cast / to_int / to_float / to_string_column ─────────────────────

///|
test "to_int identity on Int" {
  let col = BuiltinColumn::from_int_options([Some(1), None])
  assert_eq(col.to_int(), Ok(col))
}

///|
test "to_int from Float truncates and preserves null" {
  let col = BuiltinColumn::from_float_options([Some(1.9), None, Some(-2.5)])
  let out = col.to_int().unwrap()
  assert_eq(out.dtype(), @types.DataType::Int)
  assert_eq(out.get(0), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1), Ok(@types.Scalar::Null))
  assert_eq(out.get(2), Ok(@types.Scalar::Int(-2)))
}

///|
test "to_int from Bool maps true/false to 1/0" {
  let col = BuiltinColumn::from_bool_options([Some(true), Some(false), None])
  let out = col.to_int().unwrap()
  assert_eq(out.get(0), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1), Ok(@types.Scalar::Int(0)))
  assert_eq(out.get(2), Ok(@types.Scalar::Null))
}

///|
test "to_int from String parses numerics, errors on garbage" {
  let ok = BuiltinColumn::from_string_options([Some("42"), None, Some("-7")])
  let out = ok.to_int().unwrap()
  assert_eq(out.get(0), Ok(@types.Scalar::Int(42)))
  assert_eq(out.get(1), Ok(@types.Scalar::Null))
  assert_eq(out.get(2), Ok(@types.Scalar::Int(-7)))
  let bad = BuiltinColumn::from_strings(["nope"])
  assert_true(bad.to_int() is Err(ParseError(_)))
}

///|
test "to_float promotes Int" {
  let col = BuiltinColumn::from_int_options([Some(3), None])
  let out = col.to_float().unwrap()
  assert_eq(out.dtype(), @types.DataType::Float)
  assert_eq(out.get(0), Ok(@types.Scalar::Float(3.0)))
  assert_eq(out.get(1), Ok(@types.Scalar::Null))
}

///|
test "to_float identity on Float" {
  let col = BuiltinColumn::from_floats([1.0, 2.0])
  assert_eq(col.to_float(), Ok(col))
}

///|
test "to_float from Bool" {
  let col = BuiltinColumn::from_bools([true, false])
  let out = col.to_float().unwrap()
  assert_eq(out.get(0), Ok(@types.Scalar::Float(1.0)))
  assert_eq(out.get(1), Ok(@types.Scalar::Float(0.0)))
}

///|
test "to_float from String parses, errors on garbage" {
  let ok = BuiltinColumn::from_strings(["1.5", "-2"])
  let out = ok.to_float().unwrap()
  assert_eq(out.get(0), Ok(@types.Scalar::Float(1.5)))
  assert_eq(out.get(1), Ok(@types.Scalar::Float(-2.0)))
  let bad = BuiltinColumn::from_strings(["nope"])
  assert_true(bad.to_float() is Err(ParseError(_)))
}

///|
test "to_string_column renders value-style for every dtype" {
  assert_eq(
    BuiltinColumn::from_int_options([Some(7), None])
    .to_string_column()
    .unwrap()
    .get(0),
    Ok(@types.Scalar::String("7")),
  )
  assert_eq(
    BuiltinColumn::from_floats([1.5]).to_string_column().unwrap().get(0),
    Ok(@types.Scalar::String("1.5")),
  )
  assert_eq(
    BuiltinColumn::from_bool_options([Some(true), Some(false), None])
    .to_string_column()
    .unwrap()
    .get(2),
    Ok(@types.Scalar::Null),
  )
  let s = BuiltinColumn::from_strings(["already"])
  assert_eq(s.to_string_column(), Ok(s))
}

///|
test "cast dispatches by dtype and rejects Bool / Null targets" {
  let col = BuiltinColumn::from_ints([1, 2, 3])
  assert_eq(col.cast(@types.DataType::Int), Ok(col))
  assert_eq(
    col.cast(@types.DataType::Float).unwrap().dtype(),
    @types.DataType::Float,
  )
  assert_eq(
    col.cast(@types.DataType::String).unwrap().dtype(),
    @types.DataType::String,
  )
  assert_true(col.cast(@types.DataType::Bool) is Err(Unsupported(_)))
  assert_true(col.cast(@types.DataType::Null) is Err(Unsupported(_)))
}

// ── typed accessors ──────────────────────────────────────────────────

///|
test "int_values returns the underlying array" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let arr = col.int_values().unwrap()
  assert_eq(arr.length(), 3)
  assert_eq(arr[0], Some(1))
  assert_eq(arr[1], None)
}

///|
test "float_values / bool_values / string_values happy path" {
  let f = BuiltinColumn::from_floats([1.0, 2.0]).float_values().unwrap()
  assert_eq(f.length(), 2)
  let b = BuiltinColumn::from_bools([true]).bool_values().unwrap()
  assert_eq(b[0], Some(true))
  let s = BuiltinColumn::from_strings(["x"]).string_values().unwrap()
  assert_eq(s[0], Some("x"))
}

///|
test "typed accessors reject the wrong dtype" {
  let col = BuiltinColumn::from_strings(["x"])
  assert_true(col.int_values() is Err(TypeMismatch(_)))
  assert_true(col.float_values() is Err(TypeMismatch(_)))
  assert_true(col.bool_values() is Err(TypeMismatch(_)))
  assert_true(
    BuiltinColumn::from_ints([1]).string_values() is Err(TypeMismatch(_)),
  )
}
