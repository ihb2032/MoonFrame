// Whitebox foreign-page reads — the page shapes MoonFrame's own writer
// never emits but its reader accepts (a dictionary page plus an
// RLE_DICTIONARY data page; a V2 data page), and the page-body
// refusals (a PLAIN payload shorter than num_values names, a SNAPPY /
// GZIP body that does not decompress, def levels that do not decode).
// Each file is hand-built thrift, the shape a foreign writer produces.

///|
/// A one-column FLBA decimal foreign file over one PLAIN page: every
/// cell's fixed-width payload spelled big-endian, the schema element
/// naming the width, scale, and precision a foreign writer's decimal
/// annotation carries.
fn flba_decimal_file(
  payloads : Array[Array[Byte]],
  scale : Int32,
  precision~ : Int32 = 38,
  type_length~ : Int32 = 16,
) -> Bytes {
  let n = payloads.length()
  let body : Array[Byte] = plain_defs(n)
  for cell in payloads {
    for b in cell {
      body.push(b)
    }
  }
  let header = v1_page_header(n, 0, body.length(), page_type=0)
  let pages : Array[Byte] = []
  for b in header {
    pages.push(b)
  }
  for b in body {
    pages.push(b)
  }
  let total = pages.length().to_int64()
  let footer = one_column_footer(
    7,
    7,
    1,
    Some(5),
    0,
    n.to_int64(),
    total,
    created_by="MoonFrame-foreign-test",
    type_length=Some(type_length),
    scale=Some(scale),
    precision=Some(precision),
  )
  file_over(footer, pages=Bytes::from_array(pages))
}

///|
/// One page of a foreign file: its body bytes, the encoding its header
/// names, and its shape (dictionary / V1 / V2).
priv struct ForeignPage {
  body : Array[Byte]
  encoding : Int32
  dictionary_page : Bool
  v2 : Bool
  num_values : Int32
  def_len : Int32
  page_type : Int32
}

///|
/// Build a one-column parquet file over one or more pages: the schema
/// row's physical tag, repetition, and converted annotation, the pages,
/// and the footer chunk metadata sized over them all.
priv struct ForeignSpec {
  physical : Int32
  repetition : Int32
  converted : Int32?
  codec : Int32
  pages : Array[ForeignPage]
}

