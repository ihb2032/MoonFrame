// The lazy Parquet source: `scan_parquet` collects the eager read, a
// projection narrows the columns built, and an absorbed predicate filters
// the read exactly as the eager filter would.

///|
test "the lazy parquet source collects, projects, and filters" {
  let frame = @frame.DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("i", @types.DataType::Int),
      @types.Field::Field("s", @types.DataType::String),
    ]),
    [
      [@types.Scalar::Int(1L), @types.Scalar::String("west")],
      [@types.Scalar::Null, @types.Scalar::Null],
      [@types.Scalar::Int(-3L), @types.Scalar::String("east")],
    ],
  )
  let path = "_build/lazy_parquet_test_source.parquet"
  @io.write_parquet(frame, path)
  // Collect equals the eager read.
  // The plan renders the format token and the origin.
  let lf = scan_parquet(path)
  assert_eq(lf.explain(), "SCAN_PARQUET \"\{path}\"")
  // A projection narrows the columns built.
  let projected = lf.select([@expr.col("i")]).collect()
  assert_eq(projected.columns(), ["i"])
  assert_eq(
    lf.select([@expr.col("i")]).explain(optimized=true),
    "SELECT [col(i)]\n  SCAN_PARQUET \"\{path}\" [i]",
  )
  // An absorbed predicate filters the read — the eager filter, verbatim.
  let filtered = lf.filter(@expr.col("i").gt(@expr.lit_int(0L))).collect()
  assert_eq(filtered.nrows(), 1)
  assert_eq(filtered.item(0, "s"), @types.Scalar::String("west"))
  assert_eq(filtered, frame.filter(@expr.col("i").gt(@expr.lit_int(0L))))
}
