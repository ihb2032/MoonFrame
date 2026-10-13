// Property-based tests (quickcheck) for the `io` package: CSV, JSON, and
// NDJSON are faithful round-trips. We check a *text fixpoint* — parsing
// emitted text and re-emitting it reproduces the text exactly — which
// validates that reader and writer agree on the wire format, without
// coupling the property to the DataFrame's internal schema-flag
// representation.

///|
/// A non-empty `Array[Int64]` of length `1..=max_len`. We avoid the 0-row
/// frame, whose emitted header alone carries no values for schema inference to
/// recover the Int dtype from.
fn gen_i64_array(max_len : Int32) -> @gen.Generator[Array[Int64]] {
  @gen.int_range(1, max_len).flat_map(n => {
    @gen.int_range(-1000, 1000).map(x => x.to_int64()).array_with_size(n)
  })
}

///|
/// The text-fixpoint property for one wire format: parsing the emitted text
/// and re-emitting it reproduces the text exactly. Driven by the
/// `wire_formats` table, so a fourth format joins by adding its row there.
fn prop_roundtrip(fmt : WireFormat, xs : Array[Int64]) -> Bool {
  try {
    let df = @frame.DataFrame::DataFrame([@series.Series::from_ints("x", xs)])
    let text = (fmt.emit)(df)
    (fmt.emit)((fmt.parse)(text)) == text
  } catch {
    _ => false
  }
}

///|
test "property: CSV round-trips a single Int column" {
  // A fixed seed keeps the generated cases — and hence coverage —
  // reproducible run to run; `count` matches the driver's default sweep.
  for xs in gen_i64_array(30).samples(count=100, seed=37UL) {
    assert_true(prop_roundtrip(wire_formats[0], xs))
  }
}

///|
test "property: JSON round-trips a single Int column" {
  for xs in gen_i64_array(30).samples(count=100, seed=37UL) {
    assert_true(prop_roundtrip(wire_formats[1], xs))
  }
}

///|
test "property: NDJSON round-trips a single Int column" {
  for xs in gen_i64_array(30).samples(count=100, seed=37UL) {
    assert_true(prop_roundtrip(wire_formats[2], xs))
  }
}
