// Downstream facade smoke test.
//
// This module lives outside `ihb2032/MoonFrame` and imports ONLY the root
// facade (`@moonframe`), exactly as a real user would. It compiles a spread of
// typical pipelines; `moon check` here fails if the facade ever stops
// re-exporting a symbol a downstream program needs to *name*.
//
// It deliberately chains through the fluent intermediates — `when().then()
// .otherwise()`, `group_by().agg()`, and their lazy twins — without ever
// naming `WhenThen` / `WhenThenElse` / `GroupedDataFrame` / `LazyGroupBy`.
// Those types are `pub` in their home packages but are NOT re-exported by the
// facade; that this file compiles proves a caller never has to name one — dot
// resolution follows each step's return value. If a future change made one of
// them necessary to name, this fixture would stop compiling and force the
// question back into view.
//
// It is a compile fixture: `moon check` typechecks every chain. The assertions
// let it double as a runnable `moon test` if wired that way.

///|
/// Value types the facade must re-export, each named directly.
test "value types are reachable by name" {
  let dtype : @moonframe.DataType = @moonframe.DataType::Int
  let field : @moonframe.Field = @moonframe.Field::Field("a", dtype)
  let schema : @moonframe.Schema = @moonframe.Schema::Schema([field])
  let scalar : @moonframe.Scalar = @moonframe.Scalar::Int(1)
  assert_eq(schema.len(), 1)
  assert_eq(scalar.to_string(), "1")
  assert_true(field.nullable())
}

///|
/// Eager construction, expressions, operators, and the `when` conditional —
/// the ternary chain threads `WhenThen` / `WhenThenElse` without naming them.
test "eager expression pipeline" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("qty", [10, 3, 7]),
    @moonframe.Series::from_strings("region", ["west", "east", "west"]),
  ])
  let tagged = df.with_columns([
    @moonframe.when(@moonframe.col("qty").gt(@moonframe.lit_int(5)))
    .then(@moonframe.lit_str("big"))
    .otherwise(@moonframe.lit_str("small"))
    .with_alias("size"),
    (@moonframe.col("qty") + @moonframe.lit_int(1)).with_alias("qty1"),
  ])
  let big = tagged.filter(
    @moonframe.col("size")
    .eq(@moonframe.lit_str("big"))
    .land(@moonframe.col("qty").gt(@moonframe.lit_int(0))),
  )
  assert_eq(big.nrows(), 2)
  let _ = big.select(@moonframe.cols(["region", "qty"]))
  let _ = big.to_markdown()

}

///|
/// Group-by / aggregate — `group_by(...).agg(...)` chains `GroupedDataFrame`
/// without naming it — plus sort, unique, drop, and rename.
test "group-by, sort, and reshaping" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_strings("region", ["west", "east", "west"]),
    @moonframe.Series::from_ints("rev", [100, 50, 70]),
  ])
  let grouped = df
    .group_by([@moonframe.col("region")])
    .agg([
      @moonframe.col("rev").sum().with_alias("rev"),
      @moonframe.col("rev").count().with_alias("n"),
    ])
    .sort([
      (
        @moonframe.col("rev"),
        @moonframe.SortOrder::Desc,
        @moonframe.NullOrder::NullsLast,
      ),
    ])
  assert_eq(grouped.nrows(), 2)
  let _ = df.unique(subset=[@moonframe.col("region")])
  let _ = df.drop([@moonframe.col("rev")]).rename([("region", "r")])

}

///|
/// Join through `JoinOptions`.
test "join" {
  let left = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  let right = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_ints("score", [9, 8]),
  ])
  let joined = left.join(
    right,
    @moonframe.JoinOptions::on([@moonframe.col("id")]),
  )
  assert_eq(joined.ncols(), 3)
}

///|
/// Lazy layer — `LazyFrame::group_by(...).agg(...)` chains `LazyGroupBy`
/// without naming it — with `collect` / `explain`.
test "lazy pipeline" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_strings("k", ["x", "y", "x"]),
    @moonframe.Series::from_ints("v", [1, 2, 3]),
  ])
  let lf = @moonframe.LazyFrame::LazyFrame(df)
    .filter(@moonframe.col("v").gt(@moonframe.lit_int(0)))
    .group_by([@moonframe.col("k")])
    .agg([@moonframe.col("v").sum().with_alias("v")])
  let out = lf.collect()
  assert_eq(out.nrows(), 2)
  let _ = lf.explain()

}

///|
/// IO round-trip and the error type, named on the recovery path.
test "io and error handling" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("a", [1, 2]),
  ])
  let csv = @moonframe.format_csv(df)
  let back = @moonframe.parse_csv_str(csv)
  assert_eq(back.nrows(), 2)
  // The error type is nameable on a recovery boundary — a missing column
  // raises `DataError`, re-wrapped here into a `Result`.
  let r : Result[@moonframe.DataFrame, @moonframe.DataError] = Ok(
    df.select([@moonframe.col("missing")]),
  ) catch {
    e => Err(e)
  }
  assert_true(r is Err(_))
}
