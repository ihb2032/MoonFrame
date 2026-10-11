// Whitebox pins for the Parquet column mapping: every `ParquetColumnData`
// variant fed straight into the frame assembly (the external fixture only
// exercises the row-form `Values` path its optional columns degrade to),
// plus the error arms — a non-UTF8 payload, a malformed document, a
// missing file.

///|
/// One column-chunk-to-frame mapping, in isolation.
fn one_chunk(
  name : String,
  t : @parquet.ColumnType,
  data : @parquet.ParquetColumnData,
) -> @frame.DataFrame raise @types.DataError {
  let columns = [@parquet.new_column(name, t, @parquet.Repetition::Required)]
  parquet_columnar_to_frame(
    @parquet.new_parquet_columnar_file(columns, [data], data.length(), None),
    None,
  )
}

///|
test "every columnar chunk variant maps onto its series" {
  let df = one_chunk(
    "b",
    @parquet.ColumnType::Boolean,
    @parquet.ParquetColumnData::BooleanValues([true, false]),
  )
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.item(0, "b"), @types.Scalar::Bool(true))
  let i32 = one_chunk(
    "i",
    @parquet.ColumnType::Int32,
    @parquet.ParquetColumnData::Int32Values([7, -7]),
  )
  assert_eq(i32.item(0, "i"), @types.Scalar::Int(7L))
  let ni32 = one_chunk(
    "i",
    @parquet.ColumnType::Int32,
    @parquet.ParquetColumnData::NullableInt32Values([Some(7), None]),
  )
  assert_true(ni32.item(1, "i") is @types.Scalar::Null)
  let i64 = one_chunk(
    "i",
    @parquet.ColumnType::Int64,
    @parquet.ParquetColumnData::Int64Values([9_223_372_036_854_775_807L]),
  )
  assert_eq(i64.item(0, "i"), @types.Scalar::Int(9_223_372_036_854_775_807L))
  let ni64 = one_chunk(
    "i",
    @parquet.ColumnType::Int64,
    @parquet.ParquetColumnData::NullableInt64Values([None, Some(1L)]),
  )
  assert_true(ni64.item(0, "i") is @types.Scalar::Null)
  // The timestamp mapping — the dtype the Parquet precision was matched to.
  let ts = one_chunk(
    "t",
    @parquet.ColumnType::TimestampMicros,
    @parquet.ParquetColumnData::TimestampMicrosValues([1704067200000000L]),
  )
  assert_eq(ts.item(0, "t").to_string(), "2024-01-01T00:00:00.000000")
  let nts = one_chunk(
    "t",
    @parquet.ColumnType::TimestampMicros,
    @parquet.ParquetColumnData::NullableTimestampMicrosValues([None]),
  )
  assert_true(nts.item(0, "t") is @types.Scalar::Null)
  let f32 = one_chunk(
    "f",
    @parquet.ColumnType::Float,
    @parquet.ParquetColumnData::FloatValues([1.5]),
  )
  assert_eq(f32.item(0, "f"), @types.Scalar::Float(1.5))
  let f64 = one_chunk(
    "f",
    @parquet.ColumnType::Double,
    @parquet.ParquetColumnData::DoubleValues([0.25]),
  )
  assert_eq(f64.item(0, "f"), @types.Scalar::Float(0.25))
  let txt = one_chunk(
    "s",
    @parquet.ColumnType::String,
    @parquet.ParquetColumnData::Utf8Values([@utf8.encode("hi")]),
  )
  assert_eq(txt.item(0, "s"), @types.Scalar::String("hi"))
  let ntxt = one_chunk(
    "s",
    @parquet.ColumnType::String,
    @parquet.ParquetColumnData::NullableUtf8Values([
      Some(@utf8.encode("hi")),
      None,
    ]),
  )
  assert_eq(ntxt.item(0, "s"), @types.Scalar::String("hi"))
  assert_true(ntxt.item(1, "s") is @types.Scalar::Null)
  // The unlabelled byte array reads as strict text, nulls preserved.
  let bin = one_chunk(
    "s",
    @parquet.ColumnType::Binary,
    @parquet.ParquetColumnData::BinaryValues([@utf8.encode("raw")]),
  )
  assert_eq(bin.item(0, "s"), @types.Scalar::String("raw"))
  assert_eq(bin.get_column("s").dtype(), @types.DataType::String)
  let nbin = one_chunk(
    "s",
    @parquet.ColumnType::Binary,
    @parquet.ParquetColumnData::NullableBinaryValues([
      None,
      Some(@utf8.encode("raw")),
    ]),
  )
  assert_true(nbin.item(0, "s") is @types.Scalar::Null)
  // The row-form chunk decodes per cell under the declared dtype.
  let rows = one_chunk(
    "v",
    @parquet.ColumnType::Int32,
    @parquet.ParquetColumnData::Values([
      @parquet.Value::Int32(3),
      @parquet.Value::Null,
    ]),
  )
  assert_eq(rows.item(0, "v"), @types.Scalar::Int(3L))
  assert_true(rows.item(1, "v") is @types.Scalar::Null)
  let strs = one_chunk(
    "v",
    @parquet.ColumnType::String,
    @parquet.ParquetColumnData::Values([@parquet.Value::String("x")]),
  )
  assert_eq(strs.item(0, "v"), @types.Scalar::String("x"))
}

