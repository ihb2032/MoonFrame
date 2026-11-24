// Blackbox tests of the Arrow IPC interchange on the io surface: the
// round trip under every compression and both framings, the projections,
// the refusals, the lazy source's push-downs against the eager read, and
// the sink's agreement with the whole-frame write.

///|
fn ipc_ints(
  name : String,
  cells : Array[Int64],
) -> @series.Series raise @types.DataError {
  @series.Series::from_scalars(
    name,
    cells.map(i => @types.Scalar::Int(i)),
    dtype=@types.DataType::Int,
  )
}

///|
fn ipc_lvs(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn ipc_struct(a : @types.Scalar, b : @types.Scalar) -> @types.Scalar {
  @types.Scalar::Struct(
    @types.StructValue::StructValue([
      @types.FieldValue::FieldValue("a", a),
      @types.FieldValue::FieldValue("b", b),
    ]),
  )
}

///|
fn ipc_decimal(text : String) -> @types.Scalar {
  @types.Scalar::Decimal(@types.Dec128::parse_opt(text).unwrap())
}

///|
/// A frame of every dtype the interchange carries, with nulls in each
/// column, a list, a struct, and a list of lists. Its decimals share one
/// scale, so they read back as they were written.
fn ipc_frame() -> @frame.DataFrame raise @types.DataError {
  let list = @types.DataType::List(@types.DataType::Int)
  let record = @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::String),
    ]),
  )
  @frame.DataFrame::DataFrame([
    ipc_ints("i", [1L, 2L, -3L]),
    @series.Series::from_scalars(
      "f",
      [
        @types.Scalar::Float(1.5),
        @types.Scalar::Null,
        @types.Scalar::Float(0.0 / 0.0),
      ],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "b",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Null,
        @types.Scalar::Bool(false),
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_scalars(
      "s",
      [
        @types.Scalar::String("héllo"),
        @types.Scalar::Null,
        @types.Scalar::String(""),
      ],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "d",
      [
        @types.Scalar::Date(0L),
        @types.Scalar::Date(20000L),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Date,
    ),
    @series.Series::from_scalars(
      "t",
      [
        @types.Scalar::Timestamp(0L),
        @types.Scalar::Timestamp(-1_704_067_200_000_000L),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Timestamp,
    ),
    @series.Series::from_scalars(
      "du",
      [
        @types.Scalar::Duration(1500000L),
        @types.Scalar::Null,
        @types.Scalar::Duration(-1L),
      ],
      dtype=@types.DataType::Duration,
    ),
    @series.Series::from_scalars(
      "dec",
      [ipc_decimal("1.50"), @types.Scalar::Null, ipc_decimal("-2.25")],
      dtype=@types.DataType::Decimal,
    ),
    @series.Series::from_scalars(
      "l",
      [
        ipc_lvs([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
        @types.Scalar::Null,
        ipc_lvs([]),
      ],
      dtype=list,
    ),
    @series.Series::from_scalars(
      "st",
      [
        ipc_struct(@types.Scalar::Int(1), @types.Scalar::String("x")),
        @types.Scalar::Null,
        ipc_struct(@types.Scalar::Null, @types.Scalar::String("")),
      ],
      dtype=record,
    ),
    @series.Series::from_scalars(
      "ll",
      [
        ipc_lvs([]),
        @types.Scalar::Null,
        ipc_lvs([ipc_lvs([@types.Scalar::Int(5)]), ipc_lvs([])]),
      ],
      dtype=@types.DataType::List(list),
    ),
  ])
}

///|
/// Whether two cells read the same: a float by its bits, so a NaN and a
/// negative zero are their own; a list or a struct cell by its cells.
fn ipc_same_cell(
  want : @types.Scalar,
  got : @types.Scalar,
) -> Bool raise @types.DataError {
  match (want, got) {
    (@types.Scalar::Float(a), @types.Scalar::Float(b)) =>
      a.reinterpret_as_int64() == b.reinterpret_as_int64()
    (@types.Scalar::List(a), @types.Scalar::List(b)) =>
      ipc_same_cells(a.cells(), b.cells())
    (@types.Scalar::Struct(a), @types.Scalar::Struct(b)) => {
      let wanted = a.fields()
      let gotten = b.fields()
      let mut same = wanted.length() == gotten.length()
      for i in 0..<wanted.length() {
        if wanted[i].name() != gotten[i].name() ||
          !ipc_same_cell(wanted[i].value(), gotten[i].value()) {
          same = false
        }
      }
      same
    }
    (a, b) => a == b
  }
}

///|
fn ipc_same_cells(
  want : Array[@types.Scalar],
  got : Array[@types.Scalar],
) -> Bool raise @types.DataError {
  if want.length() != got.length() {
    return false
  }
  let mut same = true
  for i in 0..<want.length() {
    if !ipc_same_cell(want[i], got[i]) {
      same = false
    }
  }
  same
}

///|
/// Whether a frame reads back as it was written: the same columns, in
/// order, each of the same dtype and the same cells.
fn ipc_assert_same(
  label : String,
  got : @frame.DataFrame,
  want : @frame.DataFrame,
) -> Unit raise {
  let mut same = got.shape() == want.shape() && got.columns() == want.columns()
  if same {
    for name in want.columns() {
      let a = got.get_column(name)
      let b = want.get_column(name)
      if a.dtype() != b.dtype() ||
        !ipc_same_cells(a.to_scalars().copy(), b.to_scalars().copy()) {
        same = false
      }
    }
  }
  if !same {
    fail(
      "\{label}: the frame reads back as \{got.nrows()} rows over \{got.columns().length()} columns, where it was written as \{want.nrows()} rows over \{want.columns().length()} columns",
    )
  }
}

///|
test "write_ipc / read_ipc round-trip every dtype under every compression and both framings" {
  let df = ipc_frame()
  let path = "_build/io_ipc_roundtrip.arrow"
  for
    compression in [
      @io.IpcCompression::Uncompressed,
      @io.IpcCompression::Lz4,
      @io.IpcCompression::Zstd,
    ] {
    for format in [@io.IpcFormat::File, @io.IpcFormat::Stream] {
      @io.write_ipc(df, path, compression~, format~)
      ipc_assert_same("the file", @io.read_ipc(path), df)
      // In-memory bytes read the same as the file they came from.
      let bytes = @fs.read_file_to_bytes(path)
      ipc_assert_same("the bytes", @io.parse_ipc(bytes), df)
    }
  }
}

///|
test "write_ipc takes the file framing by default" {
  let df = ipc_frame()
  let path = "_build/io_ipc_default.arrow"
  @io.write_ipc(df, path)
  let bytes = @fs.read_file_to_bytes(path)
  // The file format opens with `ARROW1` and two zero bytes, and closes
  // with the marker again.
  assert_true(bytes.has_prefix(b"ARROW1\x00\x00"))
  assert_true(bytes.has_suffix(b"ARROW1"))
  let stream_path = "_build/io_ipc_default.stream"
  @io.write_ipc(df, stream_path, format=@io.IpcFormat::Stream)
  let stream = @fs.read_file_to_bytes(stream_path)
  assert_false(stream.has_prefix(b"ARROW1"))
  // The stream format closes with its end marker: a continuation and a
  // zero length.
  let end = stream.length()
  assert_eq(stream[end - 8:end].to_owned(), b"\xFF\xFF\xFF\xFF\x00\x00\x00\x00")
}

///|
test "a decimal column reads back at its column's scale" {
  // A decimal column is one scale, the most fraction digits its cells
  // count; a cell counting fewer is lifted to it, and reads back there.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "d",
      [ipc_decimal("1.50"), ipc_decimal("0.001"), @types.Scalar::Null],
      dtype=@types.DataType::Decimal,
    ),
  ])
  let path = "_build/io_ipc_decimal.arrow"
  @io.write_ipc(df, path)
  assert_eq(@io.read_ipc(path).get_column("d").to_scalars().copy(), [
    ipc_decimal("1.500"),
    ipc_decimal("0.001"),
    @types.Scalar::Null,
  ])
}

///|
test "read_ipc's projection keeps the payload's column order and leaves the rest unread" {
  let df = ipc_frame()
  let path = "_build/io_ipc_projection.arrow"
  @io.write_ipc(df, path)
  // The projection names the columns it keeps; they answer in the
  // payload's own order.
  let picked = @io.read_ipc(path, projection=["l", "i"])
  assert_eq(picked.columns(), ["i", "l"])
  assert_eq(picked.shape(), (3, 2))
  // A name the payload does not carry builds no column, and the rows
  // still answer.
  let none = @io.read_ipc(path, projection=["i", "none", "l"])
  assert_eq(none.columns(), ["i", "l"])
  let empty = @io.read_ipc(path, projection=["none"])
  assert_eq(empty.shape(), (3, 0))
}

///|
test "read_ipc refuses a column its mapping does not carry, and a projection past it reads the rest" {
  // The sample's time-of-day columns have no dtype to read as; its dates
  // and timestamps do.
  let path = ".github/fixtures/arrow-ipc/1.0.0-littleendian/generated_datetime.stream"
  let whole = Ok(ignore(@io.read_ipc(path))) catch { e => Err(e) }
  assert_true(
    whole is Err(@types.DataError::Unsupported(message)) &&
    message.contains("column \"f2\" carries a time32 column"),
  )
  let dates = @io.read_ipc(path, projection=["f0", "f1", "f8"])
  assert_eq(dates.columns(), ["f0", "f1", "f8"])
  // The sample carries its rows over more than one record batch.
  assert_eq(dates.shape(), (17, 3))
  assert_eq(dates.get_column("f0").dtype(), @types.DataType::Date)
  assert_eq(dates.get_column("f1").dtype(), @types.DataType::Timestamp)
}

///|
test "a missing file and an empty file refuse" {
  let result = Ok(ignore(@io.read_ipc("_build/io_ipc_absent.arrow"))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
  // A scan defers the read to its collection, and refuses the same way
  // there.
  let scanned = Ok(ignore(@io.scan_ipc("_build/io_ipc_absent.arrow").collect())) catch {
    e => Err(e)
  }
  assert_true(scanned is Err(@types.DataError::IoError(_)))
  let empty_path = "_build/io_ipc_empty.arrow"
  @fs.write_bytes_to_file(empty_path, b"")
  let empty = Ok(ignore(@io.read_ipc(empty_path))) catch { e => Err(e) }
  assert_true(empty is Err(@types.DataError::ParseError(_)))
  // So does a text file: nothing in it opens a schema message.
  let text_path = "_build/io_ipc_text.arrow"
  @fs.write_bytes_to_file(text_path, b"hello,world\n1,2\n")
  let text = Ok(ignore(@io.read_ipc(text_path))) catch { e => Err(e) }
  assert_true(text is Err(@types.DataError::ParseError(_)))
}

///|
test "a write to an unwritable path raises the io error" {
  let df = ipc_frame()
  let result = Ok(ignore(@io.write_ipc(df, "_build/no-such-dir/x.arrow"))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
  // So does a sunk plan: the payload is finished, and its write refuses.
  let sunk = Ok(
    ignore(
      @io.sink_ipc(
        @frame.LazyFrame::LazyFrame(df),
        "_build/no-such-dir/x.arrow",
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(sunk is Err(@types.DataError::IoError(_)))
}

///|
test "write_ipc keeps a frame with no column, or no row, as it was" {
  // A frame of rows with no fields keeps its height.
  let rows = @frame.DataFrame::from_rows(
    @types.Schema::Schema([]),
    Array::makei(3, _ => []),
  )
  let path = "_build/io_ipc_n_by_0.arrow"
  @io.write_ipc(rows, path)
  assert_eq(@io.read_ipc(path).shape(), (3, 0))
  // A frame of columns with no rows keeps its columns and their dtypes.
  let full = ipc_frame()
  let columns_path = "_build/io_ipc_0_by_n.arrow"
  @io.write_ipc(full.slice(0, length=0), columns_path)
  let back = @io.read_ipc(columns_path)
  assert_eq(back.shape(), (0, 11))
  assert_eq(back.columns(), full.columns())
  assert_eq(back.get_column("st").dtype(), full.get_column("st").dtype())
  // And a frame with neither.
  let bare_path = "_build/io_ipc_0_by_0.arrow"
  @io.write_ipc(@frame.DataFrame::DataFrame([]), bare_path)
  assert_eq(@io.read_ipc(bare_path).shape(), (0, 0))
}

///|
/// A file of three record batches, two rows each: `i` runs 1 to 6, and `s`
/// carries each batch's own name on its two rows.
fn ipc_batches(
  path : String,
  names : Array[String],
) -> Unit raise @types.DataError {
  let sink = @ipc.IpcSink::sink(None, file=true)
  for b in 0..<3 {
    sink.push([
      ipc_ints("i", [b.to_int64() * 2L + 1L, b.to_int64() * 2L + 2L]),
      @series.Series::from_strings("s", [names[b], names[b]]),
    ])
  }
  // The payload is finished before the write is in sight: the catch is
  // for the write's error alone.
  let bytes = sink.finish()
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
test "a sunk window reads the record batches it needs" {
  // A multi-batch file under a sunk window: the window absorbs into the
  // scan leaf, the batches outside it never decode, and the collected
  // rows are exactly the eager read's.
  let path = "_build/io_ipc_window.arrow"
  ipc_batches(path, ["a", "b", "c"])
  assert_eq(
    @io.scan_ipc(path).head(2).explain(optimized=true),
    "SCAN_IPC \"_build/io_ipc_window.arrow\" WINDOW HEAD 2",
  )
  let head = @io.scan_ipc(path)
    .head(2)
    .collect()
    .get_column("i")
    .to_scalars()
    .copy()
  assert_eq(head, [@types.Scalar::Int(1), @types.Scalar::Int(2)])
  let tail = @io.scan_ipc(path)
    .tail(2)
    .collect()
    .get_column("i")
    .to_scalars()
    .copy()
  assert_eq(tail, [@types.Scalar::Int(5), @types.Scalar::Int(6)])
  let sliced = @io.scan_ipc(path)
    .slice(-3)
    .collect()
    .get_column("i")
    .to_scalars()
    .copy()
  assert_eq(sliced, [
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
    @types.Scalar::Int(6),
  ])
  // A window cut through a batch keeps only the overlapping rows.
  let middle = @io.scan_ipc(path)
    .slice(1, length=3)
    .collect()
    .get_column("s")
    .to_scalars()
    .copy()
  assert_eq(middle, [
    @types.Scalar::String("a"),
    @types.Scalar::String("b"),
    @types.Scalar::String("b"),
  ])
  // A window that ends inside a batch keeps its rows up to that end.
  let three = @io.scan_ipc(path)
    .head(3)
    .collect()
    .get_column("s")
    .to_scalars()
    .copy()
  assert_eq(three, [
    @types.Scalar::String("a"),
    @types.Scalar::String("a"),
    @types.Scalar::String("b"),
  ])
  // The eager read answers the same rows.
  let eager = @io.read_ipc(path)
  assert_eq(eager.shape(), (6, 2))
  assert_eq(eager.head(2).get_column("i").to_scalars().copy(), head)
  assert_eq(eager.tail(2).get_column("i").to_scalars().copy(), tail)
  // And a narrowed scan matches the eager read exactly, in the payload's
  // column order.
  let narrowed = @io.scan_ipc(path).select([@expr.col("s"), @expr.col("i")])
  let kept = eager.select([@expr.col("s"), @expr.col("i")])
  assert_eq(narrowed.collect().columns(), kept.columns())
}

///|
test "an empty window still answers the columns" {
  // `head(0)` selects no rows, and the sunk window skips every batch —
  // but the collected frame keeps the schema, as an eager
  // read-then-head answers `0×N`.
  let path = "_build/io_ipc_empty_window.arrow"
  ipc_batches(path, ["a", "b", "c"])
  let got = @io.scan_ipc(path).head(0).collect()
  assert_eq(got.shape(), (0, 2))
  assert_eq(got.columns(), ["i", "s"])
  assert_eq(got.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(got.get_column("s").dtype(), @types.DataType::String)
}

///|
test "a refusal confined to a skipped record batch does not surface" {
  // The last batch's text is corrupted to bytes that are not UTF-8. A
  // read that reaches the batch refuses; a window that ends before it
  // never decodes it, and reads the rows before it exactly.
  let path = "_build/io_ipc_skipped_refusal.arrow"
  ipc_batches(path, ["alpha", "bravo", "charlie"])
  let bytes = @fs.read_file_to_bytes(path)
  let at = match bytes.find(b"charlie") {
    Some(i) => i
    None => fail("the last batch's text is not in the payload")
  }
  @fs.write_bytes_to_file(
    path,
    Bytes::makei(bytes.length(), i => if i == at { b'\xFF' } else { bytes[i] }),
  )
  let whole = Ok(ignore(@io.read_ipc(path))) catch { e => Err(e) }
  assert_true(
    whole
    is Err(
      @types.DataError::ParseError(@types.ParseErrorDetail::Message(message)),
    ) &&
    message.contains("not UTF-8"),
  )
  let before = @io.scan_ipc(path).head(4).collect()
  assert_eq(before.get_column("s").to_scalars().copy(), [
    @types.Scalar::String("alpha"),
    @types.Scalar::String("alpha"),
    @types.Scalar::String("bravo"),
    @types.Scalar::String("bravo"),
  ])
  // A window that reaches the corrupted batch meets the refusal, as the
  // eager read does.
  let reaching = Ok(ignore(@io.scan_ipc(path).tail(2).collect())) catch {
    e => Err(e)
  }
  assert_true(reaching is Err(@types.DataError::ParseError(_)))
}

///|
test "scan_ipc's predicate reads a column the projection drops" {
  // The pushed predicate's own columns ride the decode even when the
  // projection omits them.
  let path = "_build/io_ipc_predicate.arrow"
  ipc_batches(path, ["a", "b", "c"])
  let kept = @io.scan_ipc(path)
    .filter(@expr.col("i").gt(@expr.lit_int(3)))
    .select([@expr.col("s")])
    .collect()
  assert_eq(kept.columns(), ["s"])
  // Rows 4, 5, and 6 pass `i > 3`: the cut end of the second batch and
  // the whole of the third.
  assert_eq(kept.get_column("s").to_scalars().copy(), [
    @types.Scalar::String("b"),
    @types.Scalar::String("c"),
    @types.Scalar::String("c"),
  ])
  // The eager filter answers the same rows.
  let eager = @io.read_ipc(path)
    .filter(@expr.col("i").gt(@expr.lit_int(3)))
    .select([@expr.col("s")])
  assert_eq(kept.get_column("s"), eager.get_column("s"))
}

///|
test "sink_ipc writes what write_ipc writes for one batch, and one record batch per batch otherwise" {
  let df = ipc_frame()
  let written = "_build/io_ipc_written.arrow"
  @io.write_ipc(
    df,
    written,
    compression=@io.IpcCompression::Zstd,
    format=@io.IpcFormat::Stream,
  )
  let sunk = "_build/io_ipc_sunk.arrow"
  @io.sink_ipc(
    @frame.LazyFrame::LazyFrame(df),
    sunk,
    compression=@io.IpcCompression::Zstd,
    format=@io.IpcFormat::Stream,
  )
  assert_eq(@fs.read_file_to_bytes(sunk), @fs.read_file_to_bytes(written))
  // A plan answered in several batches lands as many record batches, and
  // reads back as the plan collects.
  let path = "_build/io_ipc_sink_batches.arrow"
  ipc_batches(path, ["a", "b", "c"])
  let out = "_build/io_ipc_sink_many.arrow"
  @io.sink_ipc(@io.scan_ipc(path), out, compression=@io.IpcCompression::Lz4)
  assert_eq(@ipc.open_ipc(@fs.read_file_to_bytes(out), None).batch_count(), 3)
  assert_eq(@io.read_ipc(out), @io.read_ipc(path))
  // A windowed plan sinks the batches the window kept — here the cut
  // end of one batch and the whole of the next — and reads back as the
  // window's rows.
  let windowed = "_build/io_ipc_sink_window.arrow"
  @io.sink_ipc(@io.scan_ipc(path).tail(3), windowed)
  assert_eq(
    @ipc.open_ipc(@fs.read_file_to_bytes(windowed), None).batch_count(),
    2,
  )
  assert_eq(@io.read_ipc(windowed).get_column("i").to_scalars().copy(), [
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
    @types.Scalar::Int(6),
  ])
  // An empty window sinks one empty batch, of the schema's columns.
  let empty = "_build/io_ipc_sink_empty.arrow"
  @io.sink_ipc(@io.scan_ipc(path).head(0), empty)
  let empty_back = @io.read_ipc(empty)
  assert_eq(empty_back.shape(), (0, 2))
  assert_eq(empty_back.columns(), ["i", "s"])
}

///|
test "sink_ipc of a plan whose every row is filtered out writes the schema and no cell" {
  let path = "_build/io_ipc_sink_none_in.arrow"
  ipc_batches(path, ["a", "b", "c"])
  let out = "_build/io_ipc_sink_none.arrow"
  @io.sink_ipc(
    @io.scan_ipc(path).filter(@expr.col("i").gt(@expr.lit_int(100))),
    out,
  )
  // Whatever batches the pipeline answered — none, or empty ones — the
  // payload holds no cell, and reads as no row.
  let back = @io.read_ipc(out)
  assert_eq(back.nrows(), 0)
}
