// `memo_result` refuses a miss with `InvalidOperation` rather than answer
// with whatever entry happens to sit at the memo's front. The executing fold
// pairs every probe with a node `post_order_unique` emitted, so no public
// surface can produce the miss — only an in-package caller hand-building a
// memo can, which is why the refusal is pinned here, beside the
// package-private function it covers.

///|
test "memo_result refuses a node the walk never emitted" {
  let df = @io.parse_csv_str("a\n1\n")
  let other = @io.parse_csv_str("a\n2\n")
  // One computed scan in the memo, probed for a second scan it never stored —
  // two distinct node objects, so the identity scan cannot match either way.
  let memo : Array[(LogicalPlan, @frame.DataFrame)] = [(Scan(InMemory(df)), df)]
  let res = Ok(memo_result(memo, Scan(InMemory(other)))) catch { e => Err(e) }
  assert_true(res is Err(@types.DataError::InvalidOperation(_)))
}