///|
/// The one-column thrift footer every hand-built file here rides: a
/// root schema element, one column element, one row group, one chunk.
/// The schema's and the chunk's physical tags are separate parameters —
/// the mismatched shape names two deliberately — beside the repetition,
/// converted annotation, and codec; `num_values` names the footer's,
/// the chunk's, and the row group's row counts together and
/// `total_size` the chunk's compressed / uncompressed sizes and the row
/// group's byte size together, the one spelling every builder wrote.
fn one_column_footer(
  schema_physical : Int32,
  chunk_physical : Int32,
  repetition : Int32,
  converted : Int32?,
  codec : Int32,
  num_values : Int64,
  total_size : Int64,
  offset~ : Int64 = 4L,
  name~ : String = "v",
  created_by~ : String = "MoonFrame-test",
  type_length~ : Int32? = None,
  scale~ : Int32? = None,
  precision~ : Int32? = None,
) -> Bytes {
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(2, 12)
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, 1)
  w.struct_end()
  w.struct_field_begin_list_elem()
  w.i32_field(1, schema_physical)
  match type_length {
    Some(len) => w.i32_field(2, len)
    None => ()
  }
  w.i32_field(3, repetition)
  w.text_field(4, name)
  match scale {
    Some(s) => w.i32_field(7, s)
    None => ()
  }
  match precision {
    Some(p) => w.i32_field(8, p)
    None => ()
  }
  match converted {
    Some(c) => w.i32_field(6, c)
    None => ()
  }
  w.struct_end()
  w.i64_field(3, num_values)
  w.field_header(4, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.field_header(1, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i64_field(2, 4L)
  w.struct_field_begin(3)
  w.i32_field(1, chunk_physical)
  w.field_header(2, 9)
  w.list_header(2, 5)
  w.i32_list_elem(0)
  w.i32_list_elem(3)
  w.field_header(3, 9)
  w.list_header(1, 8)
  w.text_list_elem(name)
  w.i32_field(4, codec)
  w.i64_field(5, num_values)
  w.i64_field(6, total_size)
  w.i64_field(7, total_size)
  w.i64_field(9, offset)
  w.struct_end()
  w.struct_end()
  w.i64_field(2, total_size)
  w.i64_field(3, num_values)
  w.struct_end()
  w.struct_end()
  w.text_field(6, created_by)
  w.struct_end()
  w.finish()
}

///|
fn foreign_file(spec : ForeignSpec) -> Bytes {
  // The page headers and bodies, in order. A dictionary page carries
  // only the DictionaryPageHeader — its num_values names the value set's
  // entries, and the value set rides PLAIN — and the footer's chunk
  // num_values counts the data pages' cells alone, exactly the shape a
  // foreign writer spells.
  let pages_bytes : Array[Byte] = []
  let mut total_size = 0L
  let mut total_values = 0L
  for page in spec.pages {
    let page_header = if page.dictionary_page {
      dict_page_header(0, page.num_values, page.body.length())
    } else if page.v2 {
      v2_page_header(
        page.num_values,
        page.encoding,
        page.def_len,
        page.body.length(),
      )
    } else {
      v1_page_header(
        page.num_values,
        page.encoding,
        page.body.length(),
        page_type=page.page_type,
      )
    }
    for b in page_header {
      pages_bytes.push(b)
    }
    for b in page.body {
      pages_bytes.push(b)
    }
    total_size = total_size +
      (page.body.length() + page_header.length()).to_int64()
    if !page.dictionary_page {
      total_values = total_values + page.num_values.to_int64()
    }
  }
  let footer = one_column_footer(
    spec.physical,
    spec.physical,
    spec.repetition,
    spec.converted,
    spec.codec,
    total_values,
    total_size,
    created_by="MoonFrame-foreign-test",
  )
  file_over(footer, pages=Bytes::from_array(pages_bytes))
}

///|
/// The definition levels a V1 data page carries for `n` present cells —
/// the 4-byte little-endian length prefix every V1 level run opens
/// with, then one RLE run of `n` ones at width 1 (header `n << 1`,
/// value 1).
fn plain_defs(n : Int32) -> Array[Byte] {
  let run : Array[Byte] = []
  push_varint_bytes(run, n.to_uint64() << 1)
  run.push(b'\x01')
  let out : Array[Byte] = []
  push_le_i32(out, run.length())
  for b in run {
    out.push(b)
  }
  out
}

///|
test "a dictionary page's fields read in the thrift bindings' order" {
  // num_values (1) then encoding (2) — the ids the parquet thrift
  // bindings define. The count here is three, a value no legal encoding
  // spells, so a reader that took field 1 for the encoding would refuse
  // the page naming an unsupported encoding; the values read back prove
  // each field landed in its own slot. The dictionary: three INT64
  // values (10, 20, 30). The data page: four present cells, indices
  // [0, 2, 1, 2] at width 2 — one bit-packed group: header 3, then the
  // byte pair 0x98 0x00 (slot 1's value 2 at bits 3, slot 2's 1 at bit
  // 4, slot 3's 2 at bit 7, pads zero).
  let dict_body : Array[Byte] = []
  push_le_i64(dict_body, 10L)
  push_le_i64(dict_body, 20L)
  push_le_i64(dict_body, 30L)
  let data_body : Array[Byte] = plain_defs(4)
  data_body.push((0x02).to_byte()) // index bit width 2
  data_body.push((0x03).to_byte()) // one bit-packed group
  data_body.push((0x98).to_byte())
  data_body.push((0x00).to_byte())
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: dict_body,
        encoding: 0,
        dictionary_page: true,
        v2: false,
        num_values: 3,
        def_len: 0,
        page_type: 0,
      },
      {
        body: data_body,
        encoding: 2,
        dictionary_page: false,
        v2: false,
        num_values: 4,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(30),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
}

///|
test "a foreign RLE_DICTIONARY file reads through the value set" {
  // The dictionary page: two INT64 values (10, 20). The data page: def
  // levels for three present cells, then the index stream — width byte
  // 1, and the bit-packed indices [0, 1, 0] (one group, bits 0,1,0 →
  // 0x02).
  let dict_body : Array[Byte] = []
  push_le_i64(dict_body, 10L)
  push_le_i64(dict_body, 20L)
  let data_body : Array[Byte] = plain_defs(3)
  data_body.push((0x01).to_byte()) // index bit width 1
  data_body.push((0x03).to_byte()) // one bit-packed group
  data_body.push((0x02).to_byte()) // values 0, 1, 0 (+ padding 0)
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: dict_body,
        encoding: 0,
        dictionary_page: true,
        v2: false,
        num_values: 2,
        def_len: 0,
        page_type: 0,
      },
      {
        body: data_body,
        encoding: 2,
        dictionary_page: false,
        v2: false,
        num_values: 3,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(10),
  ])
  // A dictionary data page without a dictionary page before it: the
  // indices leave the (empty) value set.
  let orphan : Array[Byte] = plain_defs(1)
  orphan.push((0x01).to_byte())
  orphan.push((0x03).to_byte())
  orphan.push((0x01).to_byte())
  let orphan_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: orphan,
        encoding: 2,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(orphan_file, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "a dictionary chunk with two data pages reads every page's rows" {
  // The chunk's num_values counts the data pages' cells alone — a
  // dictionary page's own count names its entries, not frame rows — so
  // a dictionary page ahead of two data pages neither advances the
  // walk's produced total nor eats into the chunk's own count.
  let dict_body : Array[Byte] = []
  push_le_i64(dict_body, 10L)
  push_le_i64(dict_body, 20L)
  // First data page: two present cells, both index 0 — the index
  // stream is width byte 1, then an RLE run of two index-0 (header
  // `2 << 1`, value 0).
  let first : Array[Byte] = plain_defs(2)
  first.push((0x01).to_byte())
  first.push((0x04).to_byte())
  first.push(b'\x00')
  // Second data page: one present cell, index 1 — an RLE run of one.
  let second : Array[Byte] = plain_defs(1)
  second.push((0x01).to_byte())
  second.push((0x02).to_byte())
  second.push(b'\x01')
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: dict_body,
        encoding: 0,
        dictionary_page: true,
        v2: false,
        num_values: 2,
        def_len: 0,
        page_type: 0,
      },
      {
        body: first,
        encoding: 2,
        dictionary_page: false,
        v2: false,
        num_values: 2,
        def_len: 0,
        page_type: 0,
      },
      {
        body: second,
        encoding: 2,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
  ])
}

