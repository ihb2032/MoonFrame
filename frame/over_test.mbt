// Blackbox tests for `Expr::over` — the window wrapper. Pinned: an
// aggregating inner broadcasting over its group, a group-length transform
// landing cell-for-cell, multi-key partitions, a null key forming its own
// group, the naming rule (the inner's name, alias to rename), the
// length-mismatch and nesting refusals, the whole-frame contract against
// the equivalent group_by-then-join spelling, and the lazy layer carrying
// the window through with the optimizer's fences holding.

///|
/// g = a,a,a,b,b; x = 1..3 / 10,20; plus a null-key row at the end.
fn groups_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_string_options("g", [
      Some("a"),
      Some("a"),
      Some("a"),
      Some("b"),
      Some("b"),
      None,
    ]),
    Series::from_ints("x", [1, 2, 3, 10, 20, 99]),
  ])
}

///|
test "an aggregating over broadcasts its group's single cell" {
  let df = groups_df()
  let out = df.with_columns([
    @expr.col("x").sum().over([@expr.col("g")]).with_alias("total"),
  ])
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(6),
    @types.Scalar::Int(6),
    @types.Scalar::Int(6),
    @types.Scalar::Int(30),
    @types.Scalar::Int(30),
    @types.Scalar::Int(99),
  ])
  // Mean is Float; a null key is its own group.
  let means = df.select([
    @expr.col("x").mean().over([@expr.col("g")]).with_alias("m"),
  ])
  assert_eq(means.item(0, "m").to_string(), "2")
  assert_eq(means.item(3, "m").to_string(), "15")
  assert_eq(means.item(5, "m").to_string(), "99")
}

///|
test "a group-length transform lands cell-for-cell" {
  let df = groups_df()
  let out = df.with_columns([
    @expr.col("x").cum_sum().over([@expr.col("g")]).with_alias("cs"),
    @expr.col("x").shift(1).over([@expr.col("g")]).with_alias("lag"),
    @expr.col("x").rank().over([@expr.col("g")]).with_alias("r"),
  ])
  assert_eq(out.get_column("cs").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
    @types.Scalar::Int(6),
    @types.Scalar::Int(10),
    @types.Scalar::Int(30),
    @types.Scalar::Int(99),
  ])
  // The shift restarts inside each group, not across the frame.
  assert_eq(out.get_column("lag").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Null,
    @types.Scalar::Int(10),
    @types.Scalar::Null,
  ])
  // The ranks number within each group — the default Average method is
  // `Float`, the values distinct, so each lands on its whole rank.
  assert_eq(out.get_column("r").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(1.0),
  ])
}

///|
test "multiple keys partition by the composite" {
  let df = DataFrame::DataFrame([
    Series::from_strings("g", ["a", "a", "a", "a"]),
    Series::from_strings("h", ["x", "x", "y", "x"]),
    Series::from_ints("v", [1, 2, 3, 4]),
  ])
  let out = df.with_columns([
    @expr.col("v").sum().over([@expr.col("g"), @expr.col("h")]).with_alias("s"),
  ])
  assert_eq(out.get_column("s").to_scalars(), [
    // (a, x) holds rows 0, 1, 3 — sum 7; (a, y) holds row 2 alone.
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(3),
    @types.Scalar::Int(7),
  ])
}

///|
test "the window names itself after its inner expression" {
  let df = groups_df()
  let out = df.with_columns([@expr.col("x").sum().over([@expr.col("g")])])
  // The sum's own name is its operand's, so the window replaces `x`.
  assert_eq(out.get_column("x").to_scalars(), [
    @types.Scalar::Int(6),
    @types.Scalar::Int(6),
    @types.Scalar::Int(6),
    @types.Scalar::Int(30),
    @types.Scalar::Int(30),
    @types.Scalar::Int(99),
  ])
  // A literal inner names itself `literal`, never after a key — and the
  // window is still frame-tall: every row of every group carries the 7.
  let lit = df.select([
    @expr.lit_int(7).over([@expr.col("g")]).with_alias("seven"),
  ])
  assert_eq(lit.nrows(), 6)
  assert_eq(lit.get_column("seven").to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
  ])
}

