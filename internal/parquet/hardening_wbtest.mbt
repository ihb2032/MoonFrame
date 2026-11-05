// Whitebox regressions for the reader's integer-bound hardening — every
// test here is a hostile byte sequence an adversarial review built
// against the pre-hardening reader, kept because each one is the
// cheapest spelling of a wrap or a bomb the arithmetic could regress
// back into. The happy shapes stay in the round-trip file.

///|
test "an RLE run count that wraps the bound check refuses" {
  // A one-long run first (`02 01`), then a run header whose varint
  // spells 0xFFFFFFFE — repetitions 0x7FFFFFFF. The pre-hardening bound
  // `written + repetitions > count` wrapped negative and let the run
  // walk off the array; the subtraction form refuses.
  assert_true(rle_decode(b"\x02\x01\xFE\xFF\xFF\xFF\x0F\x01", 3, 1) is None)
  // The same header with nothing written yet stays inside Int32 and
  // refuses on the plain count instead — both orders must refuse.
  assert_true(rle_decode(b"\xFE\xFF\xFF\xFF\x0F\x01", 3, 1) is None)
}

///|
test "a bit-packed group count past the padded bound refuses" {
  // Exactly 0x1000_0000 groups passes the absolute guard, so only the
  // padded-bound form (`groups * 8 > remaining + 7`, spelled as the
  // division to avoid the wrap both sides of that comparison could do)
  // refuses it against a three-value count.
  let huge : Array[Byte] = []
  push_varint_bytes(huge, (0x1000_0000UL << 1) | 1UL)
  assert_true(rle_decode(Bytes::from_array(huge), 3, 1) is None)
}

///|
test "a snappy stream declaring a gigabyte it never writes refuses cheaply" {
  // The varint `80 80 80 80 04` declares exactly 0x4000_0000 bytes —
  // inside the guard, so the pre-hardening reader allocated the
  // gigabyte before looking at the stream. Five bytes in, the output
  // grows with what the stream produces and the empty tail refuses.
  assert_true(snappy_decompress(b"\x80\x80\x80\x80\x04") is None)
}

