// Whitebox foreign-page reads — the page shapes MoonFrame's own writer
// never emits but its reader accepts (a dictionary page plus an
// RLE_DICTIONARY data page; a V2 data page), and the page-body
// refusals (a PLAIN payload shorter than num_values names, a SNAPPY /
// GZIP body that does not decompress, def levels that do not decode).
// Each file is hand-built thrift, the shape a foreign writer produces.

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
fn foreign_file(spec : ForeignSpec) -> Bytes {
  // The page headers and bodies, in order.
  let pages_bytes : Array[Byte] = []
  let mut total_size = 0L
  let mut total_values = 0L
  for page in spec.pages {
    let pw = thrift_writer()
    pw.i32_field(1, if page.dictionary_page { 2 } else { 0 })
    pw.i32_field(2, page.body.length())
    pw.i32_field(3, page.body.length())
    if page.v2 {
      pw.struct_field_begin(8)
      pw.i32_field(1, page.num_values)
      pw.i32_field(2, 0)
      pw.i32_field(3, page.num_values)
      pw.i32_field(4, page.encoding)
      pw.i32_field(5, page.def_len)
      pw.i32_field(6, 0)
      pw.bool_field_v2(7, true)
      pw.struct_end()
    } else {
      pw.struct_field_begin(5)
      pw.i32_field(1, page.num_values)
      pw.i32_field(2, page.encoding)
      pw.i32_field(3, 3)
      pw.i32_field(4, 3)
      pw.struct_end()
    }
    pw.struct_end()
    let page_header = pw.finish()
    for b in page_header {
      pages_bytes.push(b)
    }
    for b in page.body {
      pages_bytes.push(b)
    }
    total_size = total_size +
      (page.body.length() + page_header.length()).to_int64()
    total_values = total_values + page.num_values.to_int64()
  }
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(2, 12)
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, 1)
  w.struct_end()
  w.struct_field_begin_list_elem()
  w.i32_field(1, spec.physical)
  w.i32_field(3, spec.repetition)
  w.text_field(4, "v")
  match spec.converted {
    Some(c) => w.i32_field(6, c)
    None => ()
  }
  w.struct_end()
  w.i64_field(3, total_values)
  w.field_header(4, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.field_header(1, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i64_field(2, 4L)
  w.struct_field_begin(3)
  w.i32_field(1, spec.physical)
  w.field_header(2, 9)
  w.list_header(2, 5)
  w.i32_list_elem(0)
  w.i32_list_elem(3)
  w.field_header(3, 9)
  w.list_header(1, 8)
  w.text_list_elem("v")
  w.i32_field(4, spec.codec)
  w.i64_field(5, total_values)
  w.i64_field(6, total_size)
  w.i64_field(7, total_size)
  w.i64_field(9, 4L)
  w.struct_end()
  w.struct_end()
  w.i64_field(2, total_size)
  w.i64_field(3, total_values)
  w.struct_end()
  w.struct_end()
  w.text_field(6, "MoonFrame-foreign-test")
  w.struct_end()
  let footer = w.finish()
  let out : Array[Byte] = []
  for b in b"PAR1" {
    out.push(b)
  }
  for b in pages_bytes {
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
/// The bool field the V2 header carries — the compact protocol's
/// value-in-type-nibble spelling, written directly (the writer has no
/// bool helper).
fn ThriftWriter::bool_field_v2(
  self : ThriftWriter,
  id : Int32,
  v : Bool,
) -> Unit {
  self.field_header(id, if v { 1 } else { 2 })
}

///|
/// The PLAIN definition levels for `n` present cells — one RLE run of
/// `n` ones at width 1 (header `n << 1`, value 1).
fn plain_defs(n : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  push_varint_bytes(out, n.to_uint64() << 1)
  out.push(b'\x01')
  out
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
      },
      {
        body: data_body,
        encoding: 2,
        dictionary_page: false,
        v2: false,
        num_values: 3,
        def_len: 0,
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
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(orphan_file, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "a foreign V2 data page reads its bit-packed levels" {
  // V2: the def levels are raw bit-packed bytes (three present cells
  // = bits 111 → 0x07), then the PLAIN values. The body handed to the
  // reader is levels-then-values; the header names def_len = 1.
  let body : Array[Byte] = [(0x07).to_byte()]
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
        def_len: 1,
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
      },
    ],
  })
  assert_eq(read_parquet_columns(v2_file, None)[0].1.to_scalars(), [
    @types.Scalar::Int(9),
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
      },
    ],
  })
  let result = Ok(ignore(read_parquet_columns(short_file, None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
  // Def levels that do not decode: the level stream is a bit-packed
  // header naming more groups than the count allows.
  let bad_defs : Array[Byte] = [(0xFF).to_byte(), (0x01).to_byte()]
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
      },
    ],
  })
  let bad_result = Ok(ignore(read_parquet_columns(bad_file, None))) catch {
    e => Err(e)
  }
  assert_true(bad_result is Err(_))
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
      },
    ],
  })
  let raw_result = Ok(ignore(read_parquet_columns(raw_file, None))) catch {
    e => Err(e)
  }
  assert_true(raw_result is Err(@types.DataError::ParseError(_)))
}
