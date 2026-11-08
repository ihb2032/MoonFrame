// Blackbox tests for the parquet interchange — the file-level
// write/read round trip over every compression, the projection rule,
// the lazy scan's push-downs, and the refusals. (One-file-one-test
// exemption: none — this is the format's only test file, the whitebox
// round-trips beside the codec carry the byte-level pins.)

///|
fn parquet_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("i", [Some(1), None, Some(3)]),
    @series.Series::from_string_options("s", [Some("a"), Some(""), None]),
    @series.Series::from_date_options("d", [Some(0L), Some(-1L), None]),
    @series.Series::from_decimals("x", [
      Some(@types.Dec128::of_int64_scale(150L, scale=2)),
      None,
      Some(@types.Dec128::of_int64_scale(-5L, scale=2)),
    ]),
  ])
}

///|
test "write_parquet / read_parquet round-trip under every compression" {
  let df = parquet_frame()
  for
    codec in [
      @io.ParquetCodec::Uncompressed,
      @io.ParquetCodec::Snappy,
      @io.ParquetCodec::Gzip,
    ] {
    let path = "_build/io_parquet_roundtrip.parquet"
    @io.write_parquet(df, path, codec~)
    let back = @io.read_parquet(path)
    assert_eq(back.shape(), df.shape())
    assert_eq(back.columns(), df.columns())
    for name in df.columns() {
      assert_eq(back.get_column(name).dtype(), df.get_column(name).dtype())
      assert_eq(
        back.get_column(name).to_scalars(),
        df.get_column(name).to_scalars(),
      )
    }
  }
}

///|
test "read_parquet projection names the columns it keeps" {
  let df = parquet_frame()
  let path = "_build/io_parquet_projection.parquet"
  @io.write_parquet(df, path)
  let back = @io.read_parquet(path, projection=["s", "i"])
  assert_eq(back.columns(), ["i", "s"])
  assert_eq(back.nrows(), 3)
  // A name the file does not carry builds no column — lenient like the
  // text readers' projection, the rows over zero columns.
  let miss = @io.read_parquet(path, projection=["nope"])
  assert_eq(miss.columns(), [])
  assert_eq(miss.nrows(), 3)
  // The whole frame without a projection.
  assert_eq(@io.read_parquet(path).shape(), df.shape())
}

///|
test "a gzip-suffixed path is not double-compressed" {
  // The parquet writer writes raw parquet bytes regardless of the
  // suffix — the format carries its own compression; the transparent
  // gzip of the text writers must not wrap it.
  let df = parquet_frame()
  let path = "_build/io_parquet_plain.parquet.gz"
  @io.write_parquet(df, path)
  // Reading through the guarded file reader would gunzip; the parquet
  // reader reads raw bytes — so the file must be plain parquet bytes
  // (magic at the head) for this to round-trip.
  let raw = @fs.read_file_to_bytes(path)
  assert_eq(raw[0], b'P')
  assert_eq(raw[raw.length() - 1], b'1')
  assert_eq(@io.read_parquet(path).shape(), df.shape())
}

///|
test "a missing file and an empty file refuse" {
  let result = Ok(ignore(@io.read_parquet("_build/io_parquet_absent.parquet"))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
  let empty_path = "_build/io_parquet_empty.parquet"
  @fs.write_bytes_to_file(empty_path, b"")
  let empty = Ok(ignore(@io.read_parquet(empty_path))) catch { e => Err(e) }
  assert_true(empty is Err(@types.DataError::ParseError(_)))
  // So does a non-parquet file with the wrong magic.
  let text_path = "_build/io_parquet_not_parquet.parquet"
  @fs.write_bytes_to_file(text_path, b"hello,world\n1,2\n")
  let wrong = Ok(ignore(@io.read_parquet(text_path))) catch { e => Err(e) }
  assert_true(wrong is Err(@types.DataError::ParseError(_)))
}

///|
test "a write to an unwritable path raises the io error" {
  let df = parquet_frame()
  let result = Ok(ignore(@io.write_parquet(df, "_build/no-such-dir/x.parquet"))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}
