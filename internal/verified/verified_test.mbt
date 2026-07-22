// Coverage smoke for the island, not behaviour pins — the behaviour is
// machine-checked for every input by `moon prove` (each function's
// `proof_ensure` against `specs.mbtp`). What needs exercising here is the
// one thing the callers cannot reach: `next_merge_width`'s defensive
// totality guard. The sort loop only ever asks with `0 < width < n`, so the
// arbitrary-`Int` guard line would otherwise sit uncovered; its semantics —
// including the `2^30` wrap boundary the old whitebox pins sampled — are the
// proof's job now.

///|
test "next_merge_width rejects out-of-protocol inputs" {
  assert_eq(@verified.next_merge_width(0, 5), None)
  assert_eq(@verified.next_merge_width(-1, 5), None)
  assert_eq(@verified.next_merge_width(5, 1), None)
  assert_eq(@verified.next_merge_width(5, 5), None)
}
