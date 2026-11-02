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
  // A finite literal past the Double range collapses to a signed Infinity
  // (IEEE 754), matching the explicit `inf` literal — not a ParseError.
  let huge = BuiltinColumn::from_strings(["1e999", "-1e999"]).cast(
    @types.DataType::Float,
  )
  assert_eq(huge.get(0), @types.Scalar::Float(@double.infinity))
  assert_eq(huge.get(1), @types.Scalar::Float(@double.neg_infinity))
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

// ── Date ↔ Timestamp casts ──────────────────────────────────────────

///|
test "cast Timestamp from Date scales day counts to microseconds" {
  let col = BuiltinColumn::from_i64_options(@types.DataType::Date, [
    Some(0L),
    None,
    Some(1L),
    Some(-1L),
  ])
  let out = col.cast(@types.DataType::Timestamp)
  assert_eq(out.dtype(), @types.DataType::Timestamp)
  assert_eq(out.get(0), @types.Scalar::Timestamp(0L))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::Timestamp(86_400_000_000L))
  assert_eq(out.get(3), @types.Scalar::Timestamp(-86_400_000_000L))
}

///|
test "cast Timestamp from Date refuses a day count whose instant overflows" {
  let hostile = BuiltinColumn::from_i64_options(@types.DataType::Date, [
    Some(9_223_372_036_854_775_807L),
  ])
  assert_true(
    (Ok(hostile.cast(@types.DataType::Timestamp)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast Date from Timestamp floors microsecond counts to whole days" {
  let col = BuiltinColumn::from_i64_options(@types.DataType::Timestamp, [
    Some(0L),
    None,
    Some(86_399_999_999L), // one microsecond before a full day: still day 0
    Some(86_400_000_000L),
    Some(-1L), // one microsecond before the epoch: 1969-12-31
  ])
  let out = col.cast(@types.DataType::Date)
  assert_eq(out.dtype(), @types.DataType::Date)
  assert_eq(out.get(0), @types.Scalar::Date(0L))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(2), @types.Scalar::Date(0L))
  assert_eq(out.get(3), @types.Scalar::Date(1L))
  assert_eq(out.get(4), @types.Scalar::Date(-1L))
}

///|
test "the Date ↔ Timestamp casts round-trip a calendar date" {
  let days = BuiltinColumn::from_i64_options(@types.DataType::Date, [
    Some(11016L),
    Some(-719_162L), // 0001-01-01
    Some(2_932_896L), // 9999-12-31
  ])
  let back = days.cast(@types.DataType::Timestamp).cast(@types.DataType::Date)
  assert_eq(back.get(0), @types.Scalar::Date(11016L))
  assert_eq(back.get(1), @types.Scalar::Date(-719_162L))
  assert_eq(back.get(2), @types.Scalar::Date(2_932_896L))
}

///|
test "the temporal casts refuse a construction the invariants rule out" {
  // A `Date` / `Timestamp` dtype welded to a `Bool` buffer cannot occur
  // through any constructor (the dtype/buffer agreement is
  // constructor-guaranteed); the casts' unreachable arms still answer a
  // refusal rather than misreading the buffer.
  let bool_col = BuiltinColumn::from_bools([true])
  let bogus_date : BuiltinColumn = BuiltinColumn::{
    dtype: @types.DataType::Date,
    data: bool_col.data,
    validity: bool_col.validity,
  }
  assert_true(
    (Ok(bogus_date.cast(@types.DataType::Timestamp)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
  let bogus_ts : BuiltinColumn = BuiltinColumn::{
    dtype: @types.DataType::Timestamp,
    data: bool_col.data,
    validity: bool_col.validity,
  }
  assert_true(
    (Ok(bogus_ts.cast(@types.DataType::Date)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
}
