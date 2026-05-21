// Blackbox tests for the Arrow-style validity `Bitmap`. Only the public
// API is exercised; the bit-packing layout is verified indirectly through
// `is_valid` / `is_null` / `null_count`.

// ── Constructors ─────────────────────────────────────────────────────

///|
test "all_valid marks every slot valid for non-byte-aligned lengths" {
  // Cover the packing-edge cases the plan calls out explicitly.
  for n in [0, 1, 7, 8, 9, 16, 17] {
    let bm = Bitmap::all_valid(n)
    assert_eq(bm.len(), n)
    assert_eq(bm.null_count(), 0)
    for i in 0..<n {
      assert_eq(bm.is_valid(i), Ok(true))
      assert_eq(bm.is_null(i), Ok(false))
    }
  }
}

///|
test "all_null marks every slot null across packing-edge lengths" {
  for n in [0, 1, 7, 8, 9, 16] {
    let bm = Bitmap::all_null(n)
    assert_eq(bm.len(), n)
    assert_eq(bm.null_count(), n)
    for i in 0..<n {
      assert_eq(bm.is_valid(i), Ok(false))
      assert_eq(bm.is_null(i), Ok(true))
    }
  }
}

///|
test "from_bools mirrors the input vector exactly" {
  let bm = Bitmap::from_bools([
    true, false, true, true, false, false, true, true, false,
  ])
  assert_eq(bm.len(), 9)
  assert_eq(bm.null_count(), 4)
  let expected = [true, false, true, true, false, false, true, true, false]
  for i in 0..<expected.length() {
    assert_eq(bm.is_valid(i), Ok(expected[i]))
  }
}

///|
test "from_bools on the empty array" {
  let bm = Bitmap::from_bools([])
  assert_eq(bm.len(), 0)
  assert_eq(bm.null_count(), 0)
}

///|
test "from_options on Int? round-trips Some/None as 1/0" {
  let bm = Bitmap::from_options([Some(1), None, Some(3), None, None])
  assert_eq(bm.len(), 5)
  assert_eq(bm.null_count(), 3)
  assert_eq(bm.is_valid(0), Ok(true))
  assert_eq(bm.is_valid(1), Ok(false))
  assert_eq(bm.is_valid(2), Ok(true))
  assert_eq(bm.is_valid(3), Ok(false))
  assert_eq(bm.is_valid(4), Ok(false))
}

///|
test "from_options is generic in the element type" {
  // String options must also work — the function only looks at Some/None.
  let bm = Bitmap::from_options([Some("a"), None, Some("c")])
  assert_eq(bm.len(), 3)
  assert_eq(bm.null_count(), 1)
  assert_eq(bm.is_valid(1), Ok(false))
}

// ── Cross-constructor equivalence ─────────────────────────────────────

///|
test "all_valid and from_bools agree on a uniform-true vector" {
  let n = 11 // a non-byte-aligned size to exercise packing
  let a = Bitmap::all_valid(n)
  let b = Bitmap::from_bools(Array::make(n, true))
  assert_eq(a, b)
}

///|
test "all_null and from_options agree on a uniform-None vector" {
  let n = 13
  let a = Bitmap::all_null(n)
  let none_vec : Array[Int?] = Array::make(n, None)
  let b = Bitmap::from_options(none_vec)
  assert_eq(a, b)
}

// ── Inspection ────────────────────────────────────────────────────────

