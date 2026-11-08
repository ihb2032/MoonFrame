// Whitebox round-trips for the whole parquet codec — a frame of every
// writable dtype written and read back under each compression, plus the
// malformed-file refusals and the projection rule. The dtype coverage
// rides the MoonFrame surface this branch carries (the Duration rider
// lands on its own branch and adds its row here when they merge).

///|
/// The picked columns alone — the whitebox tests' spelling of the read;
/// production rides `read_parquet_frame`, whose single footer walk
/// answers the columns and the row count together.
fn read_parquet_columns(
  bytes : Bytes,
  projection : Array[String]?,
) -> Array[(String, @series.Series)] raise @types.DataError {
  read_parquet_frame(bytes, projection).0
}

///|
/// The file's declared row count — the whitebox tests' direct spelling;
/// production reaches the same check inside `read_parquet_frame`.
fn parquet_num_rows(bytes : Bytes) -> Int32 raise @types.DataError {
  footer_num_rows(read_footer(bytes))
}

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
    @series.Series::from_decimals("x", [
      Some(@types.Dec128::of_int64_scale(150L, scale=2)),
      None,
      Some(@types.Dec128::of_int64_scale(-5L, scale=2)),
      Some(@types.Dec128::of_int64_scale(9_223_372_036_854_775_807L, scale=2)),
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
  // A misspelt name builds no column — lenient like the text readers'
  // projection.
  assert_eq(read_parquet_columns(bytes, Some(["nope"])), [])
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
test "a written V1 page prefixes its level run with the run length" {
  // The spec's V1 data page shape: the level run opens with a 4-byte
  // little-endian length naming the encoded run's own bytes, then the
  // RLE stream, then the values — the prefix every foreign reader
  // strips before decoding the levels. The column [1, null] encodes
  // its levels [1, 0] as one bit-packed group (header 0x03, byte
  // 0x01): a two-byte run.
  let col = @series.Series::from_int_options("i", [Some(1), None])
  let bytes = write_parquet_bytes([col], ["i"], Uncompressed)
  // Walk past the leading magic through the first page header; every
  // field it carries is a scalar or a struct of scalars.
  let r = thrift_reader(bytes)
  r.pos = 4
  let mut last = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    assert_true(r.skip(h.wire))
  }
  let body_at = r.pos
  assert_eq(le_i32(bytes, body_at), 2)
  assert_eq(bytes[body_at + 4], (0x03).to_byte())
  assert_eq(bytes[body_at + 5], (0x01).to_byte())
  assert_eq(le_i64(bytes, body_at + 6), 1L)
}

///|
test "non-ASCII and astral column names and cells round-trip" {
  // The path list's length prefix counts UTF-8 bytes, not a String's
  // own UTF-16 code units: a BMP name (one unit, three bytes) would
  // undercount and an astral one (two units, four bytes) still
  // disagree, so either spelling corrupts the footer at the very name
  // the chunk pairing reads by. The schema's own name field and the
  // string cells already count bytes; this pins the list element's
  // prefix to the same truth.
  let names = ["列", "𝐀𝐁"]
  let columns : Array[@series.Series] = [
    @series.Series::from_string_options("列", [Some("值"), None, Some("🙂")]),
    @series.Series::from_string_options("𝐀𝐁", [
      Some("𝐀"),
      Some(""),
      None,
    ]),
  ]
  let bytes = write_parquet_bytes(columns, names, Uncompressed)
  let read = read_parquet_columns(bytes, None)
  assert_eq(read.length(), 2)
  assert_eq(read[0].0, "列")
  assert_eq(read[1].0, "𝐀𝐁")
  assert_eq(read[0].1.to_scalars(), columns[0].to_scalars())
  assert_eq(read[1].1.to_scalars(), columns[1].to_scalars())
  // The projection pairs by the same spelled name.
  let picked = read_parquet_columns(bytes, Some(["𝐀𝐁"]))
  assert_eq(picked.length(), 1)
  assert_eq(picked[0].0, "𝐀𝐁")
}

///|
test "the footer's size fields name the uncompressed truth" {
  // ColumnMetaData field 6 (total_uncompressed_size) names the
  // uncompressed page total and field 7 (total_compressed_size) the
  // bytes the file carries; the row group's field 2 (total_byte_size)
  // is the uncompressed sum. Under UNCOMPRESSED the three agree; under
  // SNAPPY the literal-only stream inflates its body, so 7 > 6 while
  // the row group's total stays the uncompressed one.
  let values : Array[Int64?] = []
  for i = 0; i < 40; i = i + 1 {
    values.push(Some(i.to_int64()))
  }
  let col = @series.Series::from_int_options("i", values)
  for codec in [Uncompressed, Snappy] {
    let bytes = write_parquet_bytes([col], ["i"], codec)
    let n = bytes.length()
    let footer_len = le_i32(bytes, n - 8)
    let r = thrift_reader(bytes)
    r.pos = n - 8 - footer_len
    let mut chunk6 = 0L
    let mut chunk7 = 0L
    let mut group2 = 0L
    let mut last = 0
    for ;; {
      let h = r.field_header(last).unwrap()
      if h.wire is Stop {
        break
      }
      last = h.id
      if h.id == 4 {
        ignore(list_header(r, 12).unwrap())
        let mut group_last = 0
        for ;; {
          let gh = r.field_header(group_last).unwrap()
          if gh.wire is Stop {
            break
          }
          group_last = gh.id
          if gh.id == 1 {
            ignore(list_header(r, 12).unwrap())
            let mut chunk_last = 0
            for ;; {
              let ch = r.field_header(chunk_last).unwrap()
              if ch.wire is Stop {
                break
              }
              chunk_last = ch.id
              if ch.id == 2 {
                ignore(r.zigzag_i64())
              } else if ch.id == 3 {
                let mut meta_last = 0
                for ;; {
                  let mh = r.field_header(meta_last).unwrap()
                  if mh.wire is Stop {
                    break
                  }
                  meta_last = mh.id
                  if mh.id == 6 {
                    chunk6 = r.zigzag_i64().unwrap()
                  } else if mh.id == 7 {
                    chunk7 = r.zigzag_i64().unwrap()
                  } else if !r.skip(mh.wire) {
                    fail("the footer walk could not skip a field")
                  }
                }
              } else if !r.skip(ch.wire) {
                fail("the footer walk could not skip a field")
              }
            }
          } else if gh.id == 2 {
            group2 = r.zigzag_i64().unwrap()
          } else if !r.skip(gh.wire) {
            fail("the footer walk could not skip a field")
          }
        }
      } else if !r.skip(h.wire) {
        fail("the footer walk could not skip a field")
      }
    }
    assert_true(chunk6 > 0L)
    if codec is Uncompressed {
      assert_eq(chunk6, chunk7)
      assert_eq(group2, chunk6)
    } else {
      assert_true(chunk7 > chunk6)
      assert_eq(group2, chunk6)
    }
  }
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

///|
/// Walk one thrift struct whose fields are bools, zigzag i32s, and
/// nested structs, rendering it flat — `id:value` pairs, `id:(inner)` a
/// nested struct, `id:()` an empty one — the rendering the logicalType
/// shape test compares against.
fn describe_struct(r : ThriftReader) -> String raise {
  let mut last = 0
  let mut out = ""
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    let part = match h.wire {
      BoolTrue => "\{h.id}:true"
      BoolFalse => "\{h.id}:false"
      I32V => "\{h.id}:\{r.zigzag_i32().unwrap()}"
      StructV => "\{h.id}:(\{describe_struct(r)})"
      _ => {
        assert_true(r.skip(h.wire))
        "\{h.id}:?"
      }
    }
    out = if out == "" { part } else { out + " " + part }
  }
  out
}

///|
/// The (name, logicalType-rendering) pairs of a written file's schema
/// elements, in element order — "" where an element carries no
/// logicalType field.
fn schema_logical_types(bytes : Bytes) -> Array[(String, String)] raise {
  let n = bytes.length()
  let footer_len = le_i32(bytes, n - 8)
  let r = thrift_reader(bytes)
  r.pos = n - 8 - footer_len
  let out : Array[(String, String)] = []
  let mut last = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    if h.id == 2 && h.wire is ListV {
      let count = list_header(r, 12).unwrap()
      for _ in 0..<count {
        let mut last_e = 0
        let mut name = ""
        let mut logical = ""
        for ;; {
          let he = r.field_header(last_e).unwrap()
          if he.wire is Stop {
            break
          }
          last_e = he.id
          if he.id == 4 {
            name = r.text().unwrap()
          } else if he.id == 10 && he.wire is StructV {
            logical = describe_struct(r)
          } else {
            assert_true(r.skip(he.wire))
          }
        }
        out.push((name, logical))
      }
    } else {
      assert_true(r.skip(h.wire))
    }
  }
  out
}

