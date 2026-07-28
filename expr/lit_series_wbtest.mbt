// `LitSeries` is the one node the rendering cannot tell apart: it shows as
// `lit_series("name", len)`, so two literals over different cells of the same
// name and length render identically. The blackbox suite compares expressions
// by rendering — `Expr` has no `==`, because comparing its tree would make how
// an operator lowers a promise to callers — which leaves this property to be
// asserted here, inside the package, against the node itself.

///|
test "lit_series nodes compare on the embedded series, cells included" {
  let s = @series.Series::from_ints("v", [1, 2, 3])
  // Two literal-series nodes over equal series are equal nodes (`Series` has
  // structural `Eq`); a series differing by name, cells, or dtype is a
  // different node.
  assert_true(
    lit_series(s).node ==
    lit_series(@series.Series::from_ints("v", [1, 2, 3])).node,
  )
  assert_false(
    lit_series(s).node ==
    lit_series(@series.Series::from_ints("w", [1, 2, 3])).node,
  )
  assert_false(
    lit_series(s).node ==
    lit_series(@series.Series::from_ints("v", [1, 2, 4])).node,
  )
  assert_false(
    lit_series(s).node ==
    lit_series(@series.Series::from_bools("v", [true, false, true])).node,
  )
  // A literal series is never equal to a non-`LitSeries` (the mismatched-
  // variant fallthrough).
  assert_false(lit_series(s).node == col("v").node)
}
