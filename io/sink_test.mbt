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

///|
/// The text a sink left on disk, decoded the way a reader would.
fn sunk_text(path : String) -> String {
  let bytes = @fs.read_file_to_bytes(path) catch { _ => b"unreadable" }
  @utf8.decode(bytes) catch {
    _ => "undecodable"
  }
}

///|
/// The frame the JSON sinks are checked over: an integer, a string column
/// whose cells need the writers' escaping and carry nulls and an empty
/// cell, and a float column with a signed zero.
fn json_sink_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5, 6]),
    @series.Series::from_string_options("s", [
      Some("a,\"b\\c\n"),
      None,
      Some(""),
      Some("d,e"),
      None,
      Some("f\""),
    ]),
    @series.Series::from_floats("x", [1.5, -0.0, 2.25, 3.0, 4.75, 5.5]),
  ])
}

///|
test "sink_json answers the formatted frame byte for byte" {
  // A multi-group source under a filter: the batches' records share one
  // top-level array, and the file is what format_json spells for the
  // collected frame.
  let path_src = "_build/io_sink_source.parquet"
  @io.write_parquet(json_sink_frame(), path_src, row_group_rows=2)
  let lf = @io.scan_parquet(path_src).filter(
    @expr.col("i").gt(@expr.lit_int(1)),
  )
  let path_out = "_build/io_sink_out.json"
  @io.sink_json(lf, path_out)
  let expected = @io.format_json(lf.collect())
  @fs.write_string_to_file("_build/io_sink_expected.json", expected)
  let got = @fs.read_file_to_bytes(path_out) catch { _ => b"" }
  let want = @fs.read_file_to_bytes("_build/io_sink_expected.json") catch {
    _ => b""
  }
  assert_eq(got, want)
  // One array, closed once, after the last batch's last record.
  assert_true(expected.has_suffix("}]"))
  assert_eq(@io.read_json(path_out).shape(), (5, 3))
}

///|
test "sink_ndjson answers the formatted frame byte for byte" {
  let path_src = "_build/io_sink_source.parquet"
  @io.write_parquet(json_sink_frame(), path_src, row_group_rows=2)
  let lf = @io.scan_parquet(path_src).with_columns([
    (@expr.col("i") * @expr.lit_int(2)).with_alias("d"),
  ])
  let path_out = "_build/io_sink_out.ndjson"
  @io.sink_ndjson(lf, path_out)
  let expected = @io.format_ndjson(lf.collect())
  assert_eq(sunk_text(path_out), expected)
  assert_eq(@io.read_ndjson(path_out).shape(), (6, 4))
}

///|
test "the json sinks join the batches with the writers' own separators" {
  // One row group per batch, one batch per pull: a record is separated
  // from the record before it by a single comma across a batch boundary,
  // and an NDJSON line ends with its newline at one.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3]),
    @series.Series::from_string_options("s", [Some("a"), None, Some("c")]),
  ])
  let path_src = "_build/io_sink_source.parquet"
  @io.write_parquet(df, path_src, row_group_rows=1)
  let lf = @io.scan_parquet(path_src)
  let mut batches = 0
  let stream = lf.collect_batches()
  while true {
    match stream.next() {
      Some(_) => batches = batches + 1
      None => break
    }
  }
  assert_eq(batches, 3)
  @io.sink_json(lf, "_build/io_sink_out.json")
  assert_eq(
    sunk_text("_build/io_sink_out.json"),
    "[{\"i\":1,\"s\":\"a\"},{\"i\":2,\"s\":null},{\"i\":3,\"s\":\"c\"}]",
  )
  @io.sink_ndjson(lf, "_build/io_sink_out.ndjson")
  assert_eq(
    sunk_text("_build/io_sink_out.ndjson"),
    "{\"i\":1,\"s\":\"a\"}\n{\"i\":2,\"s\":null}\n{\"i\":3,\"s\":\"c\"}\n",
  )
}

///|
test "the json sinks write an empty plan as the writers write an empty frame" {
  // No record reaches the sink — a filter no row survives, and a blank
  // file — and the files are what format_json / format_ndjson spell for
  // what collect answers.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("v", [1, 2, 3]),
  ])
  let path_src = "_build/io_sink_source.parquet"
  @io.write_parquet(df, path_src, row_group_rows=1)
  let none = @io.scan_parquet(path_src).filter(
    @expr.col("v").gt(@expr.lit_int(10)),
  )
  @fs.write_string_to_file("_build/io_sink_blank.csv", "")
  let blank = @io.scan_csv("_build/io_sink_blank.csv")
  for lf in [none, blank] {
    @io.sink_json(lf, "_build/io_sink_out.json")
    assert_eq(
      sunk_text("_build/io_sink_out.json"),
      @io.format_json(lf.collect()),
    )
    @io.sink_ndjson(lf, "_build/io_sink_out.ndjson")
    assert_eq(
      sunk_text("_build/io_sink_out.ndjson"),
      @io.format_ndjson(lf.collect()),
    )
  }
  assert_eq(sunk_text("_build/io_sink_out.json"), "[]")
  assert_eq(sunk_text("_build/io_sink_out.ndjson"), "")
}

