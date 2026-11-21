// Whitebox battery for the slice pass's scan absorption: a window a
// descent sinks onto a file leaf disappears into the source when the
// driver pays for one (the leaf carries it, the node vanishes), composes
// with a window an earlier descent already sank there, and stays a node
// when the driver does not or the windows do not compose — plus the
// translations between the plan's window spelling and the leaf's own.

///|
/// A driver that only says whether windows absorb — the optimizer reads
/// the bit and the stored window; nothing executes in these tests, so
/// the cursor answers exhaustion forever.
fn silent_driver(absorbs : Bool) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(
    () => "TEST \"silent\"",
    (_projection, _predicate, _window) => @scan.BatchCursor::cursor(() => None),
    absorbs_window=absorbs,
  )
}

///|
/// An all-stages-on flag set — the default pipeline the slice pass runs
/// first in.
fn all_on() -> Optimizations {
  Optimizations::Optimizations()
}

///|
test "a window absorbs into a window-absorbing file scan" {
  let plan = LazyFrame::file_scan(silent_driver(true), may_carry_temporal=false).head(
      5,
    ).plan
  assert_eq(
    plan_render(plan.optimize_with(all_on())),
    "SCAN_TEST \"silent\" WINDOW HEAD 5",
  )
  // A driver that does not pay keeps the node: the window still applies,
  // as a stage above the read.
  let stays = LazyFrame::file_scan(
      silent_driver(false),
      may_carry_temporal=false,
    ).head(5).plan
  assert_eq(
    plan_render(stays.optimize_with(all_on())),
    "HEAD 5\n  SCAN_TEST \"silent\"",
  )
}

///|
test "absorbed windows compose with the fuse arithmetic" {
  // head over head composes to the tighter bound, inside the leaf.
  let fused = LazyFrame::file_scan(
      silent_driver(true),
      may_carry_temporal=false,
    )
    .head(5)
    .head(3).plan
  assert_eq(
    plan_render(fused.optimize_with(all_on())),
    "SCAN_TEST \"silent\" WINDOW HEAD 3",
  )
  // tail over head has no composite: the inner window stays absorbed,
  // the outer one stays a node — both still apply, in the order the
  // plan spelled.
  let unfused = LazyFrame::file_scan(
      silent_driver(true),
      may_carry_temporal=false,
    )
    .head(5)
    .tail(3).plan
  assert_eq(
    plan_render(unfused.optimize_with(all_on())),
    "TAIL 3\n  SCAN_TEST \"silent\" WINDOW HEAD 5",
  )
}

///|
test "an absorbed window renders beside the absorbed predicate" {
  // A filter under the head absorbs into the leaf too (the predicate
  // pass runs after the slice pass), and the leaf reads columns, then
  // rows, then the row range: WHERE before WINDOW.
  let both = LazyFrame::file_scan(silent_driver(true), may_carry_temporal=false)
    .head(5)
    .filter(@expr.col("v").gt(@expr.lit_int(1))).plan
  assert_eq(
    plan_render(both.optimize_with(all_on())),
    "SCAN_TEST \"silent\" WHERE (col(v) > 1) WINDOW HEAD 5",
  )
  // A filter over the head keeps the head a node: the window addresses
  // the filtered rows, and sinking it below the filter would change
  // which rows it picks.
  let ordered = LazyFrame::file_scan(
      silent_driver(true),
      may_carry_temporal=false,
    )
    .filter(@expr.col("v").gt(@expr.lit_int(1)))
    .head(5).plan
  assert_eq(
    plan_render(ordered.optimize_with(all_on())),
    "HEAD 5\n  SCAN_TEST \"silent\" WHERE (col(v) > 1)",
  )
}

///|
test "a slice window absorbs with its length spelled" {
  let plan = LazyFrame::file_scan(silent_driver(true), may_carry_temporal=false).slice(
      1,
      length=2,
    ).plan
  assert_eq(
    plan_render(plan.optimize_with(all_on())),
    "SCAN_TEST \"silent\" WINDOW SLICE [1: 2]",
  )
}

///|
test "the window spellings translate between plan and leaf" {
  // The three window shapes cross; every other operation answers `None`
  // — the caller leaves those as nodes, the conservative answer for any
  // input rather than a fabricated default.
  assert_true(frame_op_as_window(Head(7)) is Some(@scan.ScanWindow::Head(7)))
  assert_true(frame_op_as_window(Tail(7)) is Some(@scan.ScanWindow::Tail(7)))
  assert_true(
    frame_op_as_window(Slice(1, Some(2)))
    is Some(@scan.ScanWindow::Slice(1, Some(2))),
  )
  assert_true(
    frame_op_as_window(Slice(1, None)) is Some(@scan.ScanWindow::Slice(1, None)),
  )
  assert_true(frame_op_as_window(Reverse) is None)
  assert_true(frame_op_as_window(GatherEvery(2, 0)) is None)
  // The reverse spelling is total over the leaf's own vocabulary.
  assert_true(window_as_frame_op(@scan.ScanWindow::Head(3)) is Head(3))
  assert_true(
    window_as_frame_op(@scan.ScanWindow::Slice(2, None)) is Slice(2, None),
  )
}

///|
test "the tail spelling translates too" {
  assert_true(window_as_frame_op(@scan.ScanWindow::Tail(4)) is Tail(4))
}
