// `LitSeries` is the one node the rendering cannot tell apart: it shows as
// `lit_series("name", len)`, so two literals over different cells of the same
// name and length render identically. The blackbox suite compares expressions
// by rendering — `Expr` has no `==`, because comparing its tree would make how
// an operator lowers a promise to callers — which leaves what the node
// actually carries to be asserted here, inside the package.
//
// It is asserted by reading the series back out rather than by comparing two
// nodes. `Series` has a content-based equality of its own, so the cells can be
// checked directly, and `internal/ir` does not have to publish an equality over
// the AST for a test in this package to reach.

///|
/// The `Series` a `LitSeries` node carries, or `None` for any other node —
/// which doubles as the assertion that the constructor built the variant it
/// was supposed to.
fn lit_series_payload(e : Expr) -> @series.Series? {
  match e.node() {
    @ir.ExprNode::LitSeries(s) => Some(s)
    _ => None
  }
}

///|
test "lit_series carries the series it was given, cells included" {
  let s = @series.Series::from_ints("v", [1, 2, 3])
  match lit_series_payload(lit_series(s)) {
    Some(got) => {
      // The node holds the series itself, cells and all — the part the
      // rendering drops when it shows only a name and a length.
      assert_eq(got, @series.Series::from_ints("v", [1, 2, 3]))
      // A series differing by name, by cells, or by dtype is a different
      // payload, none of which the rendering would show.
      assert_not_eq(got, @series.Series::from_ints("w", [1, 2, 3]))
      assert_not_eq(got, @series.Series::from_ints("v", [1, 2, 4]))
      assert_not_eq(got, @series.Series::from_bools("v", [true, false, true]))
    }
    None => fail("lit_series built something other than a LitSeries node")
  }
  // And a node built by any other constructor is not a `LitSeries` at all.
  assert_true(lit_series_payload(col("v")) is None)
}
