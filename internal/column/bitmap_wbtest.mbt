// Whitebox tests for the Arrow-style validity `Bitmap`. They compile inside
// the package and exercise it there on purpose: the constructors, the bit
// reads, and the view mechanics behind a zero-copy slice are package-private,
// because the layer above reaches a column's validity through
// `ColumnStorage` and never the bitmap itself.

// ── Constructors ─────────────────────────────────────────────────────

///|
test "all_valid marks every slot valid for non-byte-aligned lengths" {
  // Cover the packing-edge cases the plan calls out explicitly.
  for n in [0, 1, 7, 8, 9, 16, 17] {
    let bm = Bitmap::all_valid(n)
    assert_eq(bm.len, n)
    assert_eq(bm.null_count(), 0)
    for i in 0..<n {
      assert_eq(bm.is_valid(i), true)
      assert_eq(bm.is_null(i), false)
    }
  }
}

///|
test "all_valid clamps a negative len to an empty bitmap" {
  // Stored verbatim, a negative `len` would desynchronise from the empty
  // buffer and make `null_count` read past it (an abort, the failure mode
  // the never-abort rule forbids). Clamped, the result is exactly the
  // empty bitmap.
  let bm = Bitmap::all_valid(-3)
  assert_eq(bm.len, 0)
  assert_eq(bm.null_count(), 0)
  assert_eq(bm.to_bools(), [])
  assert_eq(bm, Bitmap::all_valid(0))
}

///|
test "from_bools mirrors the input vector exactly" {
  let bm = mask([true, false, true, true, false, false, true, true, false])
  assert_eq(bm.len, 9)
  assert_eq(bm.null_count(), 4)
  let expected : ReadOnlyArray[Bool] = [
    true, false, true, true, false, false, true, true, false,
  ]
  for i in 0..<expected.length() {
    assert_eq(bm.is_valid(i), expected[i])
  }
}

///|
test "from_bools on the empty array" {
  let bm = mask([])
  assert_eq(bm.len, 0)
  assert_eq(bm.null_count(), 0)
}

///|
test "from_options on Int? round-trips Some/None as 1/0" {
  let bm = Bitmap::from_options([Some(1), None, Some(3), None, None])
  assert_eq(bm.len, 5)
  assert_eq(bm.null_count(), 3)
  assert_eq(bm.is_valid(0), true)
  assert_eq(bm.is_valid(1), false)
  assert_eq(bm.is_valid(2), true)
  assert_eq(bm.is_valid(3), false)
  assert_eq(bm.is_valid(4), false)
}

///|
test "is_valid_total reads one slot totally, clamping out-of-range to false" {
  let bm = mask([true, false, true])
  // In-bounds: agrees with the raising `is_valid`.
  assert_eq(bm.is_valid_total(0), true)
  assert_eq(bm.is_valid_total(1), false)
  assert_eq(bm.is_valid_total(2), true)
  // Out of range clamps to `false` rather than raising.
  assert_eq(bm.is_valid_total(-1), false)
  assert_eq(bm.is_valid_total(3), false)
}

///|
test "from_options is generic in the element type" {
  // String options must also work — the function only looks at Some/None.
  let bm = Bitmap::from_options([Some("a"), None, Some("c")])
  assert_eq(bm.len, 3)
  assert_eq(bm.null_count(), 1)
  assert_eq(bm.is_valid(1), false)
}

// ── Cross-constructor equivalence ─────────────────────────────────────

///|
test "all_valid and from_bools agree on a uniform-true vector" {
  let n = 11 // a non-byte-aligned size to exercise packing
  let a = Bitmap::all_valid(n)
  let b = mask(Array::make(n, true))
  assert_eq(a, b)
}

// ── Inspection ────────────────────────────────────────────────────────