///|
test "a group result of any other length refuses" {
  let df = groups_df()
  // A two-cell literal series cannot answer a three-row group.
  let bad = @expr.lit_series(Series::from_ints("two", [1, 2])).over([
    @expr.col("g"),
  ])
  let result : Result[DataFrame, @types.DataError] = Ok(
    df.select([bad.with_alias("s")]),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "windows do not nest, in the inner or in a key" {
  let df = groups_df()
  let nested = @expr.col("x")
    .sum()
    .over([@expr.col("g")])
    .with_alias("w")
    .over([@expr.col("g")])
  let inner_bad : Result[DataFrame, @types.DataError] = Ok(
    df.select([nested.with_alias("s")]),
  ) catch {
    e => Err(e)
  }
  assert_true(inner_bad is Err(@types.DataError::InvalidOperation(_)))
  let key_bad : Result[DataFrame, @types.DataError] = Ok(
    df.select([
      @expr.col("x")
      .sum()
      .over([@expr.col("g").sum().over([@expr.col("g")])])
      .with_alias("s"),
    ]),
  ) catch {
    e => Err(e)
  }
  assert_true(key_bad is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "a window does not reduce inside a group aggregation" {
  let df = groups_df()
  let result : Result[DataFrame, @types.DataError] = Ok(
    df
    .group_by([@expr.col("g")])
    .agg([@expr.col("x").sum().over([@expr.col("g")]).with_alias("s")]),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "a window column serves as a filter predicate" {
  let df = groups_df()
  let out = df.filter(
    @expr.col("x").sum().over([@expr.col("g")]).gt(@expr.lit_int(10)),
  )
  // Groups b (30) and the null key (99) sum above 10: three rows survive.
  assert_eq(out.nrows(), 3)
  assert_eq(out.get_column("g").to_scalars(), [
    @types.Scalar::String("b"),
    @types.Scalar::String("b"),
    @types.Scalar::Null,
  ])
}

///|
test "an over window agrees with group_by then join" {
  // The inner join drops the null-key row (a null key never matches), so
  // both sides start from the frame without it.
  let df = groups_df().filter(@expr.col("g").is_not_null())
  let windowed = df.with_columns([
    @expr.col("x").mean().over([@expr.col("g")]).with_alias("m"),
  ])
  let grouped = df
    .group_by([@expr.col("g")])
    .agg([@expr.col("x").mean().with_alias("m")])
    .join(df, JoinOptions::on([@expr.col("g")], how=JoinType::Inner))
  let by_row = grouped.sort([(@expr.col("x"), false, true)])
  assert_eq(
    windowed.get_column("m").to_scalars(),
    by_row.get_column("m").to_scalars(),
  )
}

///|
test "an empty frame evaluates its window to the inner's dtype" {
  let df = DataFrame::empty(
    @types.Schema::Schema([
      @types.Field::Field("g", @types.DataType::String),
      @types.Field::Field("x", @types.DataType::Int),
    ]),
  )
  let out = df.with_columns([
    @expr.col("x").sum().over([@expr.col("g")]).with_alias("s"),
  ])
  assert_eq(out.nrows(), 0)
  assert_eq(out.get_column("s").dtype(), @types.DataType::Int)
}

///|
test "an empty frame still evaluates its keys: a bad key name raises" {
  // The 0-row short-circuit must not swallow key errors — a 1-row frame
  // with the same window raises `ColumnNotFound` for `nope`, so a 0-row
  // one does too (`group_by`'s reading: keys evaluate before any grouping).
  let df = DataFrame::empty(
    @types.Schema::Schema([
      @types.Field::Field("g", @types.DataType::String),
      @types.Field::Field("x", @types.DataType::Int),
    ]),
  )
  let result : Result[DataFrame, @types.DataError] = Ok(
    df.with_columns([@expr.col("x").sum().over([@expr.col("nope")])]),
  ) catch {
    e => Err(e)
  }
  assert_eq(result, Err(@types.DataError::ColumnNotFound("nope")))
}

// Blackbox tests for the lazy layer's window support — `over` riding the
// deferred verbs, and the optimizer's fences holding: a predicate that
// reads a window column (or contains one) never sinks below the stage
// that defines it, because the window's cells read their group's rows.

///|
fn groups_frame() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
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
