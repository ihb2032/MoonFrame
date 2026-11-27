// Blackbox tests for the Avro interchange at the io layer — the
// file-level write/read round trip over every codec, the projection
// rule, the reference implementation's files through the entries, and
// the refusals a caller meets. (One-file-one-test exemption: none — this
// is the format's only test file at this layer; the codec's own tests
// sit beside it.)

///|
fn avro_frame() -> @frame.DataFrame raise @types.DataError {
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
test "write_avro / read_avro round-trip under every codec" {
  let df = avro_frame()
  for
    codec in [
      @io.AvroCodec::Null,
      @io.AvroCodec::Deflate,
      @io.AvroCodec::Snappy,
      @io.AvroCodec::Zstd,
    ] {
    let path = "_build/io_avro_roundtrip.avro"
    @io.write_avro(df, path, codec~)
    let back = @io.read_avro(path)
    assert_eq(back.shape(), df.shape())
    assert_eq(back.columns(), df.columns())
    for name in df.columns() {
      assert_eq(back.get_column(name).dtype(), df.get_column(name).dtype())
      assert_eq(
        back.get_column(name).to_scalars(),
        df.get_column(name).to_scalars(),
      )
    }
    // The bytes already in memory parse to the same frame.
    let bytes = @fs.read_file_to_bytes(path) catch { _ => b"" }
    assert_eq(@io.parse_avro(bytes).shape(), df.shape())
  }
  // No codec named: the blocks are stored as encoded, and the file
  // opens with the format's magic.
  @io.write_avro(df, "_build/io_avro_plain.avro")
  let raw = @fs.read_file_to_bytes("_build/io_avro_plain.avro") catch {
    _ => b""
  }
  assert_eq(raw[0], b'O')
  assert_eq(raw[3], b'\x01')
  assert_eq(@io.read_avro("_build/io_avro_plain.avro").shape(), df.shape())
}

///|
test "a gzip-suffixed path is not double-compressed" {
  // The Avro writer writes the container's bytes whatever the suffix: the
  // format carries its own block codecs, and the transparent gzip of the
  // text writers must not wrap it.
  let df = avro_frame()
  @io.write_avro(df, "_build/io_avro_plain.avro.gz")
  let raw = @fs.read_file_to_bytes("_build/io_avro_plain.avro.gz") catch {
    _ => b""
  }
  assert_eq(raw[0], b'O')
  assert_eq(@io.read_avro("_build/io_avro_plain.avro.gz").shape(), df.shape())
}

///|
test "read_avro projection names the columns it keeps" {
  let df = avro_frame()
  let path = "_build/io_avro_projection.avro"
  @io.write_avro(df, path, codec=@io.AvroCodec::Deflate)
  let back = @io.read_avro(path, projection=["s", "i"])
  assert_eq(back.columns(), ["i", "s"])
  assert_eq(back.nrows(), 3)
  // A name the file does not carry builds no column — lenient like the
  // other readers' projection, the rows over zero columns.
  let miss = @io.read_avro(path, projection=["nope"])
  assert_eq(miss.columns(), [])
  assert_eq(miss.nrows(), 3)
  // The whole frame without a projection, and the projection over bytes.
  assert_eq(@io.read_avro(path).shape(), df.shape())
  let bytes = @fs.read_file_to_bytes(path) catch { _ => b"" }
  assert_eq(@io.parse_avro(bytes, projection=["x"]).columns(), ["x"])
}

///|
test "the reference implementation's files read through the entries" {
  // A file the reference implementation wrote, under each block codec
  // it and the reader share.
  for file in ["null", "deflate", "snappy", "zstandard"] {
    let back = @io.read_avro(
      ".github/fixtures/avro/fastavro_types_\{file}.avro",
    )
    assert_eq(back.shape(), (3, 16))
    assert_eq(back.get_column("name").to_scalars(), [
      @types.Scalar::String("Zoë"),
      @types.Scalar::Null,
      @types.Scalar::String("日本語 – naïve 🌍"),
    ])
    assert_eq(back.get_column("birth").dtype(), @types.DataType::Date)
    assert_eq(back.get_column("amount").dtype(), @types.DataType::Decimal)
  }
}

///|
test "the Avro entries raise the errors a caller meets" {
  // A path that cannot be read is the read's IoError.
  let missing = Ok(ignore(@io.read_avro("_build/no_such_avro.avro"))) catch {
    e => Err(e)
  }
  assert_true(missing is Err(@types.DataError::IoError(_)))
  // A path that cannot be written is the write's IoError.
  let df = avro_frame()
  let unwritable = Ok(
    ignore(@io.write_avro(df, "_build/no_such_dir_z/out.avro")),
  ) catch {
    e => Err(e)
  }
  assert_true(unwritable is Err(@types.DataError::IoError(_)))
  // A column whose name the schema does not allow.
  let named = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("gdp/cap", [1]),
  ])
  let refused = Ok(ignore(@io.write_avro(named, "_build/io_avro_named.avro"))) catch {
    e => Err(e)
  }
  assert_eq(
    refused,
    Err(
      @types.DataError::InvalidOperation(
        "column \"gdp/cap\": the name \"gdp/cap\" is not one an Avro schema allows (letters, digits and _, starting with a letter or _)",
      ),
    ),
  )
  // A column of a dtype the schema has no type for.
  let spanned = @frame.DataFrame::DataFrame([
    @series.Series::from_duration_options("span", [Some(5L)]),
  ])
  let span = Ok(ignore(@io.write_avro(spanned, "_build/io_avro_span.avro"))) catch {
    e => Err(e)
  }
  assert_eq(
    span,
    Err(
      @types.DataError::Unsupported(
        "Avro: a column \"span\" of dtype Duration: the schema's logical types name no span",
      ),
    ),
  )
  // Bytes that are no container at all.
  let junk = Ok(ignore(@io.parse_avro(b"not an avro file"))) catch {
    e => Err(e)
  }
  assert_eq(
    junk,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "malformed Avro: bytes that do not open with the Avro magic",
        ),
      ),
    ),
  )
}