///|
test "an index page refuses naming its column" {
  // A page type the reader does not carry (INDEX_PAGE = 1) refuses
  // with the column named — its level run must first decode, since the
  // page-type gate sits after the level walk.
  let body : Array[Byte] = plain_defs(1)
  push_le_i64(body, 7L)
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 1,
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(file, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::Unsupported(_)))
}

///|
test "a FLOAT column refuses the pairing as unmappable" {
  // The pairing's own refusal: a chunk whose schema element maps to no
  // MoonFrame dtype (FLOAT would narrow a Double) raises Unsupported
  // naming the column.
  let body : Array[Byte] = plain_defs(1)
  body.push((0x00).to_byte())
  body.push((0x00).to_byte())
  body.push((0x00).to_byte())
  body.push((0x00).to_byte())
  let file = foreign_file({
    physical: 4,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(file, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::Unsupported(_)))
}

///|
test "a foreign V2 data page reads its RLE definition levels" {
  // V2 levels are an RLE / bit-packed hybrid stream at the column's
  // def-level bit width (1 here), carried raw at the page head with no
  // length prefix — the header's definition_levels_byte_length names
  // the run's size. One RLE run of three ones: the varint header
  // `3 << 1` (low bit 0 = RLE run), then the width-1 value byte 0x01.
  let body : Array[Byte] = [(0x06).to_byte(), (0x01).to_byte()]
  push_le_i64(body, 7L)
  push_le_i64(body, 8L)
  push_le_i64(body, 9L)
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: true,
        num_values: 3,
        def_len: 2,
        page_type: 0,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(8),
    @types.Scalar::Int(9),
  ])
  // The same page with its levels in the bit-packed spelling: the
  // varint header `(1 << 1) | 1` (one group of eight slots), then one
  // byte whose low bits are the levels 1, 0, 1 (the tail slots pad with
  // zeros the count never reads) — a present, a null, a present.
  let packed : Array[Byte] = [(0x03).to_byte(), (0x05).to_byte()]
  push_le_i64(packed, 7L)
  push_le_i64(packed, 8L)
  let packed_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: packed,
        encoding: 0,
        dictionary_page: false,
        v2: true,
        num_values: 3,
        def_len: 2,
        page_type: 0,
      },
    ],
  })
  let packed_read = read_parquet_columns(packed_file, None)
  assert_eq(packed_read[0].1.to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Null,
    @types.Scalar::Int(8),
  ])
}

