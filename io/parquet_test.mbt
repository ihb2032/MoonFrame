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

///|
test "a sunk window reads the row groups it needs" {
  // A multi-group file under a sunk window: the head absorbs into the
  // scan leaf, the groups outside the window never decode, and the
  // collected rows are exactly the eager read's — across `head`, `tail`
  // (a window anchored at the file's end), and a negative-offset
  // `slice` that cuts through a group's middle.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5, 6]),
  ])
  let path = "_build/io_parquet_window_groups.parquet"
  @io.write_parquet(df, path, row_group_rows=2)
  // The head absorbed into the leaf — no `HEAD` node above it.
  assert_eq(
    @io.scan_parquet(path).head(2).explain(optimized=true),
    "SCAN_PARQUET \"_build/io_parquet_window_groups.parquet\" WINDOW HEAD 2",
  )
  let cells = @io.scan_parquet(path)
    .head(2)
    .collect()
    .get_column("i")
    .to_scalars()
  assert_eq(cells, [@types.Scalar::Int(1), @types.Scalar::Int(2)])
  let tail = @io.scan_parquet(path)
    .tail(2)
    .collect()
    .get_column("i")
    .to_scalars()
  assert_eq(tail, [@types.Scalar::Int(5), @types.Scalar::Int(6)])
  let sliced = @io.scan_parquet(path)
    .slice(-3)
    .collect()
    .get_column("i")
    .to_scalars()
  assert_eq(sliced, [
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
    @types.Scalar::Int(6),
  ])
  // The eager read answers the same rows — the sunk window changed which
  // groups decode, never which rows collect.
  let eager_head = @io.read_parquet(path).head(2).get_column("i").to_scalars()
  assert_eq(cells, eager_head)
}

///|
test "an empty window still answers the columns" {
  // `head(0)` selects no rows, and the sunk window skips every row
  // group — but the collected frame keeps the schema, exactly as an
  // eager read-then-head answers `0×N`, not `0×0`.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4]),
    @series.Series::from_string_options("s", [Some("a"), None, Some("c"), None]),
  ])
  let path = "_build/io_parquet_empty_window.parquet"
  @io.write_parquet(df, path, row_group_rows=2)
  let got = @io.scan_parquet(path).head(0).collect()
  let eager = @io.read_parquet(path).head(0)
  assert_eq(got.shape(), eager.shape())
  assert_eq(got.columns(), eager.columns())
  assert_eq(got.get_column("i").dtype(), @types.DataType::Int)
}

///|
test "collect_batches walks a parquet file's row groups" {
  // The batch boundaries are the file's own: one batch per row group,
  // in the groups' declared order, and a trailing flow (a filter) keeps
  // those boundaries while a trailing block (a sort) answers one batch.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5, 6]),
  ])
  let path = "_build/io_parquet_batches.parquet"
  @io.write_parquet(df, path, row_group_rows=2)
  let stream = @io.scan_parquet(path).collect_batches()
  let rows : Array[Array[@types.Scalar]] = []
  while true {
    match stream.next() {
      Some(batch) => rows.push(batch.get_column("i").to_scalars().copy())
      None => break
    }
  }
  assert_eq(rows.length(), 3)
  assert_eq(rows[0], [@types.Scalar::Int(1), @types.Scalar::Int(2)])
  assert_eq(rows[2], [@types.Scalar::Int(5), @types.Scalar::Int(6)])
  // A trailing filter flows: the batches stay the row groups'.
  let filtered = @io.scan_parquet(path)
    .filter(@expr.col("i").gt(@expr.lit_int(1)))
    .collect_batches()
  let kept : Array[Int32] = []
  while true {
    match filtered.next() {
      Some(batch) => kept.push(batch.nrows())
      None => break
    }
  }
  assert_eq(kept, [1, 2, 2])
  // A trailing sort blocks: the whole frame answers as one batch.
  let sorted = @io.scan_parquet(path)
    .sort([(@expr.col("i"), true, false)])
    .collect_batches()
  match sorted.next() {
    Some(batch) =>
      assert_eq(batch.get_column("i").to_scalars(), [
        @types.Scalar::Int(6),
        @types.Scalar::Int(5),
        @types.Scalar::Int(4),
        @types.Scalar::Int(3),
        @types.Scalar::Int(2),
        @types.Scalar::Int(1),
      ])
    None => fail("a sorted plan answers one batch")
  }
  assert_true(sorted.next() is None)
}

///|
test "write_parquet keeps an N-by-0 frame's height" {
  let df = @frame.DataFrame::from_rows(
    @types.Schema::Schema([]),
    Array::makei(3, _ => []),
  )
  let path = "_build/io_parquet_n_by_0.parquet"
  @io.write_parquet(df, path)
  assert_eq(@io.read_parquet(path).shape(), (3, 0))
}
