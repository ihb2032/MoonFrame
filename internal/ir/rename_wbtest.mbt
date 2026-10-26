// Whitebox tests for `ExprNode::rename_columns` — every arm of the
// exhaustive match must be walked, since the coverage gate holds the
// rewrite to the same standard as the rest of the package. The lazy-side
// join tests exercise the shapes a predicate can carry; this suite pins
// the rest (and the leave-alone behaviour of every non-`Col` payload).

///|
fn rename_map() -> Map[String, String] {
  let m : Map[String, String] = Map([])
  m["a"] = "b"
  m
}

///|
test "rename_columns rewrites the Col leaf both ways" {
  let m = rename_map()
  assert_true(Col("a").rename_columns(m) is Col("b"))
  assert_true(Col("z").rename_columns(m) is Col("z"))
}

///|
test "rename_columns carries the childless leaves verbatim" {
  let m = rename_map()
  assert_true(
    Lit(@types.Scalar::Int(3)).rename_columns(m) is Lit(@types.Scalar::Int(3)),
  )
  let s = @series.Series::from_ints("s", [1, 2])
  assert_true(LitSeries(s).rename_columns(m) is LitSeries(kept) && kept == s)
}

///|
test "rename_columns descends through every unary-child shape" {
  let m = rename_map()
  assert_true(
    Binary(BinOp::Gt, Col("a"), Col("z")).rename_columns(m)
    is Binary(_, Col("b"), Col("z")),
  )
  assert_true(
    Unary(UnOp::Neg, Col("a")).rename_columns(m) is Unary(_, Col("b")),
  )
  assert_true(
    Agg(@series.ReduceOp::Sum, Col("a")).rename_columns(m) is Agg(_, Col("b")),
  )
  assert_true(
    Str(StrOp::ToUppercase, Col("a")).rename_columns(m) is Str(_, Col("b")),
  )
  assert_true(
    Positional(PositionalOp::CumSum(false), Col("a")).rename_columns(m)
    is Positional(_, Col("b")),
  )
  assert_true(
    Cast(Col("a"), @types.DataType::Float).rename_columns(m)
    is Cast(Col("b"), _),
  )
  assert_true(
    Alias(Col("a"), "kept").rename_columns(m) is Alias(Col("b"), "kept"),
  )
}

///|
test "rename_columns descends through the multi-child shapes" {
  let m = rename_map()
  assert_true(
    Ternary(Col("a"), Col("z"), Lit(@types.Scalar::Bool(true))).rename_columns(
      m,
    )
    is Ternary(Col("b"), Col("z"), _),
  )
  assert_true(
    FillNull(Col("a"), Lit(@types.Scalar::Int(0))).rename_columns(m)
    is FillNull(Col("b"), _),
  )
  assert_true(
    FillNan(Col("a"), Lit(@types.Scalar::Float(0.0))).rename_columns(m)
    is FillNan(Col("b"), _),
  )
  assert_true(
    IsIn(Col("a"), [@types.Scalar::Int(1)]).rename_columns(m)
    is IsIn(Col("b"), _),
  )
  assert_true(
    IsBetween(
      Col("a"),
      Lit(@types.Scalar::Int(1)),
      Lit(@types.Scalar::Int(2)),
      @types.ClosedInterval::Both,
    ).rename_columns(m)
    is IsBetween(Col("b"), _, _, _),
  )
}

///|
test "rename_columns rewrites the closure nodes' inputs, not their closures" {
  let m = rename_map()
  let map_node = Map("m", [Col("a"), Col("z")], vs => vs[0])
  assert_true(
    map_node.rename_columns(m) is Map("m", inputs, _) &&
    inputs[0] is Col("b") &&
    inputs[1] is Col("z"),
  )
  let batches = MapBatches("mb", [Col("a")], false, cols => cols[0])
  assert_true(
    batches.rename_columns(m) is MapBatches("mb", inputs, false, _) &&
    inputs[0] is Col("b"),
  )
}

///|
test "rename_columns descends through diff and clip" {
  let m = rename_map()
  assert_true(Diff(Col("a"), 2).rename_columns(m) is Diff(Col("b"), 2))
  assert_true(
    Clip(Col("a"), Some(Col("z")), None).rename_columns(m)
    is Clip(Col("b"), Some(Col("z")), None),
  )
  assert_true(
    Clip(Col("z"), None, Some(Col("a"))).rename_columns(m)
    is Clip(Col("z"), None, Some(Col("b"))),
  )
  // The omitted halves stay omitted — a rename never invents a bound.
  assert_true(
    Clip(Col("a"), None, None).rename_columns(m) is Clip(Col("b"), None, None),
  )
}