///|
/// A one-column file whose chunk declares `chunk_values` and whose
/// single data page declares `page_values` — the two counting guards
/// sit between these numbers and any allocation, so the page body is
/// filler the walk never reaches.
fn counting_file(
  chunk_values : Int64,
  page_values : Int32,
  chunk_offset~ : Int64 = 4L,
) -> Bytes {
  // A DATA_PAGE header over a four-byte body.
  let pw = thrift_writer()
  pw.i32_field(1, 0)
  pw.i32_field(2, 4)
  pw.i32_field(3, 4)
  pw.struct_field_begin(5)
  pw.i32_field(1, page_values)
  pw.i32_field(2, 0)
  pw.i32_field(3, 3)
  pw.i32_field(4, 3)
  pw.struct_end()
  pw.struct_end()
  let page_header = pw.finish()
  // The footer: root + one INT64 column, one row group, one chunk.
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(2, 12)
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, 1)
  w.struct_end()
  w.struct_field_begin_list_elem()
  w.i32_field(1, 2)
  w.i32_field(3, 1)
  w.text_field(4, "v")
  w.struct_end()
  w.i64_field(3, chunk_values)
  w.field_header(4, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.field_header(1, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i64_field(2, 4L)
  w.struct_field_begin(3)
  w.i32_field(1, 2)
  w.field_header(2, 9)
  w.list_header(2, 5)
  w.i32_list_elem(0)
  w.i32_list_elem(3)
  w.field_header(3, 9)
  w.list_header(1, 8)
  w.text_list_elem("v")
  w.i32_field(4, 0)
  w.i64_field(5, chunk_values)
  w.i64_field(6, 64L)
  w.i64_field(7, 64L)
  w.i64_field(9, chunk_offset)
  w.struct_end()
  w.struct_end()
  w.i64_field(2, 64L)
  w.i64_field(3, chunk_values)
  w.struct_end()
  w.struct_end()
  w.text_field(6, "MoonFrame-test")
  w.struct_end()
  let footer = w.finish()
  let out : Array[Byte] = []
  for b in b"PAR1" {
    out.push(b)
  }
  for b in page_header {
    out.push(b)
  }
  for _ in 0..<4 {
    out.push(b'\x00')
  }
  for b in footer {
    out.push(b)
  }
  push_le_i32(out, footer.length())
  for b in b"PAR1" {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
test "a chunk claiming more values than its bytes could carry refuses" {
  // Two billion values over a ~150-byte file: eight one-bit cells to a
  // byte is the densest encoding parquet spells, so the count is a lie
  // before any allocation happens.
  let result = Ok(
    ignore(read_parquet_columns(counting_file(2_147_483_647L, 1), None)),
  ) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("beyond what its bytes could carry"),
  )
}

///|
test "a page naming more values than its chunk still owes refuses" {
  // The chunk declares one value, its page claims two: the page count
  // sizes the level array, so it refuses at the header instead.
  let result = Ok(ignore(read_parquet_columns(counting_file(1L, 2), None))) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("past its chunk"),
  )
}

///|
test "slice clamps an over-long length to the buffer" {
  // The clamp arm: a length past the buffer's end hands back what is
  // there — every caller's own bounds checks refuse the hostile sizes
  // first, so the arm is reached only through this direct spelling.
  assert_eq(slice(b"abcdef", 4, 100), b"ef")
  assert_eq(slice(b"abcdef", 4, 2), b"ef")
  assert_eq(slice(b"abcdef", -1, 2), b"")
  assert_eq(slice(b"abcdef", 0, 0), b"")
}

///|
test "a chunk whose region leaves the file refuses" {
  // A data-page offset far past the file's own bytes: the region is
  // validated in Int64 before it rides Int32, so the offset refuses
  // instead of truncating into some in-range corner of the file.
  let result = Ok(
    ignore(
      read_parquet_columns(counting_file(1L, 1, chunk_offset=1_000_000L), None),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("leaves the file"),
  )
}

///|
test "a bool column past one packed byte round-trips" {
  // Thirteen present cells and a null: the first eight fill one byte,
  // the next five pad a tail — both sides of the bit-packing boundary
  // in one column.
  let cells : Array[Bool?] = []
  for i in 0..<13 {
    cells.push(Some(i % 3 != 0))
  }
  cells.push(None)
  let col = @series.Series::from_bool_options("b", cells)
  let bytes = write_parquet_bytes([col], ["b"], Uncompressed)
  let read = read_parquet_columns(bytes, None)
  assert_eq(read[0].1.to_scalars(), col.to_scalars())
}

///|
test "a foreign bit-packed BOOLEAN page reads eight cells to a byte" {
  // Ten present cells as two PLAIN bytes — the spec's own packing,
  // which the per-byte reader rejected from its ninth cell on.
  let body : Array[Byte] = plain_defs(10)
  body.push((0xFF).to_byte()) // cells 0..7: all true
  body.push((0x02).to_byte()) // cell 8 false, cell 9 true
  let file = foreign_file({
    physical: 0,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 10,
        def_len: 0,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  let scalars = read[0].1.to_scalars()
  assert_eq(scalars.length(), 10)
  let mut trues = 0
  for i in 0..<10 {
    if scalars[i] is @types.Scalar::Bool(true) {
      trues = trues + 1
    }
  }
  assert_eq(trues, 9)
  assert_true(scalars[8] is @types.Scalar::Bool(false))
}

///|
test "a foreign V2 SNAPPY page reads its raw levels and compressed values" {
  // The V2 shape: the level run sits raw at the page head — an RLE run
  // of three ones at width 1 (`06 01`), never compressed — and only the
  // values after it ride the codec. Sending the whole page through the
  // decompressor rejected every foreign V2 compressed file.
  let values : Array[Byte] = []
  push_le_i64(values, 7L)
  push_le_i64(values, 8L)
  push_le_i64(values, 9L)
  let body : Array[Byte] = [(0x06).to_byte(), (0x01).to_byte()]
  for b in snappy_compress_literal(Bytes::from_array(values)) {
    body.push(b)
  }
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 1,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: true,
        num_values: 3,
        def_len: 2,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(8),
    @types.Scalar::Int(9),
  ])
}

///|
test "the writer refuses a lone-surrogate string cell" {
  // The core UTF-8 encoder aborts on an unpaired surrogate, so the
  // guard runs before it and refuses with the error model's own
  // InvalidOperation.
  let cell = StringBuilder()
  cell.write_char(Int32::unsafe_to_char(0xD800))
  let col = @series.Series::from_string_options("s", [Some(cell.to_string())])
  let result = Ok(ignore(write_parquet_bytes([col], ["s"], Uncompressed))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}
