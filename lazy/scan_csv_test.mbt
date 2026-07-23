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
  let write_opts : @io.CsvWriteOptions = @io.CsvWriteOptions(delimiter=';')
  @io.write_csv(path, df, options=write_opts)
  let read_opts : @io.CsvReadOptions = @io.CsvReadOptions(delimiter=';')
  // The `;` delimiter must reach the parser, and projection push-down must
  // narrow under those same options.
  assert_eq(
    scan_csv(path, options=read_opts).select([@expr.col("a")]).collect(),
    @io.read_csv(path, options=read_opts).select([@expr.col("a")]),
  )
}

///|
test "scan_csv_with_options snapshots the null-token list" {
  let path = "_build/lazy_scan_csv_aliasing.csv"
  @io.write_csv(
    path,
    @frame.DataFrame::new([@series.Series::from_strings("a", ["NA", "x"])]),
  )
  let tokens = ["NA"]
  let read_opts : @io.CsvReadOptions = @io.CsvReadOptions(null_values=tokens)
  let planned = scan_csv(path, options=read_opts)
  // Mutating the caller's null-token list must not reach the captured plan:
  // "NA" stays a null token for the collect below. The options copy on
  // construction and hand back a copy from `null_values()`, so neither the
  // source array nor a read-back one aliases what the reader uses.
  tokens.clear()
  read_opts.null_values().clear()
  let fresh : @io.CsvReadOptions = @io.CsvReadOptions(null_values=["NA"])
  assert_eq(planned.collect(), @io.read_csv(path, options=fresh))
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
  let opts : @io.CsvReadOptions = @io.CsvReadOptions(infer_schema_rows=1)
  // The full eager read parses `b` and fails on `oops`.
  assert_eq(
    Ok(@io.read_csv(path, options=opts)) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Cell(
          @types.CellParseLocation::Row,
          "b",
          2,
          @types.DataType::Int,
          "oops",
        ),
      ),
    ),
  )
  // The lazy scan, narrowed to `a`, never parses `b`, so it collects cleanly —
  // the one place a narrowed CSV scan diverges from a full eager read
  // (matching Polars' projection push-down).
  let out = scan_csv(path, options=opts).select([@expr.col("a")]).collect()
  assert_eq(out.columns(), ["a"])
  assert_eq(out.item(1, "a"), @types.Scalar::Int(2))
}

