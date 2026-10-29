// Registry behavior pins: the physical mapping, the display names, and the
// numericity flag — each read through the accessor the engine packages use,
// so the registry's rows stay honest.

///|
test "physical: the concrete dtypes map to their buffers; Null has none" {
  assert_true(DataType::Int.physical() is Some(PhysicalType::I64))
  assert_true(DataType::Float.physical() is Some(PhysicalType::F64))
  assert_true(DataType::Bool.physical() is Some(PhysicalType::Bool))
  assert_true(DataType::String.physical() is Some(PhysicalType::Utf8))
  // The value-level Null has no storable representation...
  assert_true(DataType::Null.physical() is None)
  // ...and Date rides the existing I64 buffer — the whole point of the
  // registry's identity/representation split.
  assert_true(DataType::Date.physical() is Some(PhysicalType::I64))
  // ...and Timestamp rides it too, the second I64 rider.
  assert_true(DataType::Timestamp.physical() is Some(PhysicalType::I64))
  // ...and Decimal is the third: its scale lives in the dtype, its
  // magnitude in the buffer.
  assert_true(DataType::Decimal(2).physical() is Some(PhysicalType::I64))
}

///|
test "display names are the registered spellings" {
  // Read through the public Show rendering, which the registry feeds.
  assert_eq(DataType::Int.to_string(), "Int")
  assert_eq(DataType::Float.to_string(), "Float")
  assert_eq(DataType::Bool.to_string(), "Bool")
  assert_eq(DataType::String.to_string(), "String")
  assert_eq(DataType::Date.to_string(), "Date")
  assert_eq(DataType::Timestamp.to_string(), "Timestamp")
  // The one parameterised spelling — it reaches TypeMismatch and
  // ParseError messages, so its interpolation is pinned here.
  assert_eq(DataType::Decimal(2).to_string(), "Decimal(2)")
  assert_eq(DataType::Null.to_string(), "Null")
}

///|
test "numericity: Int and Float only, however the buffers align" {
  assert_true(DataType::Int.is_numeric())
  assert_true(DataType::Float.is_numeric())
  assert_false(DataType::Bool.is_numeric())
  assert_false(DataType::String.is_numeric())
  // Date is I64-typed but is not a number: summing day-counts is a bug.
  assert_false(DataType::Date.is_numeric())
  // Timestamp is microseconds on I64 — not a number either.
  assert_false(DataType::Timestamp.is_numeric())
  // Decimal's arithmetic is its own checked lane (scale alignment), not
  // the generic numeric one.
  assert_false(DataType::Decimal(2).is_numeric())
  assert_false(DataType::Null.is_numeric())
}

///|
test "summability: Decimal sums, the other riders do not" {
  // A decimal column's sum is a decimal of the same scale (the checked
  // fold); a date / timestamp column has no meaningful sum. Read through
  // the accessor the whole-frame stats gate uses.
  assert_true(DataType::Decimal(2).is_summable())
  assert_false(DataType::Date.is_summable())
  assert_false(DataType::Timestamp.is_summable())
}

///|
test "the I64 rider lift: Date lifts, every other dtype reads plain Int" {
  // The lift is wildcard-free: a new I64 rider fails compilation of this
  // registration until its arm is written, so its cells can never
  // silently read back as Int. Each non-rider dtype lifts nothing — the
  // caller's plain-Int path.
  assert_true(
    DataType::Date.i64_rider_scalar(11016L) is Some(Scalar::Date(11016L)),
  )
  assert_true(
    DataType::Timestamp.i64_rider_scalar(1704067200000000L)
    is Some(Scalar::Timestamp(1704067200000000L)),
  )
  assert_true(DataType::Int.i64_rider_scalar(1L) is None)
  assert_true(DataType::Float.i64_rider_scalar(1L) is None)
  assert_true(DataType::Bool.i64_rider_scalar(1L) is None)
  assert_true(DataType::String.i64_rider_scalar(1L) is None)
  assert_true(DataType::Null.i64_rider_scalar(1L) is None)
}