///|
test "a non-UTF8 text payload refuses the read" {
  // A lone continuation byte is not UTF-8.
  let bad : Bytes = b"\x80"
  let res : Result[@frame.DataFrame, @types.DataError] = Ok(
    one_chunk(
      "s",
      @parquet.ColumnType::String,
      @parquet.ParquetColumnData::Utf8Values([bad]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(res is Err(@types.DataError::ParseError(_)))
}

///|
test "a malformed document and a missing file map to their errors" {
  assert_true(
    (Ok(ignore(parse_parquet(b"not parquet"))) catch { e => Err(e) })
    is Err(@types.DataError::IoError(_)),
  )
  assert_true(
    (Ok(ignore(read_parquet("no/such/file.parquet"))) catch { e => Err(e) })
    is Err(@types.DataError::IoError(_)),
  )
  assert_true(
    (Ok(
      ignore(
        write_parquet(
          @frame.DataFrame::from_rows(
            @types.Schema::Schema([
              @types.Field::Field("i", @types.DataType::Int),
            ]),
            [[@types.Scalar::Int(1L)]],
          ),
          "no/such/dir/out.parquet",
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::IoError(_)),
  )
}

///|
test "the scan driver reports a missing file through the same error" {
  let driver = parquet_scan_driver("no/such/source.parquet")
  let res : Result[@scan.ScanBatch, @types.DataError] = Ok(driver.scan()) catch {
    e => Err(e)
  }
  assert_true(res is Err(@types.DataError::IoError(_)))
}

///|
test "the cell mapping covers every variant, ahead of the write gate" {
  // The write path only reaches an Int / String column today (the upstream
  // writer's gate); the cell mapping itself is total, pinned here so the
  // writer widening its gate activates mapped arms that already hold.
  assert_true(parquet_cell(@types.Scalar::Int(1L)) is @parquet.Value::Int64(1L))
  assert_true(
    parquet_cell(@types.Scalar::Float(0.5)) is @parquet.Value::Double(0.5),
  )
  assert_true(
    parquet_cell(@types.Scalar::Bool(true)) is @parquet.Value::Boolean(true),
  )
  assert_true(
    parquet_cell(@types.Scalar::String("x")) is @parquet.Value::String("x"),
  )
  assert_true(
    parquet_cell(@types.Scalar::Timestamp(1L))
    is @parquet.Value::TimestampMicros(1L),
  )
  assert_true(parquet_cell(@types.Scalar::Null) is @parquet.Value::Null)
  assert_true(
    (Ok(ignore(parquet_cell(@types.Scalar::Date(0L)))) catch { e => Err(e) })
    is Err(@types.DataError::Unsupported(_)),
  )
  assert_true(
    (Ok(ignore(parquet_cell(@types.Scalar::Decimal(2, 1L)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
}

///|
test "the row-form chunk takes Int64 and Binary cells" {
  let wide = one_chunk(
    "v",
    @parquet.ColumnType::Int64,
    @parquet.ParquetColumnData::Values([
      @parquet.Value::Int64(2_147_483_648L),
      @parquet.Value::Null,
    ]),
  )
  assert_eq(wide.item(0, "v"), @types.Scalar::Int(2_147_483_648L))
  let blob = one_chunk(
    "v",
    @parquet.ColumnType::Binary,
    @parquet.ParquetColumnData::Values([
      @parquet.Value::Binary(@utf8.encode("blob")),
    ]),
  )
  assert_eq(blob.item(0, "v"), @types.Scalar::String("blob"))
}

///|
test "the row-form chunk takes a timestamp cell; a writer failure surfaces" {
  let ts_cell = one_chunk(
    "v",
    @parquet.ColumnType::TimestampMicros,
    @parquet.ParquetColumnData::Values([
      @parquet.Value::TimestampMicros(1704067200000000L),
    ]),
  )
  assert_eq(ts_cell.item(0, "v").to_string(), "2024-01-01T00:00:00.000000")
  // A frame with no columns makes the upstream writer refuse (its own
  // empty-schema guard), which surfaces through the same io error.
  let empty = @frame.DataFrame::from_rows(@types.Schema::Schema([]), [])
  assert_true(
    (Ok(ignore(format_parquet(empty))) catch { e => Err(e) })
    is Err(@types.DataError::IoError(_)),
  )
  // A corrupt file read through the driver (not just the eager parse)
  // surfaces the same way.
  @fs.write_bytes_to_file("_build/io_parquet_corrupt.parquet", b"junk")
  let driver = parquet_scan_driver("_build/io_parquet_corrupt.parquet")
  let res : Result[@scan.ScanBatch, @types.DataError] = Ok(driver.scan()) catch {
    e => Err(e)
  }
  assert_true(res is Err(@types.DataError::IoError(_)))
}

///|
test "a Null-dtype column refuses its write type" {
  // No frame can carry a Null-dtype column (it cannot be built), so this
  // arm is reached only by the type mapping's own contract.
  assert_true(
    (Ok(ignore(parquet_write_type(@types.DataType::Null))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
}
