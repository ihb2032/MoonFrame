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
      assert_eq(bm.is_valid(i), true)
      assert_eq(bm.is_null(i), false)
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
      assert_eq(bm.is_valid(i), false)
      assert_eq(bm.is_null(i), true)
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
  assert_eq(bm.len(), 0)
  assert_eq(bm.null_count(), 0)
  assert_eq(bm.to_bools(), [])
  assert_eq(bm, Bitmap::all_valid(0))
}

///|
test "all_null clamps a negative len to an empty bitmap" {
  let bm = Bitmap::all_null(-1)
  assert_eq(bm.len(), 0)
  assert_eq(bm.null_count(), 0)
  assert_eq(bm.to_bools(), [])
  assert_eq(bm, Bitmap::all_null(0))
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
    assert_eq(bm.is_valid(i), expected[i])
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
  assert_eq(bm.is_valid(0), true)
  assert_eq(bm.is_valid(1), false)
  assert_eq(bm.is_valid(2), true)
  assert_eq(bm.is_valid(3), false)
  assert_eq(bm.is_valid(4), false)
}

///|
test "is_valid_total reads one slot totally, clamping out-of-range to false" {
  let bm = Bitmap::from_bools([true, false, true])
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
  assert_eq(bm.len(), 3)
  assert_eq(bm.null_count(), 1)
  assert_eq(bm.is_valid(1), false)
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
  let bm = Bitmap::from_bools([
    true, false, true, // byte 0, bits 0..2
     true, true, false, false, true, // byte 0, bits 3..7
     false, true, true, // byte 1, bits 0..2 (== logical bits 8..10)
     false, // byte 1, bit 3 (== logical bit 11)
  ])
  let part = bm.slice(3, 8)
  assert_eq(part.len(), 8)
  let expected = [true, true, false, false, true, false, true, true]
  for i in 0..<expected.length() {
    assert_eq(part.is_valid(i), expected[i])
  }
}

///|
test "slice with length 0 yields an empty bitmap regardless of start" {
  let bm = Bitmap::all_valid(5)
  let part = bm.slice(2, 0)
  assert_eq(part.len(), 0)
  assert_eq(part.null_count(), 0)
}

///|
test "slice covering the full range is value-equal to the source" {
  let bm = Bitmap::from_bools([true, false, true, true])
  let part = bm.slice(0, 4)
  assert_eq(part, bm)
}