///|
test "the json sinks raise the read's own error and refuse what the writers refuse" {
  // The missing column's error surfaces at the first pulled batch — the
  // same error collect raises.
  let broken = @frame.LazyFrame::LazyFrame(
    @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [1])]),
  ).filter(@expr.col("nope").gt(@expr.lit_int(0)))
  let bad_json = Ok(ignore(@io.sink_json(broken, "_build/io_sink_none.json"))) catch {
    e => Err(e)
  }
  assert_true(bad_json is Err(@types.DataError::ColumnNotFound(_)))
  let bad_ndjson = Ok(
    ignore(@io.sink_ndjson(broken, "_build/io_sink_none.ndjson")),
  ) catch {
    e => Err(e)
  }
  assert_true(bad_ndjson is Err(@types.DataError::ColumnNotFound(_)))
  // A path into a directory that does not exist raises the write's own
  // IoError.
  let plain = @frame.LazyFrame::LazyFrame(
    @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [1])]),
  )
  let lost_json = Ok(
    ignore(@io.sink_json(plain, "_build/no_such_dir_z/out.json")),
  ) catch {
    e => Err(e)
  }
  assert_true(lost_json is Err(@types.DataError::IoError(_)))
  let lost_ndjson = Ok(
    ignore(@io.sink_ndjson(plain, "_build/no_such_dir_z/out.ndjson")),
  ) catch {
    e => Err(e)
  }
  assert_true(lost_ndjson is Err(@types.DataError::IoError(_)))
  // A lone surrogate is the writers' refusal, for either framing.
  let lone = @frame.LazyFrame::LazyFrame(
    @frame.DataFrame::DataFrame([
      @series.Series::from_strings("s", [lone_surrogate_str(0xD800)]),
    ]),
  )
  let lone_json = Ok(ignore(@io.sink_json(lone, "_build/io_sink_lone.json"))) catch {
    e => Err(e)
  }
  assert_true(lone_json is Err(@types.DataError::InvalidOperation(_)))
  let lone_ndjson = Ok(
    ignore(@io.sink_ndjson(lone, "_build/io_sink_lone.ndjson")),
  ) catch {
    e => Err(e)
  }
  assert_true(lone_ndjson is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "a read error past the first batch comes before the surrogate refusal" {
  // The first batch carries a lone surrogate and a later batch fails to
  // read — here a SQL answer whose later cells refuse the dtype the first
  // batch settled: the text is written only once the plan has answered, so
  // the error is the read's own — the error collect raises, and the one
  // collect-then-write_json raises.
  let late_double = tally_ints(5000, k => {
    if k < 4096 {
      Int64(k.to_int64())
    } else {
      Double(k.to_double())
    }
  })
  let lone = lone_surrogate_str(0xD800)
  let plan = @io.scan_sql(late_double, "select").with_columns([
    @expr.lit_str(lone).with_alias("s"),
  ])
  let stream = plan.collect_batches()
  let first = Ok(stream.next()) catch { e => Err(e) }
  guard first is Ok(Some(batch)) else { fail("the first batch should answer") }
  assert_eq(batch.nrows(), 4096)
  assert_eq(batch.get_column("s").to_scalars()[0], @types.Scalar::String(lone))
  let second = Ok(ignore(stream.next())) catch { e => Err(e) }
  assert_true(second is Err(_))
  let collected = Ok(ignore(plan.collect())) catch { e => Err(e) }
  assert_true(collected is Err(_))
  let sunk = Ok(ignore(@io.sink_json(plan, "_build/io_sink_late.json"))) catch {
    e => Err(e)
  }
  assert_eq(sunk, collected)
  let sunk_lines = Ok(
    ignore(@io.sink_ndjson(plan, "_build/io_sink_late.ndjson")),
  ) catch {
    e => Err(e)
  }
  assert_eq(sunk_lines, collected)
}

///|
test "the json sinks compress a .gz path as the writers do" {
  let lf = @frame.LazyFrame::LazyFrame(
    @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [1, 2])]),
  )
  @io.sink_json(lf, "_build/io_sink_out.json.gz")
  assert_eq(@io.read_json("_build/io_sink_out.json.gz").shape(), (2, 1))
  @io.sink_ndjson(lf, "_build/io_sink_out.ndjson.gz")
  assert_eq(@io.read_ndjson("_build/io_sink_out.ndjson.gz").shape(), (2, 1))
}
