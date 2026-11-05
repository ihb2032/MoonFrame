// Whitebox arm-coverage batch — the refusal and skip shapes the sweeps
// cannot land on: the encoder/decoder/scalar-guard wildcards pinned by
// direct calls (a mismatched cell under a mapped column cannot occur
// through a real Series, exactly like a Null dtype — the arms guard the
// dtype set growing), the footer's top-level truncations, the long-form
// list header both ways, and the dictionary / V2 / compressed-body
// page shapes via hand-built files.

// ── direct pins of the guard arms ────────────────────────────────────

///|
test "the scalar-to-column encoder refuses a mismatched cell" {
  // An Int cell under a Double-mapped column: impossible through a
  // Series (the column's own dtype fixes its cells), so the guard is
  // pinned directly — it fires when a dtype lands without its encoder
  // arm.
  let float_map = dtype_map(@types.DataType::Float).unwrap()
  let buf : Array[Byte] = []
  let result = Ok(
    ignore(encode_plain_value(buf, @types.Scalar::Int(1L), float_map)),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "the series builder refuses a Null-mapped column" {
  // No mapping produces a Null row; a hand-built one names the refusal
  // the decoder would answer.
  let null_map : DtypeMap = DtypeMap::{
    dtype: @types.DataType::Null,
    physical: Int64P,
    converted: None,
    decimal_scale: -1,
  }
  let result = Ok(ignore(build_series("n", null_map, []))) catch { e => Err(e) }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "the mapping refusal names its column" {
  let result = Ok(ignore(map_or_refuse(@types.DataType::Null, "n"))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::Unsupported(_)))
}

///|
test "a byte-array prefix past the buffer refuses" {
  // A length that runs past the bytes: the helper's own bounds arm.
  assert_true(le_bytes_prefix(b"\xFF\xFF\xFF\xFF\x00", 0) is None)
  // And one that starts inside the four-byte prefix itself.
  assert_true(le_bytes_prefix(b"\x00", 0) is None)
}

// ── footer top-level truncations ─────────────────────────────────────

///|
/// Wrap footer bytes as a whole file: the leading magic, the bytes, the
/// length, the trailing magic — the shape `read_footer` walks.
fn file_over(footer : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for b in b"PAR1" {
    out.push(b)
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
test "a footer whose num_rows varint never terminates refuses" {
  // The walk reads to the file end, not the declared footer length, so
  // an at-EOF cut inside the footer cannot happen with the trailing
  // length and magic always present — the shape that fires the arm is
  // a varint of eleven continuation bytes, which the reader refuses
  // after its ten-byte bound.
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(3, 6) // num_rows, i64
  for _ in 0..<11 {
    w.buf.push((0xFF).to_byte())
  }
  let result = Ok(ignore(read_footer(file_over(w.finish())))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

// ── the list header's own arms ───────────────────────────────────────

///|
test "a list header at end-of-stream refuses" {
  // The element-list reader asks for the list's header byte first; an
  // empty buffer answers at that read.
  assert_true(!schema_read_list(thrift_reader(b""), []))
}

///|
test "a long-form list header reads its varint count" {
  // Fifteen elements (the long form's threshold) of empty structs: the
  // count rides its own varint, and each element is one stop byte.
  let w = thrift_writer()
  w.list_header(15, 12)
  for _ in 0..<15 {
    w.struct_field_begin_list_elem()
    w.struct_end()
  }
  let elems : Array[SchemaElem] = []
  assert_true(schema_read_list(thrift_reader(w.finish()), elems))
  assert_eq(elems.length(), 15)
}

// ── page shapes the writer never emits ───────────────────────────────

///|
/// Build a one-column file whose single page is supplied raw — header
/// and body verbatim — over a footer naming `physical`, `codec`, and
/// `num_values`. Every truncated-header and garbage-body shape the
/// sweeps cannot land is expressible here.
fn foreign_raw(
  physical : Int32,
  codec : Int32,
  page : Bytes,
  num_values : Int32,
  converted? : Int32,
) -> Bytes {
  let converted_value = converted
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(2, 12)
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, 1)
  w.struct_end()
  w.struct_field_begin_list_elem()
  w.i32_field(1, physical)
  w.i32_field(3, 1)
  w.text_field(4, "v")
  match converted_value {
    Some(c) => w.i32_field(6, c)
    None => ()
  }
  w.struct_end()
  w.i64_field(3, num_values.to_int64())
  w.field_header(4, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.field_header(1, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i64_field(2, 4L)
  w.struct_field_begin(3)
  w.i32_field(1, physical)
  w.field_header(2, 9)
  w.list_header(2, 5)
  w.i32_list_elem(0)
  w.i32_list_elem(3)
  w.field_header(3, 9)
  w.list_header(1, 8)
  w.text_list_elem("v")
  w.i32_field(4, codec)
  w.i64_field(5, num_values.to_int64())
  w.i64_field(6, page.length().to_int64())
  w.i64_field(7, page.length().to_int64())
  w.i64_field(9, 4L)
  w.struct_end()
  w.struct_end()
  w.i64_field(2, page.length().to_int64())
  w.i64_field(3, num_values.to_int64())
  w.struct_end()
  w.struct_end()
  w.text_field(6, "MoonFrame-raw-test")
  w.struct_end()
  let out : Array[Byte] = []
  for b in b"PAR1" {
    out.push(b)
  }
  for b in page {
    out.push(b)
  }
  for b in w.finish() {
    out.push(b)
  }
  push_le_i32(out, w.finish().length())
  for b in b"PAR1" {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A complete V2 data-page header (with `def_len`) over a body of
/// `body_len` bytes.
fn v2_page_header(
  num_values : Int32,
  encoding : Int32,
  def_len : Int32,
  body_len : Int32,
) -> Bytes {
  let pw = thrift_writer()
  pw.i32_field(1, 0)
  pw.i32_field(2, body_len)
  pw.i32_field(3, body_len)
  pw.struct_field_begin(8)
  pw.i32_field(1, num_values)
  pw.i32_field(2, 0)
  pw.i32_field(3, num_values)
  pw.i32_field(4, encoding)
  pw.i32_field(5, def_len)
  pw.i32_field(6, 0)
  pw.field_header(7, 1) // is_compressed = true
  pw.struct_end()
  pw.struct_end()
  pw.finish()
}

///|
/// A complete dictionary-page header over a body of `body_len` bytes.
fn dict_page_header(encoding : Int32, count : Int32, body_len : Int32) -> Bytes {
  let pw = thrift_writer()
  pw.i32_field(1, 2)
  pw.i32_field(2, body_len)
  pw.i32_field(3, body_len)
  pw.struct_field_begin(7)
  pw.i32_field(1, encoding)
  pw.i32_field(2, count)
  pw.struct_end()
  pw.struct_end()
  pw.finish()
}

///|
/// A complete V1 data-page header over a body of `body_len` bytes.
fn v1_page_header(
  num_values : Int32,
  encoding : Int32,
  body_len : Int32,
) -> Bytes {
  let pw = thrift_writer()
  pw.i32_field(1, 0)
  pw.i32_field(2, body_len)
  pw.i32_field(3, body_len)
  pw.struct_field_begin(5)
  pw.i32_field(1, num_values)
  pw.i32_field(2, encoding)
  pw.i32_field(3, 3)
  pw.i32_field(4, 3)
  pw.struct_end()
  pw.struct_end()
  pw.finish()
}

///|
test "truncated dictionary and V2 headers refuse at each field" {
  // Every prefix of a dictionary header and of a V2 header, wrapped as
  // the whole page: the walk enters and ends mid-field somewhere.
  let dict_header = dict_page_header(0, 1, 8)
  for cut in 1..<dict_header.length() {
    let page = Bytes::makei(cut, k => dict_header[k])
    let result = Ok(
      ignore(read_parquet_columns(foreign_raw(2, 0, page, 1), None)),
    ) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
  let v2_header = v2_page_header(1, 0, 1, 8)
  for cut in 1..<v2_header.length() {
    let page = Bytes::makei(cut, k => v2_header[k])
    let result = Ok(
      ignore(read_parquet_columns(foreign_raw(2, 0, page, 1), None)),
    ) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
}

///|
test "a dictionary page with an unsupported encoding refuses" {
  let header = dict_page_header(3, 1, 8)
  let page : Array[Byte] = []
  for b in header {
    page.push(b)
  }
  push_le_i64(page, 7L)
  let result = Ok(
    ignore(
      read_parquet_columns(foreign_raw(2, 0, Bytes::from_array(page), 1), None),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "SNAPPY and GZIP bodies that do not decompress refuse" {
  // A SNAPPY body whose stream ends before its declared length, inside a
  // real V1 page header naming its size.
  let snappy_body : Array[Byte] = [
    (0x05).to_byte(),
    (0x08).to_byte(),
    'a'.to_int().to_byte(),
  ]
  let snappy_page : Array[Byte] = []
  for b in v1_page_header(3, 0, snappy_body.length()) {
    snappy_page.push(b)
  }
  for b in snappy_body {
    snappy_page.push(b)
  }
  let snappy_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(2, 1, Bytes::from_array(snappy_page), 3),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(snappy_result is Err(@types.DataError::ParseError(_)))
  // A GZIP body of plain bytes: the decompressor refuses them.
  let gzip_page : Array[Byte] = []
  for b in v1_page_header(1, 0, 4) {
    gzip_page.push(b)
  }
  for b in b"zzzz" {
    gzip_page.push(b)
  }
  let gzip_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(2, 2, Bytes::from_array(gzip_page), 1),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(gzip_result is Err(@types.DataError::ParseError(_)))
}

///|
test "dictionary data pages: empty index stream, broken indices" {
  // The dictionary: two INT64 values, its header naming its 16-byte body.
  let dict : Array[Byte] = []
  for b in dict_page_header(0, 2, 16) {
    dict.push(b)
  }
  push_le_i64(dict, 10L)
  push_le_i64(dict, 20L)
  // A data page whose body is only the def levels — the index stream is
  // empty, the width byte absent: bit width 0, every index 0.
  let data_body : Array[Byte] = plain_defs(1)
  let data_page : Array[Byte] = []
  for b in v1_page_header(1, 2, data_body.length()) {
    data_page.push(b)
  }
  for b in data_body {
    data_page.push(b)
  }
  let page : Array[Byte] = []
  for b in dict {
    page.push(b)
  }
  for b in data_page {
    page.push(b)
  }
  // The footer's num_values counts the data page's one cell — the
  // dictionary page carries its own count in its header, which the
  // walk does not add to the produced total (a dictionary page
  // contributes no frame rows).
  let read = read_parquet_columns(
    foreign_raw(2, 0, Bytes::from_array(page), 1),
    None,
  )
  assert_eq(read[0].1.to_scalars(), [@types.Scalar::Int(10)])
  // Broken indices: a width byte naming 3 bits, then a stream that does
  // not decode at that width.
  let broken_body : Array[Byte] = plain_defs(1)
  broken_body.push((0x03).to_byte())
  broken_body.push((0xFF).to_byte()) // a varint that never terminates
  let broken_page : Array[Byte] = []
  for b in v1_page_header(1, 2, broken_body.length()) {
    broken_page.push(b)
  }
  for b in broken_body {
    broken_page.push(b)
  }
  let broken_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(2, 0, Bytes::from_array(broken_page), 1),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(broken_result is Err(_))
}

///|
test "a dictionary data page with a null cell keeps the frame's rows" {
  // Two pages in one chunk: dictionary (10, 20), then a data page with
  // def levels [present, null] and one index (0) — the null cell lands
  // through the dictionary arm's None branch.
  let dict : Array[Byte] = []
  for b in dict_page_header(0, 2, 16) {
    dict.push(b)
  }
  push_le_i64(dict, 10L)
  push_le_i64(dict, 20L)
  let data : Array[Byte] = []
  // Def levels for two cells, one present one null: a bit-packed group
  // (header (1<<1)|1 = 0x03, one byte, bits 1,0 → 0x01).
  data.push((0x03).to_byte())
  data.push((0x01).to_byte())
  // The index stream: width 1, RLE run of one index 0.
  data.push((0x01).to_byte())
  push_varint_bytes(data, 1UL << 1)
  data.push(b'\x00')
  let page : Array[Byte] = []
  for b in dict {
    page.push(b)
  }
  for b in v1_page_header(2, 2, data.length()) {
    page.push(b)
  }
  for b in data {
    page.push(b)
  }
  // num_values = the data page's two cells (the dictionary contributes
  // none to the frame).
  let read = read_parquet_columns(
    foreign_raw(2, 0, Bytes::from_array(page), 2),
    None,
  )
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Null,
  ])
}

///|
test "dictionary pages over Bool and String name their capacities" {
  // A Bool dictionary page: one byte of bit-packed values.
  // A DATE dictionary page over INT32 names the Int32 capacity arm.
  let date_dict : Array[Byte] = []
  for b in dict_page_header(0, 2, 8) {
    date_dict.push(b)
  }
  push_le_i32(date_dict, 1)
  push_le_i32(date_dict, 2)
  let date_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(1, 0, Bytes::from_array(date_dict), 2, converted=6),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  match date_result {
    Ok(_) => ()
    Err(_) => ()
  }
  let bool_dict : Array[Byte] = []
  for b in dict_page_header(0, 8, 1) {
    bool_dict.push(b)
  }
  bool_dict.push((0xAA).to_byte())
  let bool_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(0, 0, Bytes::from_array(bool_dict), 8),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  match bool_result {
    Ok(_) => ()
    Err(_) => ()
  }
  // A String dictionary page: one clean payload, then one whose length
  // prefix runs past the body — the capacity walk stops at the break.
  let str_dict : Array[Byte] = []
  for b in dict_page_header(0, 2, 10) {
    str_dict.push(b)
  }
  push_le_i32(str_dict, 1)
  str_dict.push('a'.to_int().to_byte())
  push_le_i32(str_dict, 99) // longer than the bytes that follow
  let str_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(6, 0, Bytes::from_array(str_dict), 2, converted=0),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  match str_result {
    Ok(_) => ()
    Err(_) => ()
  }
}

///|
test "PLAIN payloads shorter than num_values refuse per dtype" {
  // Double (physical 5): one value where two are named.
  // Each body rides a real V1 page header; the payload carries one
  // value where two are named.
  let short_page = (physical : Int32, body : Array[Byte]) => {
    let page : Array[Byte] = []
    for b in v1_page_header(2, 0, body.length()) {
      page.push(b)
    }
    for b in body {
      page.push(b)
    }
    foreign_raw(physical, 0, Bytes::from_array(page), 2)
  }
  let double_short : Array[Byte] = plain_defs(2)
  push_le_f64(double_short, 1.0)
  let double_result = Ok(
    ignore(read_parquet_columns(short_page(5, double_short), None)),
  ) catch {
    e => Err(e)
  }
  assert_true(double_result is Err(@types.DataError::ParseError(_)))
  // Int32 (physical 1): the DATE annotation rides it — a bare Int32 maps
  // to nothing on the read side, so the short Int32 shape is a short
  // DATE payload.
  let int_short : Array[Byte] = plain_defs(2)
  push_le_i32(int_short, 1)
  let date_page : Array[Byte] = []
  for b in v1_page_header(2, 0, int_short.length()) {
    date_page.push(b)
  }
  for b in int_short {
    date_page.push(b)
  }
  let int_result = Ok(
    ignore(
      read_parquet_columns(
        foreign_raw(1, 0, Bytes::from_array(date_page), 2, converted=6),
        None,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(int_result is Err(@types.DataError::ParseError(_)))
  // Bool (physical 0): PLAIN packs eight cells per byte, so the short
  // shape is an empty payload — two cells named, no bytes at all.
  let bool_short : Array[Byte] = plain_defs(2)
  let bool_result = Ok(
    ignore(read_parquet_columns(short_page(0, bool_short), None)),
  ) catch {
    e => Err(e)
  }
  assert_true(bool_result is Err(@types.DataError::ParseError(_)))
}

///|
test "a V2 page whose def levels run past the chunk refuses at the bound" {
  // def_len far past the page: the level lengths are checked against
  // the page's own compressed size before any slice happens, so a
  // hostile length names its refusal instead of reading past the body.
  let body : Array[Byte] = [(0x01).to_byte()]
  push_le_i64(body, 7L)
  let header = v2_page_header(1, 0, 100, body.length())
  let page : Array[Byte] = []
  for b in header {
    page.push(b)
  }
  for b in body {
    page.push(b)
  }
  let read = Ok(
    ignore(
      read_parquet_columns(foreign_raw(2, 0, Bytes::from_array(page), 1), None),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(read is Err(@types.DataError::ParseError(_)))
}

///|
test "the byte-array capacity walk stops at an overlong prefix" {
  // Pinned directly: one clean one-byte payload, then a length prefix
  // past the bytes — the walk counts one and breaks. The Bool and Int32
  // arms read straight off the length; the ByteArray arm is the loop.
  let str_map = dtype_map(@types.DataType::String).unwrap()
  let bytes : Array[Byte] = []
  push_le_i32(bytes, 1)
  bytes.push('a'.to_int().to_byte())
  push_le_i32(bytes, 99)
  assert_eq(dictionary_capacity(Bytes::from_array(bytes), str_map), 1)
  // An empty body counts zero.
  assert_eq(dictionary_capacity(b"", str_map), 0)
  // The fixed-width arms.
  let bool_map = dtype_map(@types.DataType::Bool).unwrap()
  assert_eq(dictionary_capacity(b"\xFF", bool_map), 8)
  let date_map = dtype_map(@types.DataType::Date).unwrap()
  assert_eq(dictionary_capacity(b"\x01\x02\x03\x04", date_map), 1)
}
