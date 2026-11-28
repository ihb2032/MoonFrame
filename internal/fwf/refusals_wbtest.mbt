// Whitebox tests of every refusal: one a message, each asserting the
// variant and the exact text, as the library renders it and as it is
// spelled. The texts are the codec's own; where the reference reader
// refuses the same input is pinned by the fixtures.

///|
/// The refusal a test expects: the variant with its detail.
fn invalid(detail : String) -> @types.DataError {
  @types.DataError::InvalidOperation(detail)
}

///|
/// What a call raised: it must raise, or the test fails.
fn raised(
  make : () -> FwfLayout raise @types.DataError,
) -> @types.DataError raise @types.DataError {
  match attempt(make) {
    Answered(_) =>
      raise problem("the call answered where a refusal was looked for")
    Refused(error) => error
  }
}

///|
test "two boundary lists of different lengths refuse" {
  let error = raised(() => FwfLayout::FwfLayout([0, 4, 9], [3, 8]))
  assert_eq(
    error,
    invalid("fwf: 3 starts and 2 ends: a field needs one of each"),
  )
  assert_eq(
    error.message(),
    "Invalid operation: fwf: 3 starts and 2 ends: a field needs one of each",
  )
  let other = raised(() => FwfLayout::FwfLayout([0], []))
  assert_eq(
    other,
    invalid("fwf: 1 starts and 0 ends: a field needs one of each"),
  )
}

///|
test "a field that starts before the line's first character refuses" {
  let error = raised(() => FwfLayout::FwfLayout([0, -1], [3, 8]))
  assert_eq(
    error,
    invalid("fwf: field 2 starts at -1, before the line's first character"),
  )
  // the first field too, and the smallest number there is
  let first = raised(() => FwfLayout::FwfLayout([-2147483648], [2147483647]))
  assert_eq(
    first,
    invalid(
      "fwf: field 1 starts at -2147483648, before the line's first character",
    ),
  )
}

///|
test "a field that ends before it starts refuses" {
  let error = raised(() => FwfLayout::FwfLayout([0, 5], [3, 3]))
  assert_eq(error, invalid("fwf: field 2 ends at 3 before it starts at 5"))
  // an empty field does not: its start is its end
  assert_eq(
    boundaries(FwfLayout::FwfLayout([0, 5, 9], [3, 5, 12])),
    "(0, 3) (5, 5) (9, 12)",
  )
}

///|
test "a field that starts before the one before it ends refuses, out of order and overlapping alike" {
  let inside = raised(() => FwfLayout::FwfLayout([0, 4], [8, 9]))
  assert_eq(
    inside,
    invalid("fwf: field 2 starts at 4, before field 1 ends at 8"),
  )
  let backwards = raised(() => FwfLayout::FwfLayout([5, 0], [8, 3]))
  assert_eq(
    backwards,
    invalid("fwf: field 2 starts at 0, before field 1 ends at 8"),
  )
  // a field that starts where the one before it ends does not
  assert_eq(
    boundaries(FwfLayout::FwfLayout([0, 8, 9], [8, 9, 14])),
    "(0, 8) (8, 9) (9, 14)",
  )
}

///|
test "a width below zero refuses" {
  let error = raised(() => fwf_layout_of_widths([3, -1, 2]))
  assert_eq(error, invalid("fwf: the width of field 2 is -1, below zero"))
  // a width of zero is an empty field
  assert_eq(boundaries(fwf_layout_of_widths([3, 0, 2])), "(0, 3) (3, 3) (3, 5)")
}

///|
test "widths that run past what a boundary names refuse" {
  let error = raised(() => fwf_layout_of_widths([2147483647, 1]))
  assert_eq(
    error,
    invalid(
      "fwf: the widths of 2 fields run past 2147483647 characters, which no boundary names",
    ),
  )
  // the furthest a boundary names is reached, not passed
  assert_eq(
    boundaries(fwf_layout_of_widths([2147483646, 1])),
    "(0, 2147483646) (2147483646, 2147483647)",
  )
}

///|
test "a window of zero or below refuses" {
  let zero = raised(() => fwf_infer_layout(["A  B", "1  2"], 0))
  assert_eq(
    zero,
    invalid(
      "fwf: infer_nrows is 0: it names how many lines the layout is read off, one or more",
    ),
  )
  let below = raised(() => fwf_infer_layout([], -5))
  assert_eq(
    below,
    invalid(
      "fwf: infer_nrows is -5: it names how many lines the layout is read off, one or more",
    ),
  )
  // the window counts the lines it is given and may exceed them
  assert_eq(
    boundaries(fwf_infer_layout(["A  B", "1  2"], 2147483647)),
    boundaries(fwf_infer_layout(["A  B", "1  2"], 2)),
  )
}

///|
test "no line to read refuses" {
  let error = raised(() => fwf_infer_layout([], 100))
  assert_eq(error, invalid("fwf: no line to read a layout from"))
}

///|
test "lines with no character that is not a separator refuse, saying what they held" {
  let error = raised(() => fwf_infer_layout(["   ", "\t", "  \t  ", ""], 100))
  assert_eq(
    error,
    invalid(
      "fwf: no field: 4 lines read, the longest 5 characters, and every character a space, a tab, a carriage return or a line feed",
    ),
  )
  // terminators handed in are separators like the rest
  let carried = raised(() => fwf_infer_layout(["\r\n", "\n"], 100))
  assert_eq(
    carried,
    invalid(
      "fwf: no field: 2 lines read, the longest 2 characters, and every character a space, a tab, a carriage return or a line feed",
    ),
  )
  // the lines past the window are not read and do not count
  let windowed = raised(() => fwf_infer_layout(["  ", "a"], 1))
  assert_eq(
    windowed,
    invalid(
      "fwf: no field: 1 lines read, the longest 2 characters, and every character a space, a tab, a carriage return or a line feed",
    ),
  )
  // and read together the second line's one character is a field: each
  // line is measured from its own first character
  assert_eq(boundaries(fwf_infer_layout(["  ", "a"], 2)), "(0, 1)")
}

///|
test "every refusal is an InvalidOperation whose text begins with fwf:" {
  let calls : Array[() -> FwfLayout raise @types.DataError] = [
    () => FwfLayout::FwfLayout([0, 1], [1]),
    () => FwfLayout::FwfLayout([-1], [1]),
    () => FwfLayout::FwfLayout([0], [-1]),
    () => FwfLayout::FwfLayout([0, 0], [1, 1]),
    () => fwf_layout_of_widths([-1]),
    () => fwf_layout_of_widths([2147483647, 2]),
    () => fwf_infer_layout(["a"], 0),
    () => fwf_infer_layout([], 100),
    () => fwf_infer_layout([" "], 100),
  ]
  assert_eq(calls.length(), 9)
  for call in calls {
    match attempt(call) {
      Answered(_) => fail("a call answered where every call refuses")
      Refused(error) => {
        assert_true(error is @types.DataError::InvalidOperation(_))
        assert_true(error.message().has_prefix("Invalid operation: fwf: "))
      }
    }
  }
}