///|
test "every rider column's schema element carries its logicalType" {
  // The parquet format's rule that a writer carries both spellings: the
  // converted type (field 6) the legacy readers read and the logicalType
  // union (field 10) the modern ones do. Each rider's element carries
  // the union's own variant — STRING (1) and DATE (6) empty structs,
  // DECIMAL (5) with scale (1) before precision (2), TIMESTAMP (8) with
  // the UTC-adjusted bool and the MICROS (2) TimeUnit inside it — while
  // the bare Int column's element and the root carry neither.
  let columns : Array[@series.Series] = [
    @series.Series::from_ints("i", [1]),
    @series.Series::from_strings("s", ["a"]),
    @series.Series::from_date_options("d", [Some(0L)]),
    @series.Series::from_timestamp_options("t", [Some(0L)]),
    @series.Series::from_decimals("x", [
      Some(@types.Dec128::of_int64_scale(123L, scale=3)),
    ]),
  ]
  let bytes = write_parquet_bytes(
    columns,
    ["i", "s", "d", "t", "x"],
    Uncompressed,
  )
  assert_eq(schema_logical_types(bytes), [
    ("schema", ""),
    ("i", ""),
    ("s", "1:()"),
    ("d", "6:()"),
    ("t", "8:(1:true 2:(2:()))"),
    ("x", "5:(1:3 2:18)"),
  ])
  // And the file still reads back through its own footer.
  let read = read_parquet_columns(bytes, None)
  assert_eq(read.length(), 5)
}
