///|
test "physical_type: the four concrete types map one-to-one; Null has none" {
  // Asserted by pattern rather than by equality: a physical tag is matched on
  // wherever it is used, and publishing an `Eq` just so a test can spell `==`
  // would widen this package's interface for the test's convenience.
  assert_true(physical_type(@types.DataType::Int) is Some(PhysicalType::I64))
  assert_true(physical_type(@types.DataType::Float) is Some(PhysicalType::F64))
  assert_true(physical_type(@types.DataType::Bool) is Some(PhysicalType::Bool))
  assert_true(
    physical_type(@types.DataType::String) is Some(PhysicalType::Utf8),
  )
  // `Null` is a value-level concept with no physical backend, so it maps to
  // `None` — the type-level statement of why an all-null column can't be built.
  assert_true(physical_type(@types.DataType::Null) is None)
}

///|
test "PhysicalType renders its tag" {
  // `Show` is the one trait this type publishes for a reason beyond a test:
  // a physical tag appears in diagnostics. Equality does not — a caller
  // matches on the tag.
  inspect(PhysicalType::I64, content="I64")
  inspect(PhysicalType::F64, content="F64")
  inspect(PhysicalType::Bool, content="Bool")
  inspect(PhysicalType::Utf8, content="Utf8")
}
