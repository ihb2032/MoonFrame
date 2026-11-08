// Coverage pins for the decimal cast bridges — exercised through the
// package's own `BuiltinColumn::cast`, because the coverage gate counts
// a line only inside its owning package.

///|
test "the decimal casts cross every buffer, refusals included" {
  // Float -> Decimal (the correctly-rounded conversion).
  let f = BuiltinColumn::from_floats([1.5, -0.5])
  let as_dec = f.cast(@types.DataType::Decimal)
  assert_true(
    as_dec.get(0) is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::parse_opt("1.5").unwrap()),
  )
  // Int -> Decimal exact, Bool -> Decimal refuses, the same-dtype cast
  // is the identity gate.
  let i = BuiltinColumn::from_ints([7])
  let from_int = i.cast(@types.DataType::Decimal)
  assert_true(
    from_int.get(0) is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(7L)),
  )
  assert_true(
    (Ok(
      ignore(BuiltinColumn::from_bools([true]).cast(@types.DataType::Decimal)),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  let dec = BuiltinColumn::from_dec_options([Some(@types.Dec128::of_int64(1L))])
  let identity = dec.cast(@types.DataType::Decimal)
  assert_eq(
    identity.get(0),
    @types.Scalar::Decimal(@types.Dec128::of_int64(1L)),
  )
  // String -> Decimal parses the engine's own forms (the exceptional
  // literals included); a genuine non-number on a valid slot refuses.
  let text = BuiltinColumn::from_strings(["2.5", "inf"])
  let parsed = text.cast(@types.DataType::Decimal)
  assert_true(
    parsed.get(0) is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::parse_opt("2.5").unwrap()),
  )
  assert_true(parsed.get(1) is @types.Scalar::Decimal(v) && v.is_infinite())
  assert_true(
    (Ok(
      ignore(
        BuiltinColumn::from_strings(["nope"]).cast(@types.DataType::Decimal),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ParseError(_)),
  )
  // Decimal -> Int truncates; the exceptionals and out-of-range
  // magnitudes refuse like the Float source.
  let trunc = BuiltinColumn::from_dec_options([
    Some(@types.Dec128::of_int64_scale(25L, scale=1)),
  ])
  assert_eq(trunc.cast(@types.DataType::Int).get(0), @types.Scalar::Int(2))
  let inf = BuiltinColumn::from_dec_options([
    Some(@types.Dec128::infinity(neg=true)),
  ])
  assert_true(
    (Ok(ignore(inf.cast(@types.DataType::Int))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(_)),
  )
  let past = BuiltinColumn::from_dec_options([
    Some(@types.Dec128::parse_opt("1E+40").unwrap()),
  ])
  assert_true(
    (Ok(ignore(past.cast(@types.DataType::Int))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(_)),
  )
  // Decimal -> Float and -> String read the conversions.
  assert_eq(dec.cast(@types.DataType::Float).get(0), @types.Scalar::Float(1.0))
  assert_eq(
    dec.cast(@types.DataType::String).get(0),
    @types.Scalar::String("1.0"),
  )
}
