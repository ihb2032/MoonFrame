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
/// (`Null` refuses — a null column has no cells to name a dtype by) and
/// share the frame's one height — a column of another length raises
/// `LengthMismatch` instead of writing a file whose chunks disagree on
/// their row count; a 0-row frame writes its schema with zero-value
/// column chunks, the shape a reader rebuilds into the empty frame.
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
  // The decimal columns' adaptive scale: the one scale every cell
  // honours — the most fraction digits any cell carries — named in the
  // annotation and exact per cell. A NaN or ±∞ cell refuses the write
  // (the fixed-point interchange has no exceptional representation).
  // The payload then follows the magnitudes: every lifted cell inside
  // `Int64` rides the 18-digit INT64 interchange as before; a column
  // only the 16-byte FIXED_LEN_BYTE_ARRAY payload holds (a scale past
  // 18, or a magnitude past `Int64` at a scale that fits) rides
  // precision 38 over 16 bytes — and a column past even that window
  // (a scale past 38, or a magnitude past the 38 digits the 16-byte
  // payload spells) refuses naming the window it leaves.
  for i in 0..<ncols {
    if maps[i].converted is Some(DecimalC) {
      let mut scale = 0
      for cell in columns[i].to_scalars() {
        if cell is @types.Scalar::Decimal(v) {
          if v.is_nan() || v.is_infinite() {
            raise @types.DataError::InvalidOperation(
              "cannot write column \"\{names[i]}\": a NaN or infinite decimal cell has no fixed-point interchange spelling",
            )
          }
          let e = v.canonical().exponent().unwrap_or(0)
          if -e > scale {
            scale = -e
          }
        }
      }
      // The lifted digits each cell spells at the chosen scale — the
      // payload decision's own facts, read off the canonical
      // coefficient and exponent once per cell.
      let mut int64_window = scale <= 18
      let mut flba_window = scale <= 38
      for cell in columns[i].to_scalars() {
        if cell is @types.Scalar::Decimal(v) {
          if v.is_zero() {
            continue
          }
          let canon = v.canonical()
          let e = canon.exponent().unwrap_or(0)
          let digits = canon.coefficient_digits().unwrap_or([]).length()
          // The lifted magnitude's digit count: the coefficient's own
          // digits plus the zeros the scale-to-exponent shift appends.
          let lifted = digits + scale + e
          if lifted > 18 {
            int64_window = false
          }
          if lifted > 38 {
            flba_window = false
          }
        }
      }
      if int64_window {
        maps[i].decimal_scale = scale
        maps[i].decimal_precision = 18
      } else if flba_window {
        maps[i].decimal_scale = scale
        maps[i].decimal_precision = 38
        maps[i].physical = FlbaP
        maps[i].flba_width = 16
      } else {
        raise @types.DataError::InvalidOperation(
          "cannot write column \"\{names[i]}\": its cells leave the decimal interchange's 38-digit window",
        )
      }
    }
  }
  let nrows : Int64 = if ncols == 0 {
    0L
  } else {
    let height = columns[0].len()
    for i in 1..<ncols {
      if columns[i].len() != height {
        raise @types.DataError::LengthMismatch(height, columns[i].len())
      }
    }
    height.to_int64()
  }
  let out : Array[Byte] = []
  // PAR1 magic.
  for b in b"PAR1" {
    out.push(b)
  }
  // One column chunk per column: the dictionary page is not written
  // (PLAIN only), so each chunk is one data page, its offset remembered
  // for the footer.
  let chunk_offsets : Array[Int64] = []
  let chunk_compressed : Array[Int64] = []
  let chunk_uncompressed : Array[Int64] = []
  let chunk_counts : Array[Int64] = []
  for i in 0..<ncols {
    let (page, uncompressed) = encode_data_page(columns[i], maps[i], codec)
    chunk_offsets.push(out.length().to_int64())
    for b in page {
      out.push(b)
    }
    chunk_compressed.push(page.length().to_int64())
    chunk_uncompressed.push(uncompressed)
    chunk_counts.push(nrows)
  }
  // The footer: FileMetaData thrift, its length, and the trailing magic.
  let footer = write_footer(
    maps, names, chunk_offsets, chunk_compressed, chunk_uncompressed, chunk_counts,
    nrows, codec,
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
/// definition levels (bit width 1 — max def level 1 under OPTIONAL)
/// behind the 4-byte little-endian length a V1 page prefixes every
/// level run with, and the PLAIN values, compressed per the codec. The
/// answer carries both sizes: the page bytes as written, and the
/// uncompressed total (header plus uncompressed body) the footer's
/// size fields name — the header rides uncompressed in either size, so
/// the two differ by exactly what the codec did to the body.
fn encode_data_page(
  column : @series.Series,
  map : DtypeMap,
  codec : Codec,
) -> (Bytes, Int64) raise @types.DataError {
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
  // The V1 page's own shape: each level run opens with a 4-byte
  // little-endian length naming the encoded run's byte count — the
  // prefix every foreign reader strips before decoding the levels.
  push_le_i32(page_body, level_bytes.length())
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
  (Bytes::from_array(out), (header.length() + page_body.length()).to_int64())
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
    (Int64P, Decimal(v)) => {
      // The cell lifted to the column's adaptive scale — exact by the
      // write-side gate (the scale is the most fraction digits any cell
      // carries), the magnitude inside Int64 by the same gate. The lift
      // multiplies by 10^scale (the *unscaled* magnitude the annotation
      // names), spelled as the value 1 × 10^-(-scale).
      let lifted = v.mul(
        @types.Dec128::of_int64_scale(1L, scale=-map.decimal_scale),
      )
      match lifted.to_int64() {
        Some(u) => push_le_i64(buf, u)
        None =>
          raise @types.DataError::InvalidOperation(
            "cannot write a decimal cell past the INT64 interchange",
          )
      }
    }
    (FlbaP, Decimal(v)) =>
      // The same lift, spelled over the 16-byte payload: the unscaled
      // magnitude as big-endian two's complement, the width the
      // write-side gate chose and the footer's type_length names.
      push_flba16_decimal(buf, v, map.decimal_scale)
    _ =>
      raise @types.DataError::InvalidOperation(
        "parquet encoder met a \{scalar.dtype()} cell under a \{map.dtype} column",
      )
  }
}