///|
test "a projection matching no header keeps the row count and the as-built error" {
  // The optimizer writes the required-column set into the scan verbatim; it
  // cannot intersect with the file's header at plan time. When NO requested
  // name matches, the projected read used to build a 0×0 frame — losing the
  // 4-row count, so the slice below bounds-checked against 0 and raised
  // IndexOutOfBounds where the as-built plan raises ColumnNotFound. The
  // zero-match projection now falls back to a full read: optimized and
  // unoptimized plans surface the same error.
  let path = "_build/lazy_scan_csv_zero_match.csv"
  write_fixture(path)
  let plan = scan_csv(path).slice(0, 2).select([@expr.col("missing")])
  let optimized = Ok(plan.collect()) catch { e => Err(e) }
  assert_eq(optimized, Err(@types.DataError::ColumnNotFound("missing")))
  // Eager equivalent of the as-built plan: same error.
  let eager = Ok(@io.read_csv(path).slice(0, 2).select([@expr.col("missing")])) catch {
    e => Err(e)
  }
  assert_eq(optimized, eager)
  // A slice that only fits the real row count still collects when the
  // consumer exists: partial-match leniency is untouched.
  let ok = scan_csv(path).slice(0, 2).select([@expr.col("qty")]).collect()
  assert_eq(ok.shape(), (2, 1))
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

// ── predicate push-down ───────────────────────────────────────────────

///|
test "scan_csv with an absorbed predicate collects equal to the eager read then filter" {
  let path = "_build/lazy_scan_csv_predicate.csv"
  write_fixture(path)
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  assert_eq(
    scan_csv(path).filter(predicate).collect(),
    @io.read_csv(path).filter(predicate),
  )
  // With a projection on top, the scan reads `qty` to prune but hands up only
  // `region` — still cell-for-cell the eager chain.
  assert_eq(
    scan_csv(path).filter(predicate).select([@expr.col("region")]).collect(),
    @io.read_csv(path).filter(predicate).select([@expr.col("region")]),
  )
  // Two filters: one is absorbed, the other stays a node — same result.
  let second = @expr.col("region").eq(@expr.lit_str("east"))
  assert_eq(
    scan_csv(path).filter(predicate).filter(second).collect(),
    @io.read_csv(path).filter(predicate).filter(second),
  )
}

///|
test "an absorbed predicate sees every row, so an aggregate threshold agrees with eager" {
  let path = "_build/lazy_scan_csv_predicate_agg.csv"
  write_fixture(path)
  // The pruning phase builds the predicate's columns over the *whole* file, so
  // a mean-of-the-column threshold is the file's mean, not a partial one.
  let predicate = @expr.col("qty").gt(@expr.col("qty").mean())
  assert_eq(
    scan_csv(path).filter(predicate).collect(),
    @io.read_csv(path).filter(predicate),
  )
}

///|
test "an absorbed predicate reports the same errors as the eager filter" {
  let path = "_build/lazy_scan_csv_predicate_errors.csv"
  write_fixture(path)
  // A predicate naming a column the file lacks: the pruning phase never builds
  // it, so evaluation raises `ColumnNotFound` exactly as eager does.
  let missing = @expr.col("nope").gt(@expr.lit_int(1))
  assert_true(
    (Ok(scan_csv(path).filter(missing).collect()) catch { e => Err(e) })
    is Err(@types.DataError::ColumnNotFound("nope")),
  )
  // A non-Bool predicate is the same `TypeMismatch` either way.
  let not_bool = @expr.col("qty")
  assert_true(
    (Ok(scan_csv(path).filter(not_bool).collect()) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a column-less predicate on a scan keeps every row, matching eager" {
  let path = "_build/lazy_scan_csv_columnless_pred.csv"
  write_fixture(path)
  // A literal-true predicate references no column, so it must NOT be absorbed
  // into the scan: the pruner would build a zero-column key frame, INV7 would
  // collapse it to 0×0, and every one of the file's four rows would be dropped.
  // It stays a Filter above the scan and broadcasts over the fully-read frame,
  // so `collect` keeps all four rows exactly as the eager read-then-filter.
  let keep_all = @expr.lit_bool(true)
  let out = scan_csv(path).filter(keep_all).collect()
  assert_eq(out, @io.read_csv(path).filter(keep_all))
  assert_eq(out.shape(), (4, 3))
  assert_eq(out.check_invariants(), Ok(()))
  // `lit_bool(false)` also matches eager — but 0 rows either way, so testing
  // only the false case would have masked the bug: a lost row count yields 0
  // rows too. The true case is what distinguishes a correct fix.
  let keep_none = @expr.lit_bool(false)
  let none = scan_csv(path).filter(keep_none).collect()
  assert_eq(none, @io.read_csv(path).filter(keep_none))
  assert_eq(none.shape(), (0, 3))
}

///|
test "a parse error in a row the predicate drops no longer surfaces" {
  // The documented consequence of push-down, and the mirror of projection
  // push-down's own caveat: the dropped row's cells in columns the predicate
  // does not read are never parsed, so their errors cannot be reported.
  let path = "_build/lazy_scan_csv_predicate_caveat.csv"
  @fs.write_string_to_file(path, "qty,note\n5,1\n120,oops\n")
  // A one-row inference window locks `note` to Int from the first record, so
  // the second record's `oops` is a genuine cell parse error.
  let narrow = @io.CsvReadOptions(infer_schema_rows=1)
  // Eager: the whole file is parsed, so the bad cell fails the read.
  assert_true(
    (Ok(@io.read_csv(path, options=narrow)) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(_)),
  )
  // Lazy with a predicate that drops the offending row: `note` is only built
  // for the surviving row, which parses cleanly.
  let out = scan_csv(path, options=narrow)
    .filter(@expr.col("qty").lt(@expr.lit_int(50)))
    .collect()
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.item(0, "note"), @types.Scalar::Int(1))
  // A predicate that keeps the offending row still reports it.
  assert_true(
    (Ok(
      scan_csv(path, options=narrow)
      .filter(@expr.col("qty").gt(@expr.lit_int(50)))
      .collect(),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ParseError(_)),
  )
}