///|
test "slice rejects negative start, start past len, and overshoot" {
  let bm = Bitmap::all_valid(4)
  assert_eq(
    Ok(bm.slice(-1, 2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(bm.slice(5, 0)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(bm.slice(2, 5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(7)),
  )
  // An overshoot whose `start + length` overflows Int (length near Int::MAX)
  // must still be rejected, not wrap past the guard into an over-long view that
  // a later read aborts on. The reported index is the wrapped sum, so match the
  // variant rather than a brittle payload.
  assert_true(
    (Ok(bm.slice(2, 2147483647)) catch { e => Err(e) })
    is Err(IndexOutOfBounds(_)),
  )
}

///|
test "slice rejects negative length with InvalidOperation" {
  let bm = Bitmap::all_valid(4)
  assert_true(
    (Ok(bm.slice(0, -1)) catch { e => Err(e) }) is Err(InvalidOperation(_)),
  )
}

///|
test "slice at start == len with length 0 succeeds (empty tail slice)" {
  let bm = Bitmap::all_valid(3)
  let tail = bm.slice(3, 0)
  assert_eq(tail.len(), 0)
}

// ── take ──────────────────────────────────────────────────────────────

///|
test "take gathers in arbitrary order with duplicates" {
  let bm = Bitmap::from_bools([true, false, true, false, true])
  let out = bm.take([4, 1, 1, 0])
  assert_eq(out.len(), 4)
  assert_eq(out.is_valid(0), true) // src[4] = true
  assert_eq(out.is_valid(1), false) // src[1] = false
  assert_eq(out.is_valid(2), false) // src[1] = false (duplicate)
  assert_eq(out.is_valid(3), true) // src[0] = true
}

///|
test "take with empty index array returns an empty bitmap" {
  let bm = Bitmap::all_valid(3)
  let out = bm.take([])
  assert_eq(out.len(), 0)
  assert_eq(out.null_count(), 0)
}

///|
test "take reports the first offender for negative and overflow indices" {
  let bm = Bitmap::all_valid(2)
  assert_eq(
    Ok(bm.take([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(bm.take([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── bit_and ───────────────────────────────────────────────────────────

///|
test "bit_and produces the bitwise AND of two same-length bitmaps" {
  let a = Bitmap::from_bools([true, true, false, false, true])
  let b = Bitmap::from_bools([true, false, true, false, true])
  let c = a.bit_and(b)
  let expected = [true, false, false, false, true]
  for i in 0..<expected.length() {
    assert_eq(c.is_valid(i), expected[i])
  }
}

///|
test "bit_and rejects mismatched lengths" {
  let a = Bitmap::all_valid(3)
  let b = Bitmap::all_valid(4)
  assert_eq(
    Ok(a.bit_and(b)) catch {
      e => Err(e)
    },
    Err(@types.DataError::LengthMismatch),
  )
}

///|
test "bit_and on two empty bitmaps yields an empty bitmap" {
  let a = Bitmap::all_valid(0)
  let b = Bitmap::all_null(0)
  let c = a.bit_and(b)
  assert_eq(c.len(), 0)
}

// ── zero-copy slice views (P3) ───────────────────────────────────────

///|
test "sliced view equals a freshly packed bitmap and counts its own window" {
  // slice(3, 5) is a zero-copy view (offset 3 into the parent's buffer); it
  // must compare logically equal to the same five bits packed standalone,
  // and null_count must count only the view's window — not the parent's
  // other bits.
  let bm = Bitmap::from_bools([
    true, false, true, // bits 0..2
     false, true, true, false, true, // bits 3..7  (the window starts at 3)
     false, false, // bits 8..9
  ])
  let view = bm.slice(3, 5) // bits 3..7 = [false, true, true, false, true]
  let fresh = Bitmap::from_bools([false, true, true, false, true])
  assert_eq(view, fresh)
  assert_eq(view.null_count(), 2)
  assert_eq(fresh.null_count(), 2)
  // A view of a view composes the offsets.
  let inner = view.slice(1, 3) // [true, true, false]
  assert_eq(inner, Bitmap::from_bools([true, true, false]))
  assert_eq(inner.null_count(), 1)
}

///|
test "bitmap equality is logical, not structural" {
  let a = Bitmap::from_bools([true, false, true])
  // Same length, one differing bit → not equal.
  assert_eq(a == Bitmap::from_bools([true, true, true]), false)
  // Different length → not equal.
  assert_eq(a == Bitmap::from_bools([true, false]), false)
  // Same bits → equal.
  assert_eq(a == Bitmap::from_bools([true, false, true]), true)
}

///|
test "null_count of an offset-0 sub-window masks the shared tail byte (P3 regression)" {
  // A slice that starts at bit 0 but is shorter than its parent, yet rounds
  // up to the same byte count, shares the parent's final byte — where the
  // bits past `len` are live sibling bits. The popcount fast path must mask
  // them; before the fix this returned a too-small (even negative) count.
  let all3 = Bitmap::all_valid(3) // 1 byte, bits 0,1,2 set
  assert_eq(all3.slice(0, 2).null_count(), 0)
  assert_eq(all3.slice(0, 1).null_count(), 0)
  let mixed = Bitmap::from_bools([true, false, true]) // bit 1 is null
  assert_eq(mixed.slice(0, 2).null_count(), 1) // window [0, 2) keeps the null
  // `len` a multiple of 8 exercises the `tail == 0` fast path (no mask).
  assert_eq(Bitmap::all_valid(8).null_count(), 0)
  assert_eq(Bitmap::all_null(8).null_count(), 8)
}

///|
test "null_count over every slice agrees with a naive bit-by-bit count" {
  // Property: for a fixed pattern the null_count of every
  // `[start, start + len)` slice equals the per-bit count — covering offset 0
  // and offset != 0, full bytes and masked tails, all against the
  // shared-buffer fast path.
  let pattern = [
    true, false, true, true, false, false, true, false, true, true, false, true,
    false,
  ]
  let bm = Bitmap::from_bools(pattern)
  let n = pattern.length()
  for start in 0..<(n + 1) {
    for len in 0..<(n - start + 1) {
      let mut expected = 0
      for k in 0..<len {
        if !pattern[start + k] {
          expected = expected + 1
        }
      }
      assert_eq(bm.slice(start, len).null_count(), expected)
    }
  }
}