///|
/// The FileMetaData footer: the schema (a root element carrying the
/// column children), one row group, its column chunks, and the created-by
/// string. Each chunk names its compressed bytes (field 7) and its
/// uncompressed ones (field 6) separately, and the row group's own
/// total_byte_size is the uncompressed sum — the three sizes a foreign
/// reader cross-checks, each naming the truth it measures.
fn write_footer(
  maps : Array[DtypeMap],
  names : Array[String],
  chunk_offsets : Array[Int64],
  chunk_compressed : Array[Int64],
  chunk_uncompressed : Array[Int64],
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
    if maps[i].physical is FlbaP {
      // The FIXED_LEN_BYTE_ARRAY element's own field: the payload width
      // the decoder strides by.
      w.i32_field(2, maps[i].flba_width)
    }
    w.i32_field(3, 1) // OPTIONAL repetition
    w.text_field(4, names[i])
    match maps[i].converted {
      Some(c) => {
        w.i32_field(6, converted_tag(c))
        if c is DecimalC {
          // The scale and the precision the adaptive pass chose — 18
          // over the INT64 payload, 38 over the 16-byte one.
          w.i32_field(7, maps[i].decimal_scale)
          w.i32_field(8, maps[i].decimal_precision)
        }
        write_logical_type(
          w,
          c,
          maps[i].decimal_scale,
          maps[i].decimal_precision,
        )
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
  let mut total_uncompressed = 0L
  for i in 0..<maps.length() {
    total_uncompressed = total_uncompressed + chunk_uncompressed[i]
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
    w.i64_field(6, chunk_uncompressed[i])
    w.i64_field(7, chunk_compressed[i])
    // Field 9: data_page_offset — the chunk's own offset (no
    // dictionary page precedes it).
    w.i64_field(9, chunk_offsets[i])
    w.struct_end()
    w.struct_end()
  }
  // RowGroup field 2: total_byte_size — the row group's uncompressed
  // total; field 3: num_rows.
  w.i64_field(2, total_uncompressed)
  w.i64_field(3, nrows)
  w.struct_end()
  // Field 6: created_by.
  w.text_field(6, "MoonFrame")
  w.struct_end()
  w.finish()
}

///|
/// The logicalType annotation (SchemaElement field 10) a converted
/// annotation's modern spelling rides — the parquet format's own rule
/// that a writer carries both: the LogicalType union the modern readers
/// read, alongside the converted type (field 6) the legacy ones do.
/// Each variant is the union's own field id holding its parameter
/// struct: STRING (1) and DATE (6) are empty structs, DECIMAL (5)
/// carries scale (1) then precision (2), TIMESTAMP (8) carries the
/// isAdjustedToUTC bool (1) — a MoonFrame timestamp is an epoch count,
/// so UTC-adjusted — and the MICROS (2) unit inside its TimeUnit union.
fn write_logical_type(
  w : ThriftWriter,
  c : Converted,
  scale : Int32,
  precision : Int32,
) -> Unit {
  w.struct_field_begin(10)
  match c {
    Utf8C => w.empty_struct_field(1)
    DateC => w.empty_struct_field(6)
    DecimalC => {
      w.struct_field_begin(5)
      w.i32_field(1, scale)
      w.i32_field(2, precision)
      w.struct_end()
    }
    TimestampMicrosC => {
      w.struct_field_begin(8)
      w.bool_field(1, true)
      w.struct_field_begin(2)
      w.empty_struct_field(2)
      w.struct_end()
      w.struct_end()
    }
  }
  w.struct_end()
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
/// One string element inside an already-open list. The length prefix
/// names the UTF-8 byte count — the wire counts bytes, while a
/// `String`'s own length counts UTF-16 code units, so a non-ASCII or
/// astral name under that count would write a prefix the reader's
/// binary walk misreads (a BMP name undercounts, an astral one still
/// disagrees), corrupting the footer at the very name the chunk pairing
/// reads.
fn ThriftWriter::text_list_elem(self : ThriftWriter, v : String) -> Unit {
  let encoded = @utf8.encode(v)
  self.write_varint(encoded.length().to_uint64())
  for b in encoded {
    self.buf.push(b)
  }
}

///|
/// The ×10-and-add-digit step the 16-byte decimal accumulator folds
/// by. The low half's add-digit carry is arithmetically unreachable
/// over the decimal input domain, though the fold keeps the guard
/// anyway: 2^64 ends in 6, so any k·2^64 ends in an even digit, and
/// 10L ends in 0 — the low half after the ×10 step (10L − k·2^64)
/// therefore always ends in an even digit, while the carry needs it
/// within nine of the wrap (a final digit 1 through 9, all odd).
/// `#coverage.skip` rides the whole helper for that one arm, the same
/// trade the BOOLEAN dictionary capacity makes for its memory-bound
/// arm.
#coverage.skip
fn times10_plus(
  acc_hi : UInt64,
  acc_lo : UInt64,
  d : UInt64,
) -> (UInt64, UInt64) {
  let lo_prod = mul_u64(10UL, acc_lo)
  let hi_prod = mul_u64(10UL, acc_hi)
  let new_hi = hi_prod.0 + lo_prod.1
  let new_lo = lo_prod.0 + d
  if new_lo < lo_prod.0 {
    (new_hi + 1UL, new_lo)
  } else {
    (new_hi, new_lo)
  }
}

///|
/// One decimal cell's 16-byte FIXED_LEN_BYTE_ARRAY spelling: the value
/// lifted to the column's adaptive scale, then written as big-endian
/// two's complement — the interchange's own PLAIN form for the wide
/// decimal payload. The lifted magnitude's decimal digits accumulate
/// into a 128-bit (hi, lo) pair two UInt64s carry (38 digits sit far
/// inside), the negative side taking the two's complement, and the
/// pair writes out big-endian: hi's eight bytes, then lo's.
fn push_flba16_decimal(
  buf : Array[Byte],
  v : @types.Dec128,
  scale : Int32,
) -> Unit {
  let lifted = v.mul(@types.Dec128::of_int64_scale(1L, scale=-scale))
  let neg = lifted.is_negative()
  let canon = lifted.abs().canonical()
  let e = canon.exponent().unwrap_or(0)
  let digits = canon.coefficient_digits().unwrap_or([])
  // (hi, lo) × 10 + d over the 128-bit pair, once per decimal digit
  // and once per trailing zero the shift appends — the write-side gate
  // bounds the whole run at 38 digits, so no bit ever drops past 128.
  let mut hi = 0UL
  let mut lo = 0UL
  for d in digits {
    let acc = times10_plus(hi, lo, d.to_uint64())
    hi = acc.0
    lo = acc.1
  }
  for _ in 0..<e {
    let acc = times10_plus(hi, lo, 0UL)
    hi = acc.0
    lo = acc.1
  }
  if neg {
    // Two's complement over 128 bits: each half's flip is the all-ones
    // mask minus the half (no bitwise-NOT operator rides the pair),
    // then one adds through the low half with its carry.
    hi = 0xFFFF_FFFF_FFFF_FFFFUL - hi
    lo = 0xFFFF_FFFF_FFFF_FFFFUL - lo
    lo = lo + 1UL
    if lo == 0UL {
      hi = hi + 1UL
    }
  }
  push_be_u64(buf, hi)
  push_be_u64(buf, lo)
}

///|
/// The low and high halves of a UInt64 product (little pair: low,
/// high) — the multiply the 128-bit decimal accumulator rides.
fn mul_u64(a : UInt64, b : UInt64) -> (UInt64, UInt64) {
  let a_lo = a & 0xFFFF_FFFFUL
  let a_hi = a >> 32
  let b_lo = b & 0xFFFF_FFFFUL
  let b_hi = b >> 32
  let ll = a_lo * b_lo
  let lh = a_lo * b_hi
  let hl = a_hi * b_lo
  let hh = a_hi * b_hi
  // lo = ll + (lh << 32) + (hl << 32), assembled with carries.
  let mid1 = ll + (lh << 32)
  let carry1 = if mid1 < ll { 1UL } else { 0UL }
  let mid2 = mid1 + (hl << 32)
  let carry2 = if mid2 < mid1 { 1UL } else { 0UL }
  let lo = mid2
  let hi = hh + (lh >> 32) + (hl >> 32) + carry1 + carry2
  (lo, hi)
}

///|
/// One UInt64 as eight big-endian bytes — the FLBA payload's halves.
fn push_be_u64(buf : Array[Byte], v : UInt64) -> Unit {
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    buf.push(((v >> shift) & 0xFFUL).to_byte())
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
