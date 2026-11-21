// Whitebox pins for the stacking kernel the public `vstack` and the
// engine's batch assembly ride — the corners the two-frame spelling
// cannot reach.

///|
test "stacking zero frames is the empty frame" {
  // The kernel's empty corner: a cursor that yields no batches assembles
  // to the 0×0 frame, the schema-less answer (the schema-carrying empty
  // corner is a zero-row batch's own, not the stack's).
  let stacked = stack_frames("test", [])
  assert_eq(stacked.shape(), (0, 0))
}