///|
test "a REQUIRED column's pages carry no definition levels" {
  // The level sections are written only when the column's max
  // definition level is above zero; a REQUIRED leaf's is 0, so the data
  // page body starts with the values themselves — V1 with no level
  // bytes at all, V2 with definition_levels_byte_length 0. Forcing a
  // def-level decode over such a body misreads the values as levels and
  // refuses a legal foreign file.
  let v1_body : Array[Byte] = []
  push_le_i64(v1_body, 7L)
  push_le_i64(v1_body, 8L)
  let v1_file = foreign_file({
    physical: 2,
    repetition: 0,
    converted: None,
    codec: 0,
    pages: [
      {
        body: v1_body,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 2,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  assert_eq(read_parquet_columns(v1_file, None)[0].1.to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(8),
  ])
  let v2_body : Array[Byte] = []
  push_le_i64(v2_body, 9L)
  let v2_file = foreign_file({
    physical: 2,
    repetition: 0,
    converted: None,
    codec: 0,
    pages: [
      {
        body: v2_body,
        encoding: 0,
        dictionary_page: false,
        v2: true,
        num_values: 1,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  assert_eq(read_parquet_columns(v2_file, None)[0].1.to_scalars(), [
    @types.Scalar::Int(9),
  ])
}

///|
test "a bare INT32 column reads as Int" {
  // INT32 with no converted annotation is a signed 32-bit integer —
  // the shape every foreign writer emits for a plain int column, where
  // MoonFrame's own writer rides INT64.
  let body : Array[Byte] = plain_defs(3)
  push_le_i32(body, -1)
  push_le_i32(body, 2147483647)
  push_le_i32(body, -2147483648)
  let file = foreign_file({
    physical: 1,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 3,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.dtype(), @types.DataType::Int)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Int(-1L),
    @types.Scalar::Int(2147483647L),
    @types.Scalar::Int(-2147483648L),
  ])
}

///|
test "a nested group element refuses the schema naming the group" {
  // A group element names children instead of a physical type; read as
  // a leaf, the absent type would decode as BOOLEAN and a same-named
  // chunk would mis-decode under it. The walk refuses the group.
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(3, 12)
  // The root.
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, 2)
  w.struct_end()
  // A group child: children, no type.
  w.struct_field_begin_list_elem()
  w.text_field(4, "nested")
  w.i32_field(5, 1)
  w.struct_end()
  // A flat leaf.
  w.struct_field_begin_list_elem()
  w.i32_field(1, 2)
  w.i32_field(3, 1)
  w.text_field(4, "v")
  w.struct_end()
  w.struct_end()
  let footer = w.finish()
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
  let result = Ok(ignore(read_parquet_columns(Bytes::from_array(out), None))) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("nested group"),
  )
}

///|
test "a three-page chunk with a zero-value micro page reads in order" {
  // Two one-value pages around a num_values=0 micro page — a legal
  // shape a foreign writer emits when a batch boundary lands mid-chunk.
  // The walk advances page by page through the chunk's own region, and
  // the micro page owes no rows: its level run decodes to nothing and
  // the produced total does not move.
  let first : Array[Byte] = plain_defs(2)
  push_le_i64(first, 7L)
  push_le_i64(first, 8L)
  let micro : Array[Byte] = []
  push_le_i32(micro, 0) // an empty level run; no values follow
  let third : Array[Byte] = plain_defs(1)
  push_le_i64(third, 9L)
  let file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: first,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 2,
        def_len: 0,
        page_type: 0,
      },
      {
        body: micro,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 0,
        def_len: 0,
        page_type: 0,
      },
      {
        body: third,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 0,
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
/// A one-column file whose chunk metadata and schema element name
/// `chunk_physical` and `schema_physical` for the same column — the
/// page body is a well-formed INT64 page either way, so a refusal can
/// only come from the pairing's own comparison.
fn mismatched_physical_file(
  schema_physical : Int32,
  chunk_physical : Int32,
) -> Bytes {
  let body : Array[Byte] = plain_defs(1)
  push_le_i64(body, 7L)
  let page : Array[Byte] = []
  for b in v1_page_header(1, 0, body.length()) {
    page.push(b)
  }
  for b in body {
    page.push(b)
  }
  let footer = one_column_footer(
    schema_physical,
    chunk_physical,
    1,
    None,
    0,
    1L,
    page.length().to_int64(),
  )
  file_over(footer, pages=Bytes::from_array(page))
}

///|
test "a chunk whose physical type disagrees with its schema refuses" {
  // The chunk metadata says INT32 (1) where the schema row says INT64
  // (2): decoding the bytes under the schema's dtype would read
  // confidently wrong cells, so the pairing refuses naming both tags
  // and the column.
  let result = Ok(
    ignore(read_parquet_columns(mismatched_physical_file(2, 1), None)),
  ) catch {
    e => Err(e)
  }
  assert_true(
    result is Err(@types.DataError::InvalidOperation(msg)) &&
    msg.contains("\"v\"") &&
    msg.contains("physical type 1") &&
    msg.contains("physical type 2"),
  )
  // The agreeing shape still reads.
  let read = read_parquet_columns(mismatched_physical_file(2, 2), None)
  assert_eq(read[0].1.to_scalars(), [@types.Scalar::Int(7)])
}

///|
test "a multi-row-group file refuses naming the shape" {
  // Two row groups each carrying their own chunks for the same columns:
  // concatenating them would splice same-named columns into one chunk
  // list, so the footer walk refuses at the row-group count instead —
  // the groups here are empty, proving the refusal is the count's own.
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
  w.i64_field(3, 0L)
  w.field_header(4, 9)
  w.list_header(2, 12)
  w.struct_field_begin_list_elem()
  w.struct_end()
  w.struct_field_begin_list_elem()
  w.struct_end()
  w.struct_end()
  w.struct_end()
  w.text_field(6, "MoonFrame-test")
  w.struct_end()
  let footer = w.finish()
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
  let result = Ok(ignore(read_parquet_columns(Bytes::from_array(out), None))) catch {
    e => Err(e)
  }
  assert_true(
    result is Err(@types.DataError::Unsupported(msg)) &&
    msg.contains("multi-row-group parquet files are not supported yet"),
  )
}

///|
test "a REPEATED leaf column refuses naming the column" {
  // A REPEATED leaf rides repetition levels — a nested shape the flat
  // reader refuses rather than decoding rows out of its levels.
  let body : Array[Byte] = []
  push_le_i64(body, 7L)
  let file = foreign_file({
    physical: 2,
    repetition: 2,
    converted: None,
    codec: 0,
    pages: [
      {
        body,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(file, None))) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("REPEATED"),
  )
}

///|
test "page-body refusals name their column" {
  // A PLAIN page whose payload ends before num_values: two cells
  // declared, one value written.
  let short : Array[Byte] = plain_defs(2)
  push_le_i64(short, 7L)
  let short_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: short,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 2,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(short_file, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
  // Def levels that do not decode: the prefixed level stream is a
  // bit-packed header naming more groups than the count allows (the
  // prefix itself names the run's two bytes).
  let bad_defs : Array[Byte] = []
  push_le_i32(bad_defs, 2)
  bad_defs.push((0xFF).to_byte())
  bad_defs.push((0x01).to_byte())
  push_le_i64(bad_defs, 7L)
  let bad_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: bad_defs,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 3,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let bad_result = Ok(ignore(read_parquet_columns(bad_file, None))) catch {
    e => Err(e)
  }
  assert_true(bad_result is Err(_))
  // A level run whose prefix names more bytes than the body carries:
  // the two-byte run below sits behind a prefix claiming eight.
  let long_defs : Array[Byte] = []
  push_le_i32(long_defs, 8)
  long_defs.push((0x06).to_byte())
  long_defs.push((0x01).to_byte())
  let long_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: long_defs,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 3,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let long_result = Ok(ignore(read_parquet_columns(long_file, None))) catch {
    e => Err(e)
  }
  assert_true(
    long_result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("level length leaves its body"),
  )
  // A body shorter than the prefix itself: two level bytes, no prefix.
  let cut_defs : Array[Byte] = [(0x06).to_byte(), (0x01).to_byte()]
  let cut_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: cut_defs,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 3,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let cut_result = Ok(ignore(read_parquet_columns(cut_file, None))) catch {
    e => Err(e)
  }
  assert_true(cut_result is Err(_))
  // The same refusal on a V2 page: the level run names three values in
  // its header but carries no value byte — the raw level stream is
  // truncated mid-run.
  let v2_bad : Array[Byte] = [(0x06).to_byte()]
  let v2_bad_file = foreign_file({
    physical: 2,
    repetition: 1,
    converted: None,
    codec: 0,
    pages: [
      {
        body: v2_bad,
        encoding: 0,
        dictionary_page: false,
        v2: true,
        num_values: 2,
        def_len: 1,
        page_type: 0,
      },
    ],
  })
  let v2_bad_result = Ok(ignore(read_parquet_columns(v2_bad_file, None))) catch {
    e => Err(e)
  }
  assert_true(v2_bad_result is Err(_))
  // A non-UTF-8 BYTE_ARRAY cell under the UTF8 annotation: the payload
  // carries a lone 0xFF byte.
  let raw : Array[Byte] = plain_defs(1)
  push_le_i32(raw, 1)
  raw.push((0xFF).to_byte())
  let raw_file = foreign_file({
    physical: 6,
    repetition: 1,
    converted: Some(0),
    codec: 0,
    pages: [
      {
        body: raw,
        encoding: 0,
        dictionary_page: false,
        v2: false,
        num_values: 1,
        def_len: 0,
        page_type: 0,
      },
    ],
  })
  let raw_result = Ok(ignore(read_parquet_columns(raw_file, None))) catch {
    e => Err(e)
  }
  assert_true(raw_result is Err(@types.DataError::ParseError(_)))
}

///|
test "a foreign FIXED_LEN_BYTE_ARRAY decimal column reads its cells" {
  // Three 16-byte cells — 64 (0.64 at scale 2), -1, and 0 — read back
  // through the width the schema's type_length names.
  let cell_64 : Array[Byte] = []
  for _ in 0..<15 {
    cell_64.push(b'\x00')
  }
  cell_64.push(b'\x40')
  let cell_neg1 : Array[Byte] = []
  for _ in 0..<16 {
    cell_neg1.push(b'\xFF')
  }
  let cell_zero : Array[Byte] = []
  for _ in 0..<16 {
    cell_zero.push(b'\x00')
  }
  let file = flba_decimal_file([cell_64, cell_neg1, cell_zero], 2)
  let read = read_parquet_columns(file, None)
  assert_eq(read.length(), 1)
  assert_eq(read[0].0, "v")
  assert_eq(read[0].1.dtype(), @types.DataType::Decimal)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Decimal(@types.Dec128::parse_opt("0.64").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("-0.01").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("0").unwrap()),
  ])
  // The narrower widths a foreign writer spells — 8 bytes for
  // precision 18, 4 bytes for precision 9 — stride their own payloads.
  let eight : Array[Byte] = []
  for _ in 0..<7 {
    eight.push(b'\x00')
  }
  eight.push(b'\x0A') // 10 at scale 1 = 1.0
  let eight_file = flba_decimal_file([eight], 1, precision=18, type_length=8)
  let eight_read = read_parquet_columns(eight_file, None)
  assert_eq(eight_read[0].1.to_scalars(), [
    @types.Scalar::Decimal(@types.Dec128::parse_opt("1.0").unwrap()),
  ])
  // A payload shorter than the cells name refuses — the PLAIN bound
  // holds per stride: a second cell half-spelled leaves the walk past
  // the page's end.
  let cell_short : Array[Byte] = []
  for _ in 0..<8 {
    cell_short.push(b'\x00')
  }
  let cut_file = flba_decimal_file([cell_64, cell_short], 2)
  let cut_result = Ok(ignore(read_parquet_columns(cut_file, None))) catch {
    e => Err(e)
  }
  assert_true(cut_result is Err(@types.DataError::ParseError(_)))
}

///|
test "a foreign dictionary FLBA decimal reads through its value set" {
  // The dictionary page: two 16-byte values (64 → 0.64, -1). The data
  // page: def levels for three present cells, then the index stream —
  // width byte 1, bit-packed indices [0, 1, 0].
  let val_64 : Array[Byte] = []
  for _ in 0..<15 {
    val_64.push(b'\x00')
  }
  val_64.push(b'\x40')
  let val_neg1 : Array[Byte] = []
  for _ in 0..<16 {
    val_neg1.push(b'\xFF')
  }
  let dict_body : Array[Byte] = []
  for b in val_64 {
    dict_body.push(b)
  }
  for b in val_neg1 {
    dict_body.push(b)
  }
  let data_body : Array[Byte] = plain_defs(3)
  data_body.push((0x01).to_byte())
  data_body.push((0x03).to_byte())
  data_body.push((0x02).to_byte())
  let pages : Array[Byte] = []
  let dict_header = dict_page_header(0, 2, dict_body.length())
  for b in dict_header {
    pages.push(b)
  }
  for b in dict_body {
    pages.push(b)
  }
  let data_header = v1_page_header(3, 2, data_body.length(), page_type=0)
  for b in data_header {
    pages.push(b)
  }
  for b in data_body {
    pages.push(b)
  }
  let total = pages.length().to_int64()
  let footer = one_column_footer(
    7,
    7,
    1,
    Some(5),
    0,
    3L,
    total,
    created_by="MoonFrame-foreign-test",
    type_length=Some(16),
    scale=Some(2),
    precision=Some(38),
  )
  let file = file_over(footer, pages=Bytes::from_array(pages))
  let read = read_parquet_columns(file, None)
  assert_eq(read[0].1.to_scalars(), [
    @types.Scalar::Decimal(@types.Dec128::parse_opt("0.64").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("-0.01").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("0.64").unwrap()),
  ])
}
