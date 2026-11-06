// ── cast (Int / Float / String) / to_string_column ──────────────────

///|
test "cast Int identity on Int" {
  // The identity is the cast entry's gate — the column returns before any
  // conversion dispatch (`to_int` no longer carries an identity arm).
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
  // The cast entry's identity gate again — `to_float` has no identity arm.
  let col = BuiltinColumn::from_floats([1.0, 2.0])
  assert_eq(col.cast(@types.DataType::Float), col)
}

///|
test "to_int / to_float answer a refusal where the identity arms lived" {
  // The cast entry owns same-dtype identity and refuses a non-numeric I64
  // rider before dispatching, so `to_int`'s `I64` arm and `to_float`'s
  // `F64` arm are unreachable through `cast` — they stay for
  // exhaustiveness and answer the entry's refusal, the same shape the
  // temporal casts' unreachable arms take. Reached here by direct call on
  // legal constructions (a rider column, an Int column, a Float column) —
  // the old identity arm would have handed the rider column back as
  // though it were an Int result.
  let days = BuiltinColumn::from_i64_options(@types.DataType::Date, [
    Some(19000L),
  ])
  assert_true((Ok(days.to_int()) catch { e => Err(e) }) is Err(Unsupported(_)))
  let ints = BuiltinColumn::from_int_options([Some(1)])
  assert_true((Ok(ints.to_int()) catch { e => Err(e) }) is Err(Unsupported(_)))
  let floats = BuiltinColumn::from_floats([1.5])
  assert_true(
    (Ok(floats.to_float()) catch { e => Err(e) }) is Err(Unsupported(_)),
  )
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

// ── Float -> String -> Float round-trip ──────────────────────────────

///|
/// Round-trip one `Double` through the cast path — `cast(String)` renders
/// the value form, `cast(Float)` parses it back — demanding bit equality
/// (`reinterpret_as_int64`), which `==` cannot promise for the zeros:
/// `-0.0 == 0.0` numerically while carrying a different bit form.
fn roundtrip_bits(x : Double) -> Int64 raise @types.DataError {
  let text = BuiltinColumn::from_floats([x]).cast(@types.DataType::String)
  let back = text.cast(@types.DataType::Float)
  match back.get(0) {
    @types.Scalar::Float(v) => v.reinterpret_as_int64()
    _ => abort("unreachable: the Float cast's cells are Float by construction")
  }
}

///|
test "float value-form rendering round-trips bit-exactly" {
  // 0.1 and its adjacent ulp up: each renders to its own shortest exact
  // text and parses back to the same bits — and the two strings differ,
  // so the pair cannot collapse into one value through the round trip.
  let near = (0.1.reinterpret_as_int64() + 1L).reinterpret_as_double()
  assert_eq(roundtrip_bits(0.1), 0.1.reinterpret_as_int64())
  assert_eq(roundtrip_bits(near), near.reinterpret_as_int64())
  // The first doubles past 2^53, where the integer text is 16 digits and
  // a naive renderer could round to 2^53: exact text, exact bits.
  let big = (0x4340_0000_0000_0000L + 2L).reinterpret_as_double()
  assert_eq(roundtrip_bits(big), big.reinterpret_as_int64())
  // The extremes of the format: the smallest normal (2^-1022) and the
  // smallest subnormal (5e-324), both through exponent-notation text.
  let min_normal = 0x0010_0000_0000_0000L.reinterpret_as_double()
  assert_eq(roundtrip_bits(min_normal), 0x0010_0000_0000_0000L)
  let min_subnormal = 1L.reinterpret_as_double()
  assert_eq(roundtrip_bits(min_subnormal), 1L)
}

///|
test "negative zero loses its sign through the value form" {
  // A recorded loss, not a round-trip claim: core documents
  // `(-0.0).to_string()` as `"0"`, so the value form carries no sign for
  // zero and the parse back lands on +0.0 — numerically equal (and equal
  // in the IEEE total order), bit-form different. Pinned here so a future
  // renderer change that preserves the sign turns this assert around.
  let back = roundtrip_bits(-0.0)
  assert_eq(back, 0L)
  assert_true((-0.0).reinterpret_as_int64() != back)
}
