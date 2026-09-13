// The Utf8Array codec: layout, zero-copy slices, byte-wise gathers, and the
// encode/decode round-trip — including the WTF-8 spelling that lets an
// unpaired surrogate half sit in a buffer without aborting, so the io write
// paths can go on refusing it (rather than the buffer corrupting it).

///|
test "layout: offsets bound each cell over the shared byte buffer" {
  let a = Utf8Array::from_strings(["a", "bb", "λ"])
  assert_eq(a.len(), 3)
  assert_eq(a.get(0), "a")
  assert_eq(a.get(1), "bb")
  assert_eq(a.get(2), "λ")
  assert_eq(a.to_strings(), ["a", "bb", "λ"])
}

///|
test "round-trip: every width and a supplementary pair" {
  // ASCII, 2-byte (é), 3-byte (€), and 4-byte (🙂 as a surrogate pair).
  let values = ["ascii", "é", "€", "a🙂b", ""]
  let a = Utf8Array::from_strings(values)
  assert_eq(a.to_strings(), values)
}

///|
test "an unpaired surrogate round-trips instead of aborting or corrupting" {
  // MoonBit strings can legally hold a lone surrogate half; core's encoder
  // aborts on one. The buffer's WTF-8 spelling keeps it recoverable byte
  // for byte, which is what the io writers' refusal check reads.
  fn lone(code_unit : Int) -> String {
    let b = StringBuilder()
    b.write_char(Int::unsafe_to_char(code_unit))
    b.to_string()
  }

  let high = lone(0xD800)
  let low = lone(0xDC00)
  let values = ["ok", high, low, "a" + high + "b"]
  let a = Utf8Array::from_strings(values)
  assert_eq(a.get(1), high)
  assert_eq(a.get(2), low)
  assert_eq(a.get(3), "a" + high + "b")
  assert_eq(a.to_strings(), values)
}

///|
test "slice_view re-bases offsets and shares the bytes" {
  let a = Utf8Array::from_strings(["a", "bb", "ccc"])
  let view = a.slice_view(1, 2)
  assert_eq(view.len(), 2)
  assert_eq(view.get(0), "bb")
  assert_eq(view.get(1), "ccc")
  assert_eq(view.to_strings(), ["bb", "ccc"])
  // A slice of a slice re-bases again off the parent's buffer.
  let nested = a.slice_view(1, 2).slice_view(1, 1)
  assert_eq(nested.get(0), "ccc")
  let empty = a.slice_view(2, 0)
  assert_eq(empty.len(), 0)
  assert_eq(empty.to_strings(), [])
}

///|
test "take_view copies the selected byte ranges verbatim" {
  let a = Utf8Array::from_strings(["x", "λλ", "z"])
  let taken = a.take_view([2, 0, 1])
  assert_eq(taken.to_strings(), ["z", "x", "λλ"])
  let reordered = a.take_view([1, 1])
  assert_eq(reordered.to_strings(), ["λλ", "λλ"])
}

///|
test "cell_eq compares bytes without decoding" {
  let a = Utf8Array::from_strings(["a", "λ"])
  let b = Utf8Array::from_strings(["a", "b"])
  assert_true(a.cell_eq(0, a, 0))
  assert_true(a.cell_eq(1, b, 0) == false)
  // Equal content across different buffers compares equal.
  assert_true(a.cell_eq(0, b, 0))
  // A 1-byte cell never equals a 2-byte cell, whatever the bytes.
  assert_true(a.cell_eq(0, a, 1) == false)
}

///|
test "from_string_options maps None to the empty placeholder" {
  let a = Utf8Array::from_string_options([Some("x"), None, Some("yz")])
  assert_eq(a.len(), 3)
  assert_eq(a.get(0), "x")
  assert_eq(a.get(1), "")
  assert_eq(a.get(2), "yz")
}
