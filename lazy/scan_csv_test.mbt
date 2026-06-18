///|
/// File-backed behaviour of the lazy CSV source: `collect` reads through
/// `@io`, projection push-down narrows the parse to the columns a pipeline
/// consumes, and the builders stay total — a missing file or a malformed CSV
/// only fails at collect. Fixtures are written under `_build/` (the build
/// directory) with `@io.write_csv`, the same pattern the `io` file tests use.
/// Plan-rendering snapshots — the `SCAN_CSV` node and its written projection —
/// live in `logical_plan_test.mbt` and `optimize_test.mbt`.

///|
/// Write a small 4×3 fixture frame to `path`. Numeric-only (no floats), so the
/// CSV round-trips dtype-for-dtype and an eager re-read equals what was
/// written — though the tests below compare a scan against the eager *read* of
/// the same file, the truly faithful baseline.
fn write_fixture(path : String) -> Unit raise @types.DataError {
  @io.write_csv(
    path,
    @frame.DataFrame::new([
      @series.Series::from_ints("qty", [5, 120, 80, 200]),
      @series.Series::from_int_options("bonus", [Some(1), None, Some(3), None]),
      @series.Series::from_strings("region", ["west", "east", "west", "east"]),
    ]),
  )
}

///|
test "scan_csv collects bitwise-equal to the eager read of the same file" {
  let path = "_build/lazy_scan_csv_roundtrip.csv"
  write_fixture(path)
  let out = scan_csv(path).collect()
  assert_eq(out, @io.read_csv(path))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "scan_csv with projection push-down collects equal to the eager read then select" {
  let path = "_build/lazy_scan_csv_projection.csv"
  write_fixture(path)
  // A single-column selection: the optimizer narrows the parse to `region`,
  // and the result still matches reading every column then selecting.
  let projection = [@expr.col("region")]
  assert_eq(
    scan_csv(path).select(projection).collect(),
    @io.read_csv(path).select(projection),
  )
  // A wider pipeline narrows through filter + with_columns and stays equal.
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let outputs = [@expr.col("dbl"), @expr.col("region")]
  let out = scan_csv(path)
    .filter(predicate)
    .with_columns(derived)
    .select(outputs)
    .collect()
  assert_eq(
    out,
    @io.read_csv(path).filter(predicate).with_columns(derived).select(outputs),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "scan_csv_with_options honours the read options at collect time" {
  let path = "_build/lazy_scan_csv_options.csv"
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("a", [1, 2]),
    @series.Series::from_strings("b", ["p", "q"]),
  ])
  let write_opts : @io.CsvWriteOptions = {
    header: true,
    delimiter: ';',
    null_value: "",
  }
  @io.write_csv_with_options(path, df, write_opts)
  let read_opts : @io.CsvReadOptions = {
    has_header: true,
    delimiter: ';',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: false,
    on_parse_error: @io.OnParseError::Raise,
    allow_nonfinite_floats: true,
  }
  // The `;` delimiter must reach the parser, and projection push-down must
  // narrow under those same options.
  assert_eq(
    scan_csv_with_options(path, read_opts).select([@expr.col("a")]).collect(),
    @io.read_csv_with_options(path, read_opts).select([@expr.col("a")]),
  )
}

///|
test "projection push-down does not parse — or fail on — a dropped column" {
  let path = "_build/lazy_scan_csv_dropped_error.csv"
  // `b` is clean for the first row then unparsable as the Int it infers, while
  // `a` is clean throughout.
  @io.write_csv(
    path,
    @frame.DataFrame::new([
      @series.Series::from_strings("a", ["1", "2"]),
      @series.Series::from_strings("b", ["10", "oops"]),
    ]),
  )
  let opts : @io.CsvReadOptions = {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 1,
    null_values: [""],
    strict_column_count: false,
    on_parse_error: @io.OnParseError::Raise,
    allow_nonfinite_floats: true,
  }
  // The full eager read parses `b` and fails on `oops`.
  assert_true(
    (Ok(@io.read_csv_with_options(path, opts)) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(_)),
  )
  // The lazy scan, narrowed to `a`, never parses `b`, so it collects cleanly —
  // the one place a narrowed CSV scan diverges from a full eager read
  // (matching Polars' projection push-down).
  let out = scan_csv_with_options(path, opts).select([@expr.col("a")]).collect()
  assert_eq(out.columns(), ["a"])
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "scan_csv builders are total; a missing file fails only at collect" {
  let absent = "_build/lazy_scan_csv_absent.csv"
  // Building and explaining never touch the file (the projection writes even
  // though the path does not exist).
  assert_eq(
    scan_csv(absent).select([@expr.col("a")]).explain(optimized=true),
    "SELECT [col(a)]\n  SCAN_CSV \"_build/lazy_scan_csv_absent.csv\" [a]",
  )
  // Collect surfaces the missing file as IoError — through read_csv_projected
  // when a projection fired…
  assert_true(
    (Ok(scan_csv(absent).select([@expr.col("a")]).collect()) catch {
      e => Err(e)
    })
    is Err(@types.DataError::IoError(_)),
  )
  // …and through read_csv_with_options when none did.
  assert_true(
    (Ok(scan_csv(absent).collect()) catch { e => Err(e) })
    is Err(@types.DataError::IoError(_)),
  )
}
