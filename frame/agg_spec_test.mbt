// Blackbox tests for the `AggSpec` construction surface.
//
// `AggSpec`'s fields are private, so the *observable* behaviour of a spec
// — the default `"<column>_<kind>"` output name and the `with_alias`
// override — surfaces through the columns of `GroupedDataFrame::agg`, and
// is asserted there (group_by_test.mbt). What we pin here is the
// constructor surface itself: that the five `AggKind` constructors and
// `with_alias` each build the spec they claim to, observed through the
// derived `Eq`.

///|
test "AggSpec constructors of different kinds are distinct" {
  // A bug that mixed up two kinds (e.g. `count` building a `Sum` spec)
  // would collapse these into equality.
  assert_not_eq(AggSpec::count("x"), AggSpec::sum("x"))
  assert_not_eq(AggSpec::sum("x"), AggSpec::mean("x"))
  assert_not_eq(AggSpec::mean("x"), AggSpec::min("x"))
  assert_not_eq(AggSpec::min("x"), AggSpec::max("x"))
  assert_not_eq(AggSpec::max("x"), AggSpec::count("x"))
}

///|
test "AggSpec of the same kind on different columns are distinct" {
  assert_not_eq(AggSpec::sum("x"), AggSpec::sum("y"))
}

///|
test "AggSpec is reflexively equal (same column, kind, no alias)" {
  assert_eq(AggSpec::mean("revenue"), AggSpec::mean("revenue"))
}

///|
test "with_alias yields a distinct spec; equal aliases stay equal" {
  let base = AggSpec::sum("revenue")
  // Setting an alias changes the spec away from the default-named one.
  assert_not_eq(base, base.with_alias("total"))
  // Same alias → still equal (the override is deterministic).
  assert_eq(base.with_alias("total"), base.with_alias("total"))
  // Different aliases → distinct.
  assert_not_eq(base.with_alias("total"), base.with_alias("grand_total"))
  // The last alias wins when chained.
  assert_eq(
    base.with_alias("first").with_alias("second"),
    base.with_alias("second"),
  )
}
