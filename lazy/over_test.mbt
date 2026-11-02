// Blackbox tests for the lazy layer's window support — `over` riding the
// deferred verbs, and the optimizer's fences holding: a predicate that
// reads a window column (or contains one) never sinks below the stage
// that defines it, because the window's cells read their group's rows.

///|
fn groups_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_string_options("g", [
      Some("a"),
      Some("a"),
      Some("a"),
      Some("b"),
      Some("b"),
    ]),
    @series.Series::from_ints("x", [1, 2, 3, 10, 20]),
  ])
}

///|
test "a deferred with_columns window collects to its eager equivalent" {
  let df = groups_frame()
  let w = @expr.col("x").sum().over([@expr.col("g")]).with_alias("total")
  assert_eq(
    LazyFrame::LazyFrame(df).with_columns([w]).collect(),
    df.with_columns([w]),
  )
}

///|
test "a predicate reading a window column stays above its stage" {
  let df = groups_frame()
  let w = @expr.col("x").sum().over([@expr.col("g")]).with_alias("total")
  let explained = LazyFrame::LazyFrame(df)
    .with_columns([w])
    .filter(@expr.col("total").gt(@expr.lit_int(10)))
    .explain(optimized=true)
  assert_true(explained.contains(".over(col(g))"))
  let mut filter_at = -1
  let mut with_at = -1
  let lines = explained.split("\n").collect()
  for i in 0..<lines.length() {
    if lines[i].contains("FILTER") && filter_at < 0 {
      filter_at = i
    }
    if lines[i].contains("WITH_COLUMNS") && with_at < 0 {
      with_at = i
    }
  }
  // The rendered plan prints the outer stage first, so the filter sits
  // above (before) the with_columns that defines its column — the window
  // fence the predicate pass consults.
  assert_true(filter_at >= 0)
  assert_true(with_at >= 0)
  assert_true(filter_at < with_at)
  // And the collected result matches the eager spelling.
  assert_eq(
    LazyFrame::LazyFrame(df)
    .with_columns([w])
    .filter(@expr.col("total").gt(@expr.lit_int(10)))
    .collect(),
    df.with_columns([w]).filter(@expr.col("total").gt(@expr.lit_int(10))),
  )
}

///|
test "a window inside a filter predicate evaluates, and is not pushed" {
  let df = groups_frame()
  let predicate = @expr.col("x")
    .sum()
    .over([@expr.col("g")])
    .gt(@expr.lit_int(10))
  assert_eq(
    LazyFrame::LazyFrame(df).filter(predicate).collect(),
    df.filter(predicate),
  )
  // The predicate stays whole at the filter — no sinking through the scan
  // the way a bare-column predicate would.
  let explained = LazyFrame::LazyFrame(df)
    .filter(predicate)
    .explain(optimized=true)
  assert_true(explained.contains(".over(col(g))"))
  assert_true(explained.contains("FILTER"))
}
