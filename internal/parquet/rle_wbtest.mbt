// Whitebox round-trips for the RLE / bit-packed hybrid — the writer's
// own stream read back, the two hand-decodable shapes the spec names,
// and the width-0 shortcut.

///|
test "rle round-trip: runs, stretches, and every width up to a dict index" {
  let cases : Array[Array[Int32]] = [
    Array::makei(100, _ => 0),
    Array::makei(100, _ => 1),
    Array::makei(64, i => i % 2),
    Array::makei(64, i => i % 7),
    Array::makei(30, i => i),
    [5, 5, 5, 5, 5, 5, 5, 5, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    [1, 5, 5, 5, 5, 5, 5, 5, 5, 2],
    [],
  ]
  for values in cases {
    let mut max_value = 0
    for v in values {
      if v > max_value {
        max_value = v
      }
    }
    for width in [1, 2, 3, 5, 8, 16] {
      // Only the widths that can carry this case's values round-trip —
      // a narrower width truncates by design, and the round-trip is not
      // its question.
      if max_value < 1 << width {
        match rle_decode(rle_encode(values, width), values.length(), width) {
          Some((decoded, _)) => assert_eq(decoded, values)
          None =>
            if values.length() > 0 {
              fail("decode refused a well-formed stream")
            }
        }
      }
    }
  }
  // Width 0: nothing consumed, everything zero.
  assert_eq(rle_encode([0, 0, 0], 0).length(), 0)
  assert_eq(rle_decode(b"", 3, 0), Some(([0, 0, 0], 0)))
}

///|
test "rle decode reads the hand-spelled shapes" {
  // An RLE run of eight ones at width 1: header 8<<1 = 0x10, value 0x01 —
  // two bytes consumed.
  assert_eq(rle_decode(b"\x10\x01", 8, 1), Some(([1, 1, 1, 1, 1, 1, 1, 1], 2)))
  // A bit-packed group of eight values at width 3 — the spec's own
  // example bytes (0x88 0xC6 0xFA): values 0,1,2,3,4,5,6,7, one varint
  // header plus three group bytes consumed.
  assert_eq(
    rle_decode(b"\x03\x88\xC6\xFA", 8, 3),
    Some(([0, 1, 2, 3, 4, 5, 6, 7], 4)),
  )
  // A stream past its count refuses, as does a width above 31.
  assert_true(rle_decode(b"\x10\x01", 7, 1) is None)
  assert_true(rle_decode(b"", 1, 32) is None)
}
