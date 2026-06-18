// Blackbox tests for `BuiltinColumn` (Arrow layout). Only the public API
// is used; the `data` and `validity` fields are observed indirectly via
// `int_values` / `float_values` / `bool_values` / `string_values`.

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
test "structural equality compares data and validity, not identity" {
  assert_eq(BuiltinColumn::from_ints([1, 2]), BuiltinColumn::from_ints([1, 2]))
  assert_not_eq(
    BuiltinColumn::from_ints([1, 2]),
    BuiltinColumn::from_ints([1, 3]),
  )
  // Two columns with the same data but different validity must not be equal.
  assert_not_eq(
    BuiltinColumn::from_int_options([Some(1), None]),
    BuiltinColumn::from_int_options([Some(1), Some(1)]),
  )
}

// ── is_null / get ────────────────────────────────────────────────────

///|
test "is_null returns the validity for in-bounds indices" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  assert_eq(col.is_null(0), false)
  assert_eq(col.is_null(1), true)
  assert_eq(col.is_null(2), false)
}

///|
test "is_null out-of-bounds is IndexOutOfBounds" {
  let col = BuiltinColumn::from_ints([1, 2])
  assert_eq(
    Ok(col.is_null(-1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(col.is_null(2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(2)),
  )
}

///|
test "get returns Scalar or Null" {
  let col = BuiltinColumn::from_int_options([Some(7), None])
  assert_eq(col.get(0), @types.Scalar::Int(7))
  assert_eq(col.get(1), @types.Scalar::Null)
}

///|
test "get out-of-bounds is IndexOutOfBounds" {
  let col = BuiltinColumn::from_ints([1])
  assert_eq(
    Ok(col.get(5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
}

///|
test "get covers every dtype" {
  assert_eq(BuiltinColumn::from_floats([1.5]).get(0), @types.Scalar::Float(1.5))
  assert_eq(BuiltinColumn::from_bools([true]).get(0), @types.Scalar::Bool(true))
  assert_eq(
    BuiltinColumn::from_strings(["x"]).get(0),
    @types.Scalar::String("x"),
  )
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice produces an independent sub-column" {
  let col = BuiltinColumn::from_ints([10, 20, 30, 40])
  let part = col.slice(1, 3)
  assert_eq(part.len(), 2)
  assert_eq(part.get(0), @types.Scalar::Int(20))
  assert_eq(part.get(1), @types.Scalar::Int(30))
}

///|
test "slice with start == end is empty" {
  let col = BuiltinColumn::from_strings(["a", "b", "c"])
  let part = col.slice(2, 2)
  assert_true(part.is_empty())
}

///|
test "slice full range equals self length" {
  let col = BuiltinColumn::from_bools([true, false])
  let part = col.slice(0, 2)
  assert_eq(part.len(), 2)
}

///|
test "slice invalid bounds report the actual offender" {
  let col = BuiltinColumn::from_ints([1, 2, 3])
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
}

// ── take ─────────────────────────────────────────────────────────────

///|
test "take gathers in arbitrary order, with duplicates" {
  let col = BuiltinColumn::from_strings(["a", "b", "c"])
  let out = col.take([2, 0, 0, 1])
  assert_eq(out.len(), 4)
  assert_eq(out.get(0), @types.Scalar::String("c"))
  assert_eq(out.get(1), @types.Scalar::String("a"))
  assert_eq(out.get(2), @types.Scalar::String("a"))
  assert_eq(out.get(3), @types.Scalar::String("b"))
}

///|
test "take with empty index array returns empty column" {
  let col = BuiltinColumn::from_floats([1.0, 2.0])
  let out = col.take([])
  assert_true(out.is_empty())
  assert_eq(out.dtype(), @types.DataType::Float)
}

///|
test "take preserves nulls" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let out = col.take([1, 0, 1])
  assert_eq(out.null_count(), 2)
  assert_eq(out.get(1), @types.Scalar::Int(1))
}

///|
test "take out-of-bounds index reports first offender" {
  let col = BuiltinColumn::from_ints([1, 2])
  assert_eq(
    Ok(col.take([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(col.take([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── cast (Int / Float / String) / to_string_column ──────────────────

///|
test "cast Int identity on Int" {
  let col = BuiltinColumn::from_int_options([Some(1), None])
  assert_eq(col.cast(@types.DataType::Int), col)
}

///|
test "cast Int from Float truncates and preserves null" {
  let col = BuiltinColumn::from_float_options([Some(1.9), None, Some(-2.5)])
  let out = col.cast(@types.DataType::Int)
  assert_eq(out.dtype(), @types.DataType::Int)
  assert_eq(out.get(0), @types.Scalar::Int(1))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::Int(-2))
}

///|
test "cast Int from Bool maps true/false to 1/0" {
  let col = BuiltinColumn::from_bool_options([Some(true), Some(false), None])
  let out = col.cast(@types.DataType::Int)
  assert_eq(out.get(0), @types.Scalar::Int(1))
  assert_eq(out.get(1), @types.Scalar::Int(0))
  assert_eq(out.get(2), @types.Scalar::Null)
}

///|
test "cast Int from String parses numerics, errors on garbage" {
  let ok = BuiltinColumn::from_string_options([Some("42"), None, Some("-7")])
  let out = ok.cast(@types.DataType::Int)
  assert_eq(out.get(0), @types.Scalar::Int(42))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::Int(-7))
  let bad = BuiltinColumn::from_strings(["nope"])
  assert_true(
    (Ok(bad.cast(@types.DataType::Int)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast Float promotes Int" {
  let col = BuiltinColumn::from_int_options([Some(3), None])
  let out = col.cast(@types.DataType::Float)
  assert_eq(out.dtype(), @types.DataType::Float)
  assert_eq(out.get(0), @types.Scalar::Float(3.0))
  assert_eq(out.get(1), @types.Scalar::Null)
}

///|
test "cast Float identity on Float" {
  let col = BuiltinColumn::from_floats([1.0, 2.0])
  assert_eq(col.cast(@types.DataType::Float), col)
}

///|
test "cast Float from Bool" {
  let col = BuiltinColumn::from_bools([true, false])
  let out = col.cast(@types.DataType::Float)
  assert_eq(out.get(0), @types.Scalar::Float(1.0))
  assert_eq(out.get(1), @types.Scalar::Float(0.0))
}

///|
test "cast Float from String parses, errors on garbage" {
  let ok = BuiltinColumn::from_strings(["1.5", "-2"])
  let out = ok.cast(@types.DataType::Float)
  assert_eq(out.get(0), @types.Scalar::Float(1.5))
  assert_eq(out.get(1), @types.Scalar::Float(-2.0))
  let bad = BuiltinColumn::from_strings(["nope"])
  assert_true(
    (Ok(bad.cast(@types.DataType::Float)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "to_string_column renders value-style for every dtype" {
  assert_eq(
    BuiltinColumn::from_int_options([Some(7), None]).to_string_column().get(0),
    @types.Scalar::String("7"),
  )
  assert_eq(
    BuiltinColumn::from_floats([1.5]).to_string_column().get(0),
    @types.Scalar::String("1.5"),
  )
  assert_eq(
    BuiltinColumn::from_bool_options([Some(true), Some(false), None])
    .to_string_column()
    .get(2),
    @types.Scalar::Null,
  )
  let s = BuiltinColumn::from_strings(["already"])
  assert_eq(s.to_string_column(), s)
}

///|
test "cast dispatches by dtype and rejects Bool / Null targets" {
  let col = BuiltinColumn::from_ints([1, 2, 3])
  assert_eq(col.cast(@types.DataType::Int), col)
  assert_eq(col.cast(@types.DataType::Float).dtype(), @types.DataType::Float)
  assert_eq(col.cast(@types.DataType::String).dtype(), @types.DataType::String)
  assert_true(
    (Ok(col.cast(@types.DataType::Bool)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
  assert_true(
    (Ok(col.cast(@types.DataType::Null)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
}

// ── typed accessors ──────────────────────────────────────────────────

///|
test "int_values returns (data, validity); placeholders at null slots are 0" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let (data, validity) = col.int_values()
  // The data buffer is dense — null slot uses the per-dtype placeholder (0).
  assert_eq(data, [1, 0, 3])
  assert_eq(validity.len(), 3)
  assert_eq(validity.is_valid(0), true)
  assert_eq(validity.is_valid(1), false)
  assert_eq(validity.is_valid(2), true)
}

///|
test "float_values / bool_values / string_values happy path" {
  let (f, _) = BuiltinColumn::from_floats([1.0, 2.0]).float_values()
  assert_eq(f.length(), 2)
  let (b, _) = BuiltinColumn::from_bools([true]).bool_values()
  assert_eq(b[0], true)
  let (s, _) = BuiltinColumn::from_strings(["x"]).string_values()
  assert_eq(s[0], "x")
}

///|
test "typed accessors reject the wrong dtype" {
  let col = BuiltinColumn::from_strings(["x"])
  assert_true(
    (Ok(col.int_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(col.float_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(col.bool_values()) catch { e => Err(e) }) is Err(TypeMismatch(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_ints([1]).string_values()) catch { e => Err(e) })
    is Err(TypeMismatch(_)),
  )
}

// ── coverage fill: per-dtype is_null / get null branches ─────────────

///|
test "is_null covers Float, Bool, and String columns" {
  let f = BuiltinColumn::from_float_options([Some(1.5), None])
  assert_eq(f.is_null(0), false)
  assert_eq(f.is_null(1), true)
  let b = BuiltinColumn::from_bool_options([Some(true), None])
  assert_eq(b.is_null(0), false)
  assert_eq(b.is_null(1), true)
  let s = BuiltinColumn::from_string_options([None, Some("ok")])
  assert_eq(s.is_null(0), true)
  assert_eq(s.is_null(1), false)
}

///|
test "get null branch fires on every dtype" {
  assert_eq(BuiltinColumn::from_int_options([None]).get(0), @types.Scalar::Null)
  assert_eq(
    BuiltinColumn::from_float_options([None]).get(0),
    @types.Scalar::Null,
  )
  assert_eq(
    BuiltinColumn::from_bool_options([None]).get(0),
    @types.Scalar::Null,
  )
  assert_eq(
    BuiltinColumn::from_string_options([None]).get(0),
    @types.Scalar::Null,
  )
}

// ── coverage fill: slice / take across every dtype ───────────────────

///|
test "slice produces a sub-column for every dtype" {
  let i = BuiltinColumn::from_ints([1, 2, 3, 4]).slice(1, 3)
  assert_eq(i.get(0), @types.Scalar::Int(2))
  assert_eq(i.get(1), @types.Scalar::Int(3))
  let f = BuiltinColumn::from_floats([1.0, 2.0, 3.0]).slice(0, 2)
  assert_eq(f.len(), 2)
  assert_eq(f.get(1), @types.Scalar::Float(2.0))
  let b = BuiltinColumn::from_bools([true, false, true]).slice(1, 3)
  assert_eq(b.get(0), @types.Scalar::Bool(false))
  assert_eq(b.get(1), @types.Scalar::Bool(true))
  let s = BuiltinColumn::from_strings(["a", "b", "c", "d"]).slice(1, 4)
  assert_eq(s.len(), 3)
  assert_eq(s.get(0), @types.Scalar::String("b"))
  assert_eq(s.get(2), @types.Scalar::String("d"))
}

///|
test "take gathers across every dtype" {
  let i = BuiltinColumn::from_ints([10, 20, 30]).take([2, 0])
  assert_eq(i.get(0), @types.Scalar::Int(30))
  assert_eq(i.get(1), @types.Scalar::Int(10))
  let f = BuiltinColumn::from_float_options([Some(1.0), None, Some(3.0)]).take([
    1, 2, 0,
  ])
  assert_eq(f.get(0), @types.Scalar::Null)
  assert_eq(f.get(1), @types.Scalar::Float(3.0))
  assert_eq(f.get(2), @types.Scalar::Float(1.0))
  let b = BuiltinColumn::from_bools([true, false]).take([1, 0, 1])
  assert_eq(b.get(0), @types.Scalar::Bool(false))
  assert_eq(b.get(2), @types.Scalar::Bool(false))
  let s = BuiltinColumn::from_strings(["x", "y"]).take([0])
  assert_eq(s.get(0), @types.Scalar::String("x"))
}

// ── coverage fill: cast None paths ───────────────────────────────────

///|
test "cast Float preserves None across every supported source" {
  let from_bool = BuiltinColumn::from_bool_options([
    Some(true),
    None,
    Some(false),
  ]).cast(@types.DataType::Float)
  assert_eq(from_bool.get(0), @types.Scalar::Float(1.0))
  assert_eq(from_bool.get(1), @types.Scalar::Null)
  assert_eq(from_bool.get(2), @types.Scalar::Float(0.0))
  let from_string = BuiltinColumn::from_string_options([
    Some("1.5"),
    None,
    Some("-2"),
  ]).cast(@types.DataType::Float)
  assert_eq(from_string.get(0), @types.Scalar::Float(1.5))
  assert_eq(from_string.get(1), @types.Scalar::Null)
  assert_eq(from_string.get(2), @types.Scalar::Float(-2.0))
}

///|
test "to_string_column preserves None for Float" {
  let out = BuiltinColumn::from_float_options([Some(1.5), None]).to_string_column()
  assert_eq(out.get(0), @types.Scalar::String("1.5"))
  assert_eq(out.get(1), @types.Scalar::Null)
}

// ── Float -> Int cast: NaN / Inf / range guarded ─────────────────────

///|
test "cast Int rejects NaN" {
  let nan : Double = @double.not_a_number
  let col = BuiltinColumn::from_floats([nan])
  assert_true(
    (Ok(col.cast(@types.DataType::Int)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast Int rejects positive and negative Infinity" {
  let pos_inf : Double = @double.infinity
  let neg_inf : Double = @double.neg_infinity
  assert_true(
    (Ok(BuiltinColumn::from_floats([pos_inf]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_floats([neg_inf]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
}

///|
test "cast Int rejects values outside the Int range" {
  let too_big : Double = 1.0e30
  let too_small : Double = -1.0e30
  assert_true(
    (Ok(BuiltinColumn::from_floats([too_big]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_floats([too_small]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
}

///|
test "cast Int from Float skips None and truncates valid cells" {
  let col = BuiltinColumn::from_float_options([Some(1.9), None, Some(-2.5)])
  let out = col.cast(@types.DataType::Int)
  assert_eq(out.get(0), @types.Scalar::Int(1))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::Int(-2))
}

// ── String -> numeric parse strictness ───────────────────────────────

///|
test "cast Int rejects malformed strings" {
  assert_true(
    (Ok(BuiltinColumn::from_strings(["42abc"]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_strings([""]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_strings(["  42"]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
}

///|
test "cast Float rejects malformed strings" {
  assert_true(
    (Ok(BuiltinColumn::from_strings(["1.5x"]).cast(@types.DataType::Float)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_strings([""]).cast(@types.DataType::Float)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
}

///|
test "cast Int rejects base prefixes and underscore grouping" {
  // `@string.parse_int` defaults to base=0 and would accept these; the
  // cast screens them out so it agrees with CSV inference, which keeps
  // `0xFF` / `1_000` as String.
  assert_true(
    (Ok(BuiltinColumn::from_strings(["0xFF"]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_strings(["0o17"]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_strings(["0b101"]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  assert_true(
    (Ok(BuiltinColumn::from_strings(["1_000"]).cast(@types.DataType::Int)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
}

///|
test "cast Int rejects decimal integers overflowing Int64" {
  // Passes the decimal-literal screen but overflows `@string.parse_int64`,
  // exercising the parse-failure branch after the screen.
  assert_true(
    (Ok(
      BuiltinColumn::from_strings(["99999999999999999999"]).cast(
        @types.DataType::Int,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
}

///|
test "cast Float rejects underscore grouping but keeps scientific notation" {
  assert_true(
    (Ok(BuiltinColumn::from_strings(["1_000"]).cast(@types.DataType::Float)) catch {
      e => Err(e)
    })
    is Err(ParseError(_)),
  )
  // No underscore → still parsed; scientific notation is unaffected.
  let out = BuiltinColumn::from_strings(["1e3"]).cast(@types.DataType::Float)
  assert_eq(out.get(0), @types.Scalar::Float(1000.0))
}

// ── Arrow layout invariants ──────────────────────────────────────────

///|
test "from_int_options stores 0 placeholder at null slots" {
  let col = BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  let (data, validity) = col.int_values()
  assert_eq(data, [1, 0, 3])
  assert_eq(validity.is_valid(0), true)
  assert_eq(validity.is_valid(1), false)
  assert_eq(validity.is_valid(2), true)
}

///|
test "from_float_options stores 0.0 placeholder at null slots" {
  let col = BuiltinColumn::from_float_options([None, Some(2.5)])
  let (data, validity) = col.float_values()
  assert_eq(data, [(0.0 : Double), (2.5 : Double)])
  assert_eq(validity.is_valid(0), false)
  assert_eq(validity.is_valid(1), true)
}

///|
test "from_bool_options stores false placeholder at null slots" {
  let col = BuiltinColumn::from_bool_options([Some(true), None])
  let (data, validity) = col.bool_values()
  assert_eq(data, [true, false])
  assert_eq(validity.is_valid(1), false)
}

///|
test "from_string_options stores \"\" placeholder at null slots" {
  let col = BuiltinColumn::from_string_options([None, Some("hi")])
  let (data, validity) = col.string_values()
  assert_eq(data, ["", "hi"])
  assert_eq(validity.is_valid(0), false)
  assert_eq(validity.is_valid(1), true)
}

///|
test "data buffer length matches validity length for every constructor" {
  // Raw constructors → all-valid bitmap of the right length.
  let raw_i = BuiltinColumn::from_ints([1, 2, 3, 4, 5])
  let (data, validity) = raw_i.int_values()
  assert_eq(data.length(), 5)
  assert_eq(validity.len(), 5)
  assert_eq(validity.null_count(), 0)
  // Option constructors → validity reflects the Some/None mask exactly.
  let opt = BuiltinColumn::from_int_options([Some(1), None, Some(3), None])
  let (d2, v2) = opt.int_values()
  assert_eq(d2.length(), 4)
  assert_eq(v2.len(), 4)
  assert_eq(v2.null_count(), 2)
}

///|
test "cast Int -> Float preserves the validity bitmap" {
  let col = BuiltinColumn::from_int_options([
    Some(1),
    None,
    Some(3),
    None,
    Some(5),
  ])
  let out = col.cast(@types.DataType::Float)
  // Validity is unchanged across the cast.
  let (_, src_validity) = col.int_values()
  let (_, dst_validity) = out.float_values()
  assert_eq(src_validity, dst_validity)
  // And the null slots in the output read as Null, not 0.0.
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(3), @types.Scalar::Null)
}

///|
test "cast Bool -> Int and Bool -> Float preserve validity" {
  let col = BuiltinColumn::from_bool_options([
    Some(true),
    None,
    Some(false),
    None,
  ])
  let as_int = col.cast(@types.DataType::Int)
  assert_eq(as_int.null_count(), 2)
  assert_eq(as_int.get(0), @types.Scalar::Int(1))
  assert_eq(as_int.get(2), @types.Scalar::Int(0))
  let as_float = col.cast(@types.DataType::Float)
  assert_eq(as_float.null_count(), 2)
  assert_eq(as_float.get(0), @types.Scalar::Float(1.0))
}

///|
test "to_string_column on Int with nulls preserves validity" {
  let col = BuiltinColumn::from_int_options([Some(7), None, Some(-3)])
  let out = col.to_string_column()
  assert_eq(out.null_count(), 1)
  assert_eq(out.get(0), @types.Scalar::String("7"))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::String("-3"))
}

///|
test "to_string_column on Bool with nulls preserves validity" {
  let col = BuiltinColumn::from_bool_options([Some(true), None, Some(false)])
  let out = col.to_string_column()
  assert_eq(out.get(0), @types.Scalar::String("true"))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::String("false"))
}

///|
test "slice preserves nulls in the sub-window" {
  let col = BuiltinColumn::from_int_options([
    Some(1),
    None,
    Some(3),
    None,
    Some(5),
  ])
  let part = col.slice(1, 4)
  assert_eq(part.len(), 3)
  assert_eq(part.null_count(), 2)
  assert_eq(part.get(0), @types.Scalar::Null)
  assert_eq(part.get(1), @types.Scalar::Int(3))
  assert_eq(part.get(2), @types.Scalar::Null)
}

///|
test "cast Int from String skips null slots without parsing the placeholder" {
  // The placeholder for null String slots is "" (empty), which is itself
  // unparseable as an Int. The cast must short-circuit on null so the
  // placeholder is never parsed.
  let col = BuiltinColumn::from_string_options([None, Some("42")])
  let out = col.cast(@types.DataType::Int)
  assert_eq(out.get(0), @types.Scalar::Null)
  assert_eq(out.get(1), @types.Scalar::Int(42))
}

///|
test "cast Float from String skips null slots without parsing the placeholder" {
  let col = BuiltinColumn::from_string_options([None, Some("1.5")])
  let out = col.cast(@types.DataType::Float)
  assert_eq(out.get(0), @types.Scalar::Null)
  assert_eq(out.get(1), @types.Scalar::Float(1.5))
}