///|
test "is_valid out-of-bounds returns IndexOutOfBounds with the offender" {
  let bm = Bitmap::all_valid(4)
  assert_eq(bm.is_valid(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(bm.is_valid(4), Err(@types.DataError::IndexOutOfBounds(4)))
}

///|
test "is_null out-of-bounds bubbles the same error as is_valid" {
  let bm = Bitmap::all_valid(2)
  assert_eq(bm.is_null(-5), Err(@types.DataError::IndexOutOfBounds(-5)))
  assert_eq(bm.is_null(2), Err(@types.DataError::IndexOutOfBounds(2)))
}

///|
test "null_count agrees with bit-by-bit is_null" {
  let pattern = [
    true, false, false, true, true, false, true, false, true, false, false,
  ]
  let bm = Bitmap::from_bools(pattern)
  let mut expected = 0
  for v in pattern {
    if !v {
      expected = expected + 1
    }
  }
  assert_eq(bm.null_count(), expected)
  let mut by_iter = 0
  for i in 0..<bm.len() {
    if bm.is_null(i).unwrap() {
      by_iter = by_iter + 1
    }
  }
  assert_eq(by_iter, expected)
}

// ── slice ─────────────────────────────────────────────────────────────

///|
test "slice mid-range across a byte boundary preserves bits" {
  // Source spans two bytes; the slice starts at bit 3 (mid-byte) and ends
  // at bit 11 (also mid-byte), exercising packing on the seam.
  let bm = Bitmap::from_bools([
    true, false, true, // byte 0, bits 0..2
     true, true, false, false, true, // byte 0, bits 3..7
     false, true, true, // byte 1, bits 0..2 (== logical bits 8..10)
     false, // byte 1, bit 3 (== logical bit 11)
  ])
  let part = bm.slice(3, 8).unwrap()
  assert_eq(part.len(), 8)
  let expected = [true, true, false, false, true, false, true, true]
  for i in 0..<expected.length() {
    assert_eq(part.is_valid(i), Ok(expected[i]))
  }
}

///|
test "slice with length 0 yields an empty bitmap regardless of start" {
  let bm = Bitmap::all_valid(5)
  let part = bm.slice(2, 0).unwrap()
  assert_eq(part.len(), 0)
  assert_eq(part.null_count(), 0)
}

///|
test "slice covering the full range is value-equal to the source" {
  let bm = Bitmap::from_bools([true, false, true, true])
  let part = bm.slice(0, 4).unwrap()
  assert_eq(part, bm)
}

///|
test "slice rejects negative start, start past len, and overshoot" {
  let bm = Bitmap::all_valid(4)
  assert_eq(bm.slice(-1, 2), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(bm.slice(5, 0), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_eq(bm.slice(2, 5), Err(@types.DataError::IndexOutOfBounds(7)))
}

///|
test "slice rejects negative length with InvalidOperation" {
  let bm = Bitmap::all_valid(4)
  assert_true(bm.slice(0, -1) is Err(InvalidOperation(_)))
}

///|
test "slice at start == len with length 0 succeeds (empty tail slice)" {
  let bm = Bitmap::all_valid(3)
  let tail = bm.slice(3, 0).unwrap()
  assert_eq(tail.len(), 0)
}

// ── take ──────────────────────────────────────────────────────────────

///|
test "take gathers in arbitrary order with duplicates" {
  let bm = Bitmap::from_bools([true, false, true, false, true])
  let out = bm.take([4, 1, 1, 0]).unwrap()
  assert_eq(out.len(), 4)
  assert_eq(out.is_valid(0), Ok(true)) // src[4] = true
  assert_eq(out.is_valid(1), Ok(false)) // src[1] = false
  assert_eq(out.is_valid(2), Ok(false)) // src[1] = false (duplicate)
  assert_eq(out.is_valid(3), Ok(true)) // src[0] = true
}

///|
test "take with empty index array returns an empty bitmap" {
  let bm = Bitmap::all_valid(3)
  let out = bm.take([]).unwrap()
  assert_eq(out.len(), 0)
  assert_eq(out.null_count(), 0)
}

///|
test "take reports the first offender for negative and overflow indices" {
  let bm = Bitmap::all_valid(2)
  assert_eq(bm.take([0, 5]), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_eq(bm.take([-1]), Err(@types.DataError::IndexOutOfBounds(-1)))
}

// ── bit_and ───────────────────────────────────────────────────────────

///|
test "bit_and produces the bitwise AND of two same-length bitmaps" {
  let a = Bitmap::from_bools([true, true, false, false, true])
  let b = Bitmap::from_bools([true, false, true, false, true])
  let c = a.bit_and(b).unwrap()
  let expected = [true, false, false, false, true]
  for i in 0..<expected.length() {
    assert_eq(c.is_valid(i), Ok(expected[i]))
  }
}

///|
test "bit_and rejects mismatched lengths" {
  let a = Bitmap::all_valid(3)
  let b = Bitmap::all_valid(4)
  assert_eq(a.bit_and(b), Err(@types.DataError::LengthMismatch))
}

///|
test "bit_and on two empty bitmaps yields an empty bitmap" {
  let a = Bitmap::all_valid(0)
  let b = Bitmap::all_null(0)
  let c = a.bit_and(b).unwrap()
  assert_eq(c.len(), 0)
}