///|
test "is_valid out-of-bounds raises IndexOutOfBounds with the offender" {
  let bm = Bitmap::all_valid(4)
  assert_eq(
    Ok(bm.is_valid(-1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(bm.is_valid(4)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(4)),
  )
}

///|
test "is_null out-of-bounds bubbles the same error as is_valid" {
  let bm = Bitmap::all_valid(2)
  assert_eq(
    Ok(bm.is_null(-5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-5)),
  )
  assert_eq(
    Ok(bm.is_null(2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(2)),
  )
}

///|
test "null_count agrees with bit-by-bit is_null" {
  let pattern = [
    true, false, false, true, true, false, true, false, true, false, false,
  ]
  let bm = mask(pattern)
  let mut expected = 0
  for v in pattern {
    if !v {
      expected = expected + 1
    }
  }
  assert_eq(bm.null_count(), expected)
  let mut by_iter = 0
  for i in 0..<bm.len {
    if bm.is_null(i) {
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
  let bm = mask([
    true, false, true, // byte 0, bits 0..2
     true, true, false, false, true, // byte 0, bits 3..7
     false, true, true, // byte 1, bits 0..2 (== logical bits 8..10)
     false, // byte 1, bit 3 (== logical bit 11)
  ])
  let part = bm.slice_view(3, 8)
  assert_eq(part.len, 8)
  let expected : ReadOnlyArray[Bool] = [
    true, true, false, false, true, false, true, true,
  ]
  for i in 0..<expected.length() {
    assert_eq(part.is_valid(i), expected[i])
  }
}

///|
test "slice with length 0 yields an empty bitmap regardless of start" {
  let bm = Bitmap::all_valid(5)
  let part = bm.slice_view(2, 0)
  assert_eq(part.len, 0)
  assert_eq(part.null_count(), 0)
}

///|
test "slice covering the full range is value-equal to the source" {
  let bm = mask([true, false, true, true])
  let part = bm.slice_view(0, 4)
  assert_eq(part, bm)
}

// ── take ──────────────────────────────────────────────────────────────

///|
test "take gathers in arbitrary order with duplicates" {
  let bm = mask([true, false, true, false, true])
  let out = bm.take_view([4, 1, 1, 0])
  assert_eq(out.len, 4)
  assert_eq(out.is_valid(0), true) // src[4] = true
  assert_eq(out.is_valid(1), false) // src[1] = false
  assert_eq(out.is_valid(2), false) // src[1] = false (duplicate)
  assert_eq(out.is_valid(3), true) // src[0] = true
}

///|
test "take with empty index array returns an empty bitmap" {
  let bm = Bitmap::all_valid(3)
  let out = bm.take_view([])
  assert_eq(out.len, 0)
  assert_eq(out.null_count(), 0)
}

// ── bit_and ───────────────────────────────────────────────────────────

// ── zero-copy slice views ────────────────────────────────────────────

///|
test "sliced view equals a freshly packed bitmap and counts its own window" {
  // slice(3, 5) is a zero-copy view (offset 3 into the parent's buffer); it
  // must compare logically equal to the same five bits packed standalone,
  // and null_count must count only the view's window — not the parent's
  // other bits.
  let bm = mask([
    true, false, true, // bits 0..2
     false, true, true, false, true, // bits 3..7  (the window starts at 3)
     false, false, // bits 8..9
  ])
  let view = bm.slice_view(3, 5) // bits 3..7 = [false, true, true, false, true]
  let fresh = mask([false, true, true, false, true])
  assert_eq(view, fresh)
  assert_eq(view.null_count(), 2)
  assert_eq(fresh.null_count(), 2)
  // A view of a view composes the offsets.
  let inner = view.slice_view(1, 3) // [true, true, false]
  assert_eq(inner, mask([true, true, false]))
  assert_eq(inner.null_count(), 1)
}

///|
test "bitmap equality is logical, not structural" {
  let a = mask([true, false, true])
  // Same length, one differing bit → not equal.
  assert_eq(a == mask([true, true, true]), false)
  // Different length → not equal.
  assert_eq(a == mask([true, false]), false)
  // Same bits → equal.
  assert_eq(a == mask([true, false, true]), true)
}

///|
test "null_count of an offset-0 sub-window masks the shared tail byte" {
  // A slice that starts at bit 0 but is shorter than its parent, yet rounds
  // up to the same byte count, shares the parent's final byte — where the
  // bits past `len` are live sibling bits. The popcount fast path must mask
  // them; before the fix this returned a too-small (even negative) count.
  let all3 = Bitmap::all_valid(3) // 1 byte, bits 0,1,2 set
  assert_eq(all3.slice_view(0, 2).null_count(), 0)
  assert_eq(all3.slice_view(0, 1).null_count(), 0)
  let mixed = mask([true, false, true]) // bit 1 is null
  assert_eq(mixed.slice_view(0, 2).null_count(), 1) // window [0, 2) keeps the null
  // `len` a multiple of 8 exercises the `tail == 0` fast path (no mask).
  assert_eq(Bitmap::all_valid(8).null_count(), 0)
  assert_eq(mask(Array::make(8, false)).null_count(), 8)
}

///|
test "null_count over every slice agrees with a naive bit-by-bit count" {
  // Property: for a fixed pattern the null_count of every
  // `[start, start + len)` slice equals the per-bit count — covering offset 0
  // and offset != 0, an unaligned head, whole popcounted bytes in the middle,
  // and masked tails, all against the shared-buffer fast path.
  //
  // The pattern spans four bytes so an *unaligned* window can still contain
  // whole bytes: the byte-at-a-time middle is only reachable when the window
  // holds eight bits past its head, which a three-byte pattern never leaves room
  // for. Its period is 5, coprime with a byte's 8 bits and longer than the
  // buffer, so no two bytes of it hold the same mix.
  let n = 29
  let pattern = Array::makei(n, i => i % 5 != 2)
  let bm = mask(pattern)
  for start in 0..<(n + 1) {
    for len in 0..<(n - start + 1) {
      let mut expected = 0
      for k in 0..<len {
        if !pattern[start + k] {
          expected = expected + 1
        }
      }
      assert_eq(bm.slice_view(start, len).null_count(), expected)
    }
  }
}
