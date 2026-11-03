// The parquet file writer — one frame, one row group, one column chunk
// per column: PLAIN-encoded data pages (v1) under OPTIONAL repetition
// with RLE definition levels, and the thrift compact footer every
// parquet reader walks. The compression is UNCOMPRESSED or SNAPPY (the
// literal-only stream — legal, exact, no ratio) or GZIP. Column-major
// layout, values in row order: the shape every reader expects.

///|
/// The compression a written file carries.
pub(all) enum Codec {
  Uncompressed
  Snappy
  Gzip
}

///|
fn codec_tag(c : Codec) -> Int32 {
  match c {
    Uncompressed => 0
    Snappy => 1
    Gzip => 2
  }
}

///|
/// Render one frame as a whole parquet file. Every column must map
/// (`Null` refuses — a null column has no cells to name a dtype by); a
/// 0-row frame writes its schema with zero-value column chunks, the
/// shape a reader rebuilds into the empty frame.
pub fn write_parquet_bytes(
  columns : Array[@series.Series],
  names : Array[String],
  codec : Codec,
) -> Bytes raise @types.DataError {
  let ncols = columns.length()
  // The maps first — they name the schema rows and the page encoders.
  let maps : Array[DtypeMap] = []
  for i in 0..<ncols {
    maps.push(map_or_refuse(columns[i].dtype(), names[i]))
  }
  let nrows : Int64 = if ncols == 0 { 0L } else { columns[0].len().to_int64() }
  let out : Array[Byte] = []
  // PAR1 magic.
  for b in b"PAR1" {
    out.push(b)
  }
  // One column chunk per column: the dictionary page is not written
  // (PLAIN only), so each chunk is one data page, its offset remembered
  // for the footer.
  let chunk_offsets : Array[Int64] = []
  let chunk_sizes : Array[Int64] = []
  let chunk_counts : Array[Int64] = []
  for i in 0..<ncols {
    let page = encode_data_page(columns[i], maps[i], codec)
    chunk_offsets.push(out.length().to_int64())
    for b in page {
      out.push(b)
    }
    chunk_sizes.push(page.length().to_int64())
    chunk_counts.push(nrows)
  }
  // The footer: FileMetaData thrift, its length, and the trailing magic.
  let footer = write_footer(
    maps, names, chunk_offsets, chunk_sizes, chunk_counts, nrows, codec,
  )
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
/// One column's data page: the v1 page header (thrift), then the RLE
/// definition levels (bit width 1 — max def level 1 under OPTIONAL) and
/// the PLAIN values, compressed per the codec.
fn encode_data_page(
  column : @series.Series,
  map : DtypeMap,
  codec : Codec,
) -> Bytes raise @types.DataError {
  let n = column.len()
  // The definition levels: 1 per present cell, 0 per null.
  let valid = column.validity_bools()
  let levels : Array[Int32] = Array::makei(n, i => if valid[i] { 1 } else { 0 })
  let level_bytes = rle_encode(levels, 1)
  // The PLAIN payload over the present cells. BOOLEAN rides its own
  // bit-packing — eight cells to a byte, LSB first, the tail padded
  // with zeros — because a byte accumulates bits from up to eight
  // cells, so the encoding carries state across the per-cell walk.
  let payload : Array[Byte] = []
  let scalars = column.to_scalars()
  if map.physical is Boolean {
    let mut cur = 0
    let mut filled = 0
    for i in 0..<n {
      if valid[i] {
        if scalars[i] is @types.Scalar::Bool(true) {
          cur = cur | (1 << filled)
        }
        filled = filled + 1
        if filled == 8 {
          payload.push(cur.to_byte())
          cur = 0
          filled = 0
        }
      }
    }
    if filled > 0 {
      payload.push(cur.to_byte())
    }
  } else {
    for i in 0..<n {
      if valid[i] {
        encode_plain_value(payload, scalars[i], map)
      }
    }
  }
  let page_body : Array[Byte] = []
  for b in level_bytes {
    page_body.push(b)
  }
  for b in payload {
    page_body.push(b)
  }
  let body = match codec {
    Uncompressed => Bytes::from_array(page_body)
    Snappy => snappy_compress_literal(Bytes::from_array(page_body))
    Gzip => @gzip.compress(Bytes::from_array(page_body))
  }
  // The page header: DATA_PAGE (0), sizes, and the v1 header — num
  // values, PLAIN encoding, RLE definition levels, RLE repetition
  // levels (the flat schema's max repetition is 0, but the field must
  // name an encoding; RLE with a zero-width stream is what the spec's
  // own flat writers emit... spelled as BIT_PACKED(4) — the historical
  // flat default — would decode as no bytes at width 0 either way; RLE
  // keeps the one decoder honest).
  let w = thrift_writer()
  w.i32_field(1, 0)
  w.i32_field(2, page_body.length())
  w.i32_field(3, body.length())
  w.struct_field_begin(5)
  w.i32_field(1, n)
  w.i32_field(2, 0)
  w.i32_field(3, 3)
  w.i32_field(4, 3)
  w.struct_end()
  w.struct_end()
  let header = w.finish()
  let out : Array[Byte] = []
  for b in header {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// One present cell's PLAIN bytes.
fn encode_plain_value(
  buf : Array[Byte],
  scalar : @types.Scalar,
  map : DtypeMap,
) -> Unit raise @types.DataError {
  match (map.physical, scalar) {
    (Int64P, Int(v)) => push_le_i64(buf, v)
    (DoubleP, Float(v)) => push_le_f64(buf, v)
    (ByteArrayP, String(s)) => {
      // The core UTF-8 encoder aborts on an unpaired surrogate, so the
      // guard runs first and refuses with the `DataError` the write
      // signature promises instead of the abort escaping it.
      match @text.find_unpaired_surrogate(s) {
        Some(_) =>
          raise @types.DataError::InvalidOperation(
            "cannot write a parquet string cell containing an unpaired UTF-16 surrogate: the UTF-8 encoding would not round-trip",
          )
        None => ()
      }
      let bytes = @utf8.encode(s)
      push_le_i32(buf, bytes.length())
      for b in bytes {
        buf.push(b)
      }
    }
    (Int32P, Date(days)) => {
      // Parquet's DATE is an INT32 day count; a day value outside that
      // range cannot ride the annotation and refuses — the calendar
      // years a rendering shows all sit far inside it.
      if days < -2147483648L || days > 2147483647L {
        raise @types.DataError::InvalidOperation(
          "parquet DATE day count \{days} leaves the INT32 annotation",
        )
      }
      push_le_i32(buf, days.to_int())
    }
    (Int64P, Timestamp(micros)) => push_le_i64(buf, micros)
    (Int64P, Duration(micros)) => push_le_i64(buf, micros)
    (Int64P, Decimal(_, unscaled)) => push_le_i64(buf, unscaled)
    _ =>
      raise @types.DataError::InvalidOperation(
        "parquet encoder met a \{scalar.dtype()} cell under a \{map.dtype} column",
      )
  }
}

///|
/// The FileMetaData footer: the schema (a root element carrying the
/// column children), one row group, its column chunks, and the created-by
/// string.
fn write_footer(
  maps : Array[DtypeMap],
  names : Array[String],
  chunk_offsets : Array[Int64],
  chunk_sizes : Array[Int64],
  chunk_counts : Array[Int64],
  nrows : Int64,
  codec : Codec,
) -> Bytes {
  let w = thrift_writer()
  // Field 1: version.
  w.i32_field(1, 1)
  // Field 2: the schema list. The root element first (num_children,
  // no type), then one element per column.
  w.field_header(2, 9)
  w.list_header(maps.length() + 1, 12)
  // The root.
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, maps.length())
  w.struct_end()
  for i in 0..<maps.length() {
    w.struct_field_begin_list_elem()
    w.i32_field(1, physical_tag(maps[i].physical))
    w.i32_field(3, 1) // OPTIONAL repetition
    w.text_field(4, names[i])
    match maps[i].converted {
      Some(c) => {
        w.i32_field(6, converted_tag(c))
        if c is DecimalC {
          // The scale the row carried from the dtype; the precision the
          // INT64 payload bounds.
          w.i32_field(7, maps[i].decimal_scale)
          w.i32_field(8, decimal_precision())
        }
      }
      None => ()
    }
    w.struct_end()
  }
  // Field 3: num_rows.
  w.i64_field(3, nrows)
  // Field 4: the row group list — one group, its column chunks.
  w.field_header(4, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  // RowGroup field 1: columns (list of ColumnChunk).
  w.field_header(1, 9)
  w.list_header(maps.length(), 12)
  let mut total_size = 0L
  for i in 0..<maps.length() {
    total_size = total_size + chunk_sizes[i]
    w.struct_field_begin_list_elem()
    // ColumnChunk field 2: file_offset; field 3: meta_data.
    w.i64_field(2, chunk_offsets[i])
    w.struct_field_begin(3)
    w.i32_field(1, physical_tag(maps[i].physical))
    // Field 2: encodings (PLAIN 0, RLE 3).
    w.field_header(2, 9)
    w.list_header(2, 5)
    w.i32_list_elem(0)
    w.i32_list_elem(3)
    // Field 3: path_in_schema.
    w.field_header(3, 9)
    w.list_header(1, 8)
    w.text_list_elem(names[i])
    w.i32_field(4, codec_tag(codec))
    w.i64_field(5, chunk_counts[i])
    w.i64_field(6, chunk_sizes[i])
    w.i64_field(7, chunk_sizes[i])
    // Field 9: data_page_offset — the chunk's own offset (no
    // dictionary page precedes it).
    w.i64_field(9, chunk_offsets[i])
    w.struct_end()
    w.struct_end()
  }
  // RowGroup field 2: total_byte_size; field 3: num_rows.
  w.i64_field(2, total_size)
  w.i64_field(3, nrows)
  w.struct_end()
  // Field 6: created_by.
  w.text_field(6, "MoonFrame")
  w.struct_end()
  w.finish()
}

///|
/// A struct element inside a list — the writer's list-element spelling
/// (the list header already opened; the element begins like a nested
/// struct field at the id the list field itself named).
fn ThriftWriter::struct_field_begin_list_elem(self : ThriftWriter) -> Unit {
  self.stack.push(self.last_id)
  self.last_id = 0
  // A list element struct carries no field header of its own — its
  // bytes begin with the element struct's first field header directly.
}

///|
/// One i32 element inside an already-open list.
fn ThriftWriter::i32_list_elem(self : ThriftWriter, v : Int32) -> Unit {
  self.write_zigzag(v.to_int64())
}

///|
/// One string element inside an already-open list.
fn ThriftWriter::text_list_elem(self : ThriftWriter, v : String) -> Unit {
  self.write_varint(v.length().to_uint64())
  for b in @utf8.encode(v) {
    self.buf.push(b)
  }
}

///|
/// The mapping's refusal, spelled as its own function so the guard is
/// reachable directly: a dtype with no parquet row refuses the write
/// naming the column. Today that is `Null` alone (no Series constructor
/// can build one, so the public write never meets it — a future dtype
/// landing without a row hits this on its first write, and the
/// mapping-refusal reference test pins it).
fn map_or_refuse(
  dtype : @types.DataType,
  name : String,
) -> DtypeMap raise @types.DataError {
  match dtype_map(dtype) {
    Some(m) => m
    None =>
      raise @types.DataError::Unsupported(
        "parquet cannot carry column \"\{name}\" of dtype \{dtype}",
      )
  }
}
