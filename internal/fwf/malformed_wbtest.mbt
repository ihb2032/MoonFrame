// Whitebox malformed-input sweep over strings no file can hold: random
// strings of code units, surrogate halves among them, taken as lines, as a
// layout's boundaries and as a layout's widths. No call may abort, and no
// call may raise anything but `DataError`: every call raises or answers.
// The truncations, the single-character replacements and the random texts
// a file can hold are drawn and compared with the reference reader
// elsewhere in this suite; a string holding a surrogate half is the one
// input the reference cannot be handed, so it is checked for the absence
// of an abort alone. An abort would end the test process before its
// summary, so a marker line precedes each case and the summary is the
// test's last line. The seed is named below and the generator is written
// out, so the inputs are the same on every run and every target.

///|
/// `magnitude` with a drawn sign.
fn signed(rng : SplitMix, magnitude : Int32) -> Int32 {
  if rng.next() % 2UL == 1UL {
    -magnitude
  } else {
    magnitude
  }
}

///|
test "200 random strings of code units, as lines and as layouts, raise DataError or answer, and nothing aborts" {
  // a valid file's lines, to cut under whatever layout the units spell
  let grid = jstrings(
    field(
      fixture_json(".github/fixtures/fwf/reference/grid_one_space.txt.json"),
      "lines",
    ),
  )
  let rng = SplitMix::{ state: SEED_UNITS, }
  let mut raised = 0
  let mut answered = 0
  let mut strings = 0
  let mut inferences = 0
  let mut layouts_built = 0
  let mut layouts_refused = 0
  let mut cuts = 0
  let mut shortest = 40
  let mut longest = 0
  for case in 0..<200 {
    println("random-units case \{case}")
    let count = 1 + (rng.next() % 4UL).to_int()
    let drawn : Array[String] = []
    for _ in 0..<count {
      let length = (rng.next() % 41UL).to_int()
      if length < shortest {
        shortest = length
      }
      if length > longest {
        longest = length
      }
      drawn.push(drawn_units(rng, length))
    }
    strings += drawn.length()
    let mut refused = false
    // As lines, under a window drawn from the whole range a call's takes —
    // below zero, where the call refuses before it reads a line, up to the
    // furthest a boundary's count can be.
    let windows : ReadOnlyArray[Int32] = [
      -2147483648, -5, 0, 1, 2, 3, 100, 2147483647,
    ]
    let window = windows[(rng.next() % windows.length().to_uint64()).to_int()]
    let under = fwf_layout_of_widths([1, 2, 3])
    let layout = match attempt(() => fwf_infer_layout(drawn, window)) {
      Answered(layout) => {
        inferences += 1
        layout
      }
      Refused(_) => {
        refused = true
        under
      }
    }
    for line in drawn {
      let cells = fwf_cut(line, layout)
      assert_eq(cells.length(), layout.len())
      cuts += cells.length()
    }
    // As a layout's boundaries — every other code unit of the first string
    // a start, the rest an end — in one of three shapes: each unit with a
    // drawn sign; the units as they are; or running totals of the units,
    // each field starting where the one before it ended.
    let shape = (rng.next() % 3UL).to_int()
    let starts : Array[Int32] = []
    let ends : Array[Int32] = []
    let mut edge = 0
    for i, unit in drawn[0].code_units() {
      let magnitude = unit.to_int()
      if i % 2 == 0 {
        if shape == 2 {
          starts.push(edge)
        } else if shape == 1 {
          starts.push(magnitude)
        } else {
          starts.push(signed(rng, magnitude))
        }
      } else if shape == 2 {
        edge += magnitude
        ends.push(edge)
      } else if shape == 1 {
        ends.push(magnitude)
      } else {
        ends.push(signed(rng, magnitude))
      }
    }
    match attempt(() => FwfLayout::FwfLayout(starts, ends)) {
      Answered(layout) => {
        layouts_built += 1
        for line in grid {
          let cells = fwf_cut(line, layout)
          assert_eq(cells.length(), layout.len())
          cuts += cells.length()
        }
        assert_eq(fwf_cut(drawn[count - 1], layout).length(), layout.len())
      }
      Refused(_) => {
        layouts_refused += 1
        refused = true
      }
    }
    // As a layout's widths: the last string's code units, each with a
    // drawn sign, or as they are.
    let plain = rng.next() % 2UL == 0UL
    let widths = drawn[count - 1]
      .code_units()
      .map(unit => {
        let magnitude = unit.to_int()
        if plain {
          magnitude
        } else {
          signed(rng, magnitude)
        }
      })
    match attempt(() => fwf_layout_of_widths(widths)) {
      Answered(layout) => {
        layouts_built += 1
        for line in grid {
          assert_eq(fwf_cut(line, layout).length(), layout.len())
          cuts += layout.len()
        }
      }
      Refused(_) => {
        layouts_refused += 1
        refused = true
      }
    }
    if refused {
      raised += 1
    } else {
      answered += 1
    }
  }
  // A sweep that only ever raised, or only ever answered, would say
  // nothing about the other side.
  if raised == 0 || answered == 0 {
    fail("of 200 cases \{raised} raised and \{answered} answered")
  }
  if inferences == 0 || layouts_built == 0 || layouts_refused == 0 {
    fail(
      "the units as lines inferred \{inferences} layouts; as layouts \{layouts_built} were built and \{layouts_refused} refused",
    )
  }
  println(
    "random strings of code units: 200 cases, \{strings} strings of \{shortest} to \{longest} units, \{raised} raised DataError, \{answered} answered, \{inferences} layouts inferred from them, \{layouts_built} layouts built and \{layouts_refused} refused from their units, \{cuts} cells cut, 0 aborted; DONE",
  )
}
