// Property-based tests (quickcheck) for the `io` package: CSV, JSON, and
// NDJSON are faithful round-trips. We check a *text fixpoint* — parsing
// emitted text and re-emitting it reproduces the text exactly — which
// validates that reader and writer agree on the wire format, without
// coupling the property to the DataFrame's internal schema-flag
// representation.

///|
/// One generated `Int64`: mostly small values, with the `Int64` extremes
/// and the first `Double`-inexact magnitudes mixed in — the round-trip's
/// exact-text paths (the integer `repr` recovery in JSON, full-range
/// decimal text in CSV) live at those edges, so the generator owes them
/// real coverage rather than a vanishing tail.
fn gen_i64_edge() -> @gen.Generator[Int64] {
  @gen.frequency([
    (8, @gen.int_range(-1000, 1000).map(x => x.to_int64())),
    (1, @gen.pure(9_223_372_036_854_775_807L)), // Int64::MAX
    (1, @gen.pure(-9_223_372_036_854_775_808L)), // Int64::MIN
    (1, @gen.pure(9_007_199_254_740_993L)), // 2^53 + 1: first inexact Double
    (1, @gen.pure(-9_007_199_254_740_993L)),
    (1, @gen.pure(4_611_686_018_427_387_904L)), // 2^62
  ])
}

///|
/// A non-empty `Array[Int64]` of length `1..=max_len`. We avoid the 0-row
/// frame, whose emitted header alone carries no values for schema inference to
/// recover the Int dtype from.
fn gen_i64_array(max_len : Int32) -> @gen.Generator[Array[Int64]] {
  @gen.int_range(1, max_len).flat_map(n => gen_i64_edge().array_with_size(n))
}

///|
/// One generated string of ordinary printable Unicode `len` characters
/// long: a leading letter, then letters, digits, Latin-extended, and CJK
/// characters. The leading letter keeps every cell from parsing as a
/// number or a bool, so the column always infers `String` — the
/// dtype-from-content narrowing a typeless format performs (`"007"` →
/// `Int` 7, dropping the zeros) is a documented lossy case this property
/// does not generate. Escaping and control characters are the corpus
/// tests' job; the property owes the formats ordinary text.
fn gen_printable_string(len : Int32) -> @gen.Generator[String] {
  let lead = @gen.one_of([
    @gen.char_range('a', 'z'),
    @gen.char_range('A', 'Z'),
    @gen.char_range('À', 'ɏ'),
    @gen.char_range('一', '鿿'),
  ])
  let rest = @gen.one_of([lead, @gen.char_range('0', '9')])
  lead.flat_map(first => {
    rest
    .array_with_size(len - 1)
    .map(tail => {
      let b = StringBuilder()
      b.write_char(first)
      for c in tail {
        b.write_char(c)
      }
      b.to_string()
    })
  })
}

///|
/// A non-empty `Array[String]` of length `1..=max_len`, each cell a
/// printable-Unicode string of `1..=8` characters.
fn gen_string_array(max_len : Int32) -> @gen.Generator[Array[String]] {
  @gen.int_range(1, max_len).flat_map(n => {
    @gen.int_range(1, 8)
    .flat_map(len => gen_printable_string(len))
    .array_with_size(n)
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
/// The same fixpoint over a generated string column: ordinary printable
/// Unicode text must survive every format's write-read pair byte for byte.
fn prop_roundtrip_strings(fmt : WireFormat, xs : Array[String]) -> Bool {
  try {
    let df = @frame.DataFrame::DataFrame([@series.Series::from_strings("s", xs)])
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

///|
test "property: CSV round-trips a single String column" {
  for xs in gen_string_array(30).samples(count=100, seed=37UL) {
    assert_true(prop_roundtrip_strings(wire_formats[0], xs))
  }
}

///|
test "property: JSON round-trips a single String column" {
  for xs in gen_string_array(30).samples(count=100, seed=37UL) {
    assert_true(prop_roundtrip_strings(wire_formats[1], xs))
  }
}

///|
test "property: NDJSON round-trips a single String column" {
  for xs in gen_string_array(30).samples(count=100, seed=37UL) {
    assert_true(prop_roundtrip_strings(wire_formats[2], xs))
  }
}
