///|
/// File-backed behaviour of the lazy NDJSON source, mirroring
/// `scan_csv_test.mbt`: `collect` reads through `@io`, projection push-down
/// narrows the parse to the columns a pipeline consumes, and the builders stay
/// total. Clean fixtures are written with `@io.write_ndjson`; the one fixture
/// that needs a column whose JSON type a typed frame cannot model — an `Int`
/// that later turns into a string — is written as raw text through `@fs`.
/// Plan-rendering snapshots live in `logical_plan_test.mbt` and
/// `optimize_test.mbt`.

///|
/// Write a small clean fixture frame to `path` as NDJSON.
fn write_ndjson_fixture(path : String) -> Unit raise @types.DataError {
  @io.write_ndjson(
    path,
    @frame.DataFrame::new([
      @series.Series::from_ints("qty", [5, 120, 80, 200]),
      @series.Series::from_int_options("bonus", [Some(1), None, Some(3), None]),
      @series.Series::from_strings("region", ["west", "east", "west", "east"]),
    ]),
  )
}

///|
/// Write raw bytes to `path`, surfacing a filesystem error as `IoError` so the
/// test body raises only `@types.DataError`, like every other lazy test.
fn write_raw(path : String, content : String) -> Unit raise @types.DataError {
  @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
test "scan_ndjson collects bitwise-equal to the eager read of the same file" {
  let path = "_build/lazy_scan_ndjson_roundtrip.ndjson"
  write_ndjson_fixture(path)
  let out = scan_ndjson(path).collect()
  assert_eq(out, @io.read_ndjson(path))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "scan_ndjson with projection push-down collects equal to the eager read then select" {
  let path = "_build/lazy_scan_ndjson_projection.ndjson"
  write_ndjson_fixture(path)
  // A single-column selection narrows the parse to `region`.
  let projection = [@expr.col("region")]
  assert_eq(
    scan_ndjson(path).select(projection).collect(),
    @io.read_ndjson(path).select(projection),
  )
  // A wider pipeline narrows through filter + with_columns and stays equal.
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let outputs = [@expr.col("dbl"), @expr.col("region")]
  let out = scan_ndjson(path)
    .filter(predicate)
    .with_columns(derived)
    .select(outputs)
    .collect()
  assert_eq(
    out,
    @io.read_ndjson(path)
    .filter(predicate)
    .with_columns(derived)
    .select(outputs),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "scan_ndjson_with_options honours the read options at collect time" {
  let path = "_build/lazy_scan_ndjson_options.ndjson"
  write_ndjson_fixture(path)
  let opts : @io.JsonReadOptions = @io.JsonReadOptions(infer_schema_rows=1)
  assert_eq(
    scan_ndjson_with_options(path, opts).select([@expr.col("region")]).collect(),
    @io.read_ndjson_with_options(path, opts).select([@expr.col("region")]),
  )
}

///|
test "projection push-down does not parse — or fail on — a dropped NDJSON column" {
  let path = "_build/lazy_scan_ndjson_dropped_error.ndjson"
  // `b` infers Int from the first record, then turns into a string — a column
  // a typed frame cannot model, so it is written as raw NDJSON text.
  write_raw(path, "{\"a\": 1, \"b\": 10}\n{\"a\": 2, \"b\": \"oops\"}\n")
  let opts : @io.JsonReadOptions = @io.JsonReadOptions(infer_schema_rows=1)
  // The full eager read builds `b` and fails on the non-Int cell.
  assert_eq(
    Ok(@io.read_ndjson_with_options(path, opts)) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Line,
          "b",
          2,
          @types.DataType::Int,
          "oops",
        ),
      ),
    ),
  )
  // The lazy scan, narrowed to `a`, never builds `b`, so it collects cleanly —
  // the same divergence as scan_csv (Polars' projection push-down).
  let out = scan_ndjson_with_options(path, opts)
    .select([@expr.col("a")])
    .collect()
  assert_eq(out.columns(), ["a"])
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "scan_ndjson builders are total; a missing file fails only at collect" {
  let absent = "_build/lazy_scan_ndjson_absent.ndjson"
  // Building and explaining never touch the file.
  assert_eq(
    scan_ndjson(absent).select([@expr.col("a")]).explain(optimized=true),
    "SELECT [col(a)]\n  SCAN_NDJSON \"_build/lazy_scan_ndjson_absent.ndjson\" [a]",
  )
  // Collect surfaces the missing file as IoError — through read_ndjson_projected
  // when a projection fired…
  assert_true(
    (Ok(scan_ndjson(absent).select([@expr.col("a")]).collect()) catch {
      e => Err(e)
    })
    is Err(@types.DataError::IoError(_)),
  )
  // …and through read_ndjson_with_options when none did.
  assert_true(
    (Ok(scan_ndjson(absent).collect()) catch { e => Err(e) })
    is Err(@types.DataError::IoError(_)),
  )
}
