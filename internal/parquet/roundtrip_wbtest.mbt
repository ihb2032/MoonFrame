// Whitebox round-trips for the whole parquet codec — a frame of every
// writable dtype written and read back under each compression, plus the
// malformed-file refusals and the projection rule. The dtype coverage
// rides the MoonFrame surface this branch carries (the Duration rider
// lands on its own branch and adds its row here when they merge).

///|
fn sample_columns() -> Array[@series.Series] raise @types.DataError {
  [
    @series.Series::from_int_options("i", [
      Some(1),
      None,
      Some(-9_223_372_036_854_775_807L),
      Some(0L),
    ]),
    @series.Series::from_float_options("f", [
      Some(1.5),
      None,
      Some(-0.25),
      Some(1.0 / 0.0),
    ]),
    @series.Series::from_bool_options("b", [Some(true), None, Some(false), None]),
    @series.Series::from_string_options("s", [
      Some("alpha"),
      Some(""),
      None,
      Some("quote\"and,comma"),
    ]),
    @series.Series::from_date_options("d", [
      Some(0L),
      None,
      Some(11016L),
      Some(-1L),
    ]),
    @series.Series::from_timestamp_options("t", [
      Some(0L),
      Some(-1L),
      None,
      Some(1_704_121_460_123_456L),
    ]),
    @series.Series::from_decimal_options(2, "x", [
      Some(150L),
      None,
      Some(-5L),
      Some(9_223_372_036_854_775_807L),
    ]),
  ]
}

///|
fn names_of(columns : Array[@series.Series]) -> Array[String] {
  columns.map(c => c.name())
}

///|
test "parquet round-trips every dtype under every compression" {
  let columns = sample_columns()
  let names = names_of(columns)
  for codec_name in ["uncompressed", "snappy", "gzip"] {
    let codec = match codec_name {
      "snappy" => Snappy
      "gzip" => Gzip
      _ => Uncompressed
    }
    let bytes = write_parquet_bytes(columns, names, codec)
    // The magic on both ends.
    assert_eq(bytes.length() > 12, true)
    assert_eq(bytes[0], b'P')
    assert_eq(bytes[bytes.length() - 1], b'1')
    let read = read_parquet_columns(bytes, None)
    assert_eq(read.length(), columns.length())
    for i in 0..<columns.length() {
      let (name, series) = read[i]
      assert_eq(name, names[i])
      assert_eq(series.dtype(), columns[i].dtype())
      assert_eq(series.to_scalars(), columns[i].to_scalars())
    }
  }
}

///|
test "parquet round-trips an empty frame and a bare column" {
  let empty : Array[@series.Series] = []
  let bytes = write_parquet_bytes(empty, [], Uncompressed)
  assert_eq(read_parquet_columns(bytes, None).length(), 0)
  let single : Array[@series.Series] = [@series.Series::from_ints("only", [42])]
  let one = write_parquet_bytes(single, ["only"], Uncompressed)
  let read = read_parquet_columns(one, None)
  assert_eq(read.length(), 1)
  assert_eq(read[0].1.to_scalars(), [@types.Scalar::Int(42)])
  // A 0-row column round-trips its dtype.
  let zero_row : Array[@series.Series] = [
    @series.Series::from_int_options("z", []),
  ]
  let zero = write_parquet_bytes(zero_row, ["z"], Uncompressed)
  assert_eq(read_parquet_columns(zero, None)[0].1.dtype(), @types.DataType::Int)
}

///|
test "parquet projection reads the named columns only" {
  let columns = sample_columns()
  let bytes = write_parquet_bytes(columns, names_of(columns), Uncompressed)
  let read = read_parquet_columns(bytes, Some(["t", "i"]))
  assert_eq(read.length(), 2)
  assert_eq(read[0].0, "i")
  assert_eq(read[1].0, "t")
  // A misspelt name refuses.
  let result = Ok(ignore(read_parquet_columns(bytes, Some(["nope"])))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "malformed files refuse with located errors" {
  let columns = sample_columns()
  let whole = write_parquet_bytes(columns, names_of(columns), Uncompressed)
  // A truncated tail loses the magic / the length.
  for cut in [4, 10, whole.length() - 1] {
    if cut < whole.length() {
      let partial = Bytes::makei(cut, i => whole[i])
      let result = Ok(ignore(read_parquet_columns(partial, None))) catch {
        e => Err(e)
      }
      assert_true(result is Err(_))
    }
  }
  // A corrupted footer length — the most-significant byte (`n - 5`,
  // little-endian) set high names a footer far past the file.
  let n_whole = whole.length()
  let broken = Bytes::makei(n_whole, i => {
    if i == n_whole - 5 {
      (0x7F).to_byte()
    } else {
      whole[i]
    }
  })
  let result = Ok(ignore(read_parquet_columns(broken, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "the writer's own footer length and magic pin the file shape" {
  let columns = sample_columns()
  let bytes = write_parquet_bytes(columns, names_of(columns), Uncompressed)
  // The footer length prefix names the thrift bytes exactly between the
  // last page and the length itself — reading it back is what the
  // reader does; this pins that the writer wrote a self-consistent
  // file by succeeding. The trailing shape is 4 + len + 4.
  let n = bytes.length()
  assert_eq(bytes[n - 4], b'P')
  assert_eq(bytes[n - 1], b'1')
  // The length is little-endian: its low byte sits at `n - 8`.
  let len = bytes[n - 8].to_int() |
    (bytes[n - 7].to_int() << 8) |
    (bytes[n - 6].to_int() << 16) |
    (bytes[n - 5].to_int() << 24)
  assert_true(len > 0 && len < n)
}

///|
test "a written Duration round-trips as a bare INT64 column reading Int" {
  let columns : Array[@series.Series] = [
    @series.Series::from_duration_options("dur", [Some(0L), None, Some(61L)]),
  ]
  let bytes = write_parquet_bytes(columns, ["dur"], Uncompressed)
  let read = read_parquet_columns(bytes, None)
  assert_eq(read[0].1.dtype(), @types.DataType::Int)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(0),
    @types.Scalar::Null,
    @types.Scalar::Int(61),
  ])
}
