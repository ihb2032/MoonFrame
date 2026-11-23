// Blackbox tests for the lazy sinks: a plan's streaming face turned to
// a file, equal to collect-then-write for the same options.

///|
test "sink_parquet answers the collected frame" {
  // A multi-group source under a filter: the file's groups follow the
  // pipeline's batches, and reading it back answers `collect` exactly.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5, 6]),
    @series.Series::from_string_options("s", [
      Some("a"),
      None,
      Some("c"),
      Some("d"),
      None,
      Some("f"),
    ]),
  ])
  let path_src = "_build/io_sink_source.parquet"
  @io.write_parquet(df, path_src, row_group_rows=2)
  let lf = @io.scan_parquet(path_src).filter(
    @expr.col("i").gt(@expr.lit_int(1)),
  )
  let path_out = "_build/io_sink_out.parquet"
  @io.sink_parquet(lf, path_out)
  let written = @io.read_parquet(path_out)
  let collected = lf.collect()
  assert_eq(written.shape(), collected.shape())
  assert_eq(written.columns(), collected.columns())
  for name in collected.columns() {
    assert_eq(
      written.get_column(name).to_scalars(),
      collected.get_column(name).to_scalars(),
    )
  }
  // A group bound inside the batch splits the batch's groups further.
  @io.sink_parquet(lf, path_out, row_group_rows=1)
  let regrouped = @io.read_parquet(path_out)
  assert_eq(regrouped.shape(), collected.shape())
  // The codec rides through.
  @io.sink_parquet(lf, path_out, codec=@io.ParquetCodec::Snappy)
  assert_eq(@io.read_parquet(path_out).shape(), collected.shape())
}

///|
test "sink_csv answers the formatted frame byte for byte" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5, 6]),
    @series.Series::from_string_options("s", [
      Some("a,b"),
      None,
      Some("c"),
      Some("d"),
      None,
      Some("f"),
    ]),
  ])
  let path_src = "_build/io_sink_source.parquet"
  @io.write_parquet(df, path_src, row_group_rows=2)
  let lf = @io.scan_parquet(path_src).with_columns([
    (@expr.col("i") * @expr.lit_int(2)).with_alias("d"),
  ])
  let path_out = "_build/io_sink_out.csv"
  @io.sink_csv(lf, path_out)
  let expected = @io.format_csv(lf.collect())
  @fs.write_string_to_file("_build/io_sink_expected.csv", expected)
  let got = @fs.read_file_to_bytes(path_out) catch { _ => b"" }
  let want = @fs.read_file_to_bytes("_build/io_sink_expected.csv") catch {
    _ => b""
  }
  assert_eq(got, want)
}

///|
test "a sink raises the read's own error" {
  // The missing column's error surfaces at the first pulled batch —
  // the same error `collect` raises, and nothing is written.
  let lf = @frame.LazyFrame::LazyFrame(
    @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [1])]),
  ).filter(@expr.col("nope").gt(@expr.lit_int(0)))
  let result = Ok(ignore(@io.sink_parquet(lf, "_build/io_sink_none.parquet"))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ColumnNotFound(_)))
}

///|
test "the sinks carry the codec and refuse an unwritable path" {
  let lf = @frame.LazyFrame::LazyFrame(
    @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [1])]),
  )
  @io.sink_parquet(
    lf,
    "_build/io_sink_codec.parquet",
    codec=@io.ParquetCodec::Uncompressed,
  )
  assert_eq(@io.read_parquet("_build/io_sink_codec.parquet").nrows(), 1)
  @io.sink_parquet(
    lf,
    "_build/io_sink_codec.parquet",
    codec=@io.ParquetCodec::Gzip,
  )
  assert_eq(@io.read_parquet("_build/io_sink_codec.parquet").nrows(), 1)
  // A path into a directory that does not exist raises the write's own
  // IoError — the same error write_parquet would raise.
  let bad = Ok(ignore(@io.sink_parquet(lf, "_build/no_such_dir_z/out.parquet"))) catch {
    e => Err(e)
  }
  assert_true(bad is Err(@types.DataError::IoError(_)))
  let bad_csv = Ok(ignore(@io.sink_csv(lf, "_build/no_such_dir_z/out.csv"))) catch {
    e => Err(e)
  }
  assert_true(bad_csv is Err(@types.DataError::IoError(_)))
}
