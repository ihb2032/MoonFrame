// The parquet file reader — the footer walk (thrift FileMetaData: the
// schema elements, the row groups' column chunks), then per column: the
// page headers, the compressed bodies, the RLE definition levels, and
// the PLAIN or dictionary-decoded values. V1 and V2 data pages both
// decode; the encodings and physical types MoonFrame does not carry
// refuse with the column named. Projection rides the caller: only the
// columns it names are walked at all.

///|
/// One column's footer facts, before the schema pairing. The physical
/// tag walks the chunk but does not ride the struct — the schema's own
/// element names the dtype the chunk decodes under, and a disagreement
/// between the two is the pairing's refusal.
priv struct RawChunk {
  name : String
  codec : Int32
  num_values : Int64
  pages_at : Int64
  compressed : Int64
}

///|
/// The paired column: a chunk plus its schema row's dtype map.
priv struct ColumnRead {
  chunk : RawChunk
  map : DtypeMap
}

///|
/// The footer walk's result: the paired columns in chunk order, and
/// the row count field 3 names — the height a lenient projection that
/// matches no column still reports (the decoded column lengths are the
/// count a reader can check against it).
priv struct ParquetFooter {
  columns : Array[ColumnRead]
  num_rows : Int64
}

///|
/// One located parse refusal — the footer walk's error vocabulary.
fn bad(what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("parquet: \{what}"),
  )
}

///|
/// Parse a whole parquet file's footer: the trailing magic, the length,
/// the FileMetaData thrift, and the chunk→schema pairing.
fn read_footer(bytes : Bytes) -> ParquetFooter raise @types.DataError {
  let n = bytes.length()
  if n < 12 ||
    bytes[n - 4] != b'P' ||
    bytes[n - 3] != b'A' ||
    bytes[n - 2] != b'R' ||
    bytes[n - 1] != b'1' {
    raise bad("not a parquet file: the trailing magic is missing")
  }
  let footer_len = le_i32(bytes, n - 8)
  if footer_len <= 0 || footer_len > n - 12 {
    raise bad("the footer length leaves the file")
  }
  let footer_start = n - 8 - footer_len
  let r = thrift_reader(bytes)
  r.pos = footer_start
  // Field 2: schema elements. Field 3: num_rows. Field 4: row groups.
  // The order of arrival is the writer's; both collections land before
  // the pairing.
  let schema : Array[SchemaElem] = []
  let mut num_rows = 0L
  let chunks : Array[RawChunk] = []
  let mut last = 0
  for ;; {
    let header = match r.field_header(last) {
      Some(h) => h
      None => raise bad("the footer ends mid-field")
    }
    if header.wire is Stop {
      break
    }
    last = header.id
    match header.id {
      2 =>
        if !schema_read_list(r, schema) {
          raise bad("the schema list is malformed")
        }
      3 =>
        match r.zigzag_i64() {
          Some(v) => num_rows = v
          None => raise bad("num_rows is malformed")
        }
      4 =>
        if !row_groups_read(r, chunks) {
          raise bad("the row group list is malformed")
        }
      _ =>
        if !r.skip(header.wire) {
          raise bad("the footer carries an undecodable field")
        }
    }
  }
  // Pair each chunk with its schema element by column name; the root
  // element (index 0) is the schema's own head, not a column.
  let columns : Array[ColumnRead] = []
  for chunk in chunks {
    let mut paired : DtypeMap? = None
    for i in 1..<schema.length() {
      if schema[i].name == chunk.name {
        paired = map_from_schema(
          schema[i].physical,
          schema[i].converted,
          schema[i].decimal_scale,
        )
        break
      }
    }
    match paired {
      Some(map) => columns.push({ chunk, map, })
      None =>
        raise @types.DataError::Unsupported(
          "parquet column \"\{chunk.name}\" carries a dtype MoonFrame cannot map",
        )
    }
  }
  { columns, num_rows, }
}

///|
/// One schema element's decoded facts.
priv struct SchemaElem {
  name : String
  physical : Int32
  converted : Int32?
  decimal_scale : Int32?
}

///|
/// Read the schema list itself: the size byte / varint, then each
/// element struct's fields.
fn schema_read_list(r : ThriftReader, into : Array[SchemaElem]) -> Bool {
  let count = match list_header(r, 12) {
    Some(c) => c
    None => return false
  }
  for _ in 0..<count {
    let mut name = ""
    let mut physical = 0
    let mut converted : Int32? = None
    let mut scale : Int32? = None
    let mut last = 0
    for ;; {
      match r.field_header(last) {
        None => return false
        Some(h) =>
          if h.wire is Stop {
            break
          } else {
            last = h.id
            match h.id {
              1 =>
                match r.zigzag_i32() {
                  Some(v) => physical = v
                  None => return false
                }
              4 =>
                match r.text() {
                  Some(v) => name = v
                  None => return false
                }
              6 =>
                match r.zigzag_i32() {
                  Some(v) => converted = Some(v)
                  None => return false
                }
              7 =>
                match r.zigzag_i32() {
                  Some(v) => scale = Some(v)
                  None => return false
                }
              _ => if !r.skip(h.wire) { return false }
            }
          }
      }
    }
    into.push({ name, physical, converted, decimal_scale: scale, })
  }
  true
}

///|
/// A list header: the (size<<4)|elem byte or the 0xF long form. Returns
/// the element count, or `None` on a mismatched element type.
fn list_header(r : ThriftReader, elem_want : Int32) -> Int32? {
  match r.byte() {
    None => None
    Some(h) => {
      if (h & 0x0F) != elem_want {
        return None
      }
      let size = h >> 4
      if size == 15 {
        match r.varint() {
          Some(v) => Some(v.to_int())
          None => None
        }
      } else {
        Some(size)
      }
    }
  }
}

///|
/// The row-group list (field 4's payload): every group's column chunks,
/// concatenated in order.
fn row_groups_read(r : ThriftReader, into : Array[RawChunk]) -> Bool {
  let count = match list_header(r, 12) {
    Some(c) => c
    None => return false
  }
  for _ in 0..<count {
    let mut last = 0
    for ;; {
      match r.field_header(last) {
        None => return false
        Some(h) =>
          if h.wire is Stop {
            break
          } else {
            last = h.id
            if h.id == 1 {
              if !column_chunks_read(r, into) {
                return false
              }
            } else if !r.skip(h.wire) {
              return false
            }
          }
      }
    }
  }
  true
}

///|
/// The column-chunk list inside a row group.
fn column_chunks_read(r : ThriftReader, into : Array[RawChunk]) -> Bool {
  let count = match list_header(r, 12) {
    Some(c) => c
    None => return false
  }
  for _ in 0..<count {
    let mut last = 0
    for ;; {
      match r.field_header(last) {
        None => return false
        Some(h) =>
          if h.wire is Stop {
            break
          } else {
            last = h.id
            if h.id == 3 {
              if !column_meta_read(r, into) {
                return false
              }
            } else if !r.skip(h.wire) {
              return false
            }
          }
      }
    }
  }
  true
}

///|
/// One ColumnMetaData struct: type (1), path_in_schema (3, a one-string
/// list under the flat schema), codec (4), num_values (5),
/// total_compressed_size (7), data_page_offset (9),
/// dictionary_page_offset (11 — where the pages really start when a
/// dictionary page precedes).
fn column_meta_read(r : ThriftReader, into : Array[RawChunk]) -> Bool {
  let mut _physical = 0
  let mut codec = 0
  let mut num_values = 0L
  let mut compressed = 0L
  let mut data_page_offset = 0L
  let mut dictionary_page_offset = 0L
  let mut path = ""
  let mut last = 0
  for ;; {
    match r.field_header(last) {
      None => return false
      Some(h) =>
        if h.wire is Stop {
          break
        } else {
          last = h.id
          match h.id {
            1 =>
              match r.zigzag_i32() {
                Some(v) => _physical = v
                None => return false
              }
            3 => {
              let strings = match list_header(r, 8) {
                Some(c) => c
                None => return false
              }
              // The flat schema names exactly one path element; a
              // nested path is a nested dtype this reader refuses.
              if strings != 1 {
                return false
              }
              match r.text() {
                Some(v) => path = v
                None => return false
              }
            }
            4 =>
              match r.zigzag_i32() {
                Some(v) => codec = v
                None => return false
              }
            5 =>
              match r.zigzag_i64() {
                Some(v) => num_values = v
                None => return false
              }
            7 =>
              match r.zigzag_i64() {
                Some(v) => compressed = v
                None => return false
              }
            9 =>
              match r.zigzag_i64() {
                Some(v) => data_page_offset = v
                None => return false
              }
            11 =>
              match r.zigzag_i64() {
                Some(v) => dictionary_page_offset = v
                None => return false
              }
            _ => if !r.skip(h.wire) { return false }
          }
        }
    }
  }
  let pages_at = if dictionary_page_offset > 0 &&
    (data_page_offset == 0 || dictionary_page_offset < data_page_offset) {
    dictionary_page_offset
  } else {
    data_page_offset
  }
  into.push({ name: path, codec, num_values, pages_at, compressed, })
  true
}

// ── the page walk ────────────────────────────────────────────────────

///|
/// One column chunk decoded into its cells: the page loop from the
/// chunk's first offset, each page's thrift header, its compressed
/// body, the definition levels, and the values. Every page shape
/// MoonFrame writes reads back, and the foreign shapes the mapping
/// accepts (PLAIN and RLE_DICTIONARY under V1 / V2) decode too; the
/// rest refuse with the column named.
fn decode_column(
  bytes : Bytes,
  column : ColumnRead,
) -> @series.Series raise @types.DataError {
  let chunk = column.chunk
  let map = column.map
  let total = chunk.num_values
  // A chunk cannot carry more values than its bytes could spell —
  // eight one-bit cells to a byte is the densest parquet encoding — so
  // the value count rides an Int64 against the file's own length: a
  // hundred-byte file claiming two billion values refuses here, before
  // any allocation the count would name.
  if total < 0L || total > bytes.length().to_int64() * 8L {
    raise bad(
      "column \"\{chunk.name}\" claims \{total} values, beyond what its bytes could carry",
    )
  }
  let defs : Array[Int32] = []
  // The present values, decoded per physical type; the dictionary
  // (when a dictionary page precedes) holds the value set.
  let mut dictionary : Array[@types.Scalar] = []
  let values : Array[@types.Scalar?] = []
  // The chunk's own byte region is validated in Int64 before it rides
  // Int32 indices — a footer naming an offset or size past the file (or
  // past the Int32 range, where the truncating conversion would fold
  // it back inside) refuses at the boundary.
  let chunk_start = chunk.pages_at
  let chunk_end = chunk_start + chunk.compressed
  if chunk_start < 0L ||
    chunk_end < chunk_start ||
    chunk_end > bytes.length().to_int64() {
    raise bad("column \"\{chunk.name}\" leaves the file")
  }
  let mut at = chunk_start.to_int()
  let end = chunk_end.to_int()
  let mut produced = 0L
  while produced < total {
    if at >= end || at >= bytes.length() {
      raise bad("column \"\{chunk.name}\" ends before its values")
    }
    // The chunk's own byte region — the page walk parses inside it, so
    // a truncated or over-long chunk size refuses at its boundary
    // instead of reading the bytes that follow the chunk as though
    // they were its own.
    let chunk_bytes = slice(bytes, at, end - at)
    let chunk_reader = thrift_reader(chunk_bytes)
    // One page header.
    let r = chunk_reader
    let mut _uncompressed = 0
    let mut compressed_size = 0
    let mut page_type = 0
    let mut num_values = 0
    let mut encoding = 0
    let mut v2 = false
    let mut def_len = 0
    let mut last = 0
    for ;; {
      let h = match r.field_header(last) {
        Some(h) => h
        None => raise bad("a page header is malformed")
      }
      if h.wire is Stop {
        break
      }
      last = h.id
      match h.id {
        1 =>
          match r.zigzag_i32() {
            Some(v) => page_type = v
            None => raise bad("a page type is malformed")
          }
        2 =>
          match r.zigzag_i32() {
            Some(v) => _uncompressed = v
            None => raise bad("a page size is malformed")
          }
        3 =>
          match r.zigzag_i32() {
            Some(v) => compressed_size = v
            None => raise bad("a page size is malformed")
          }
        5 => {
          // DataPageHeader (V1): num_values (1), encoding (2),
          // definition_level_encoding (3).
          let mut inner_last = 0
          for ;; {
            let hi = match r.field_header(inner_last) {
              Some(h) => h
              None => raise bad("a V1 page header is malformed")
            }
            if hi.wire is Stop {
              break
            }
            inner_last = hi.id
            match hi.id {
              1 =>
                match r.zigzag_i32() {
                  Some(v) => num_values = v
                  None => raise bad("a page count is malformed")
                }
              2 =>
                match r.zigzag_i32() {
                  Some(v) => encoding = v
                  None => raise bad("a page encoding is malformed")
                }
              _ =>
                if !r.skip(hi.wire) {
                  raise bad("a V1 page header is malformed")
                }
            }
          }
        }
        7 => {
          // DictionaryPageHeader: encoding (1) and num_values (2); the
          // body that follows is PLAIN over the whole value set.
          let mut inner_last = 0
          let mut dict_count = 0
          let mut dict_encoding = 0
          for ;; {
            let hi = match r.field_header(inner_last) {
              Some(h) => h
              None => raise bad("a dictionary header is malformed")
            }
            if hi.wire is Stop {
              break
            }
            inner_last = hi.id
            match hi.id {
              1 =>
                match r.zigzag_i32() {
                  Some(v) => dict_encoding = v
                  None => raise bad("a dictionary encoding is malformed")
                }
              2 =>
                match r.zigzag_i32() {
                  Some(v) => dict_count = v
                  None => raise bad("a dictionary count is malformed")
                }
              _ =>
                if !r.skip(hi.wire) {
                  raise bad("a dictionary header is malformed")
                }
            }
          }
          if dict_encoding != 0 {
            if dict_encoding != 2 && dict_encoding != 8 {
              raise bad("a dictionary page carries an unsupported encoding")
            }
          }
          ignore(dict_count)
        }
        8 => {
          // DataPageHeaderV2: num_values (1), num_nulls (2), num_rows
          // (3), encoding (4), definition_levels_byte_length (5),
          // repetition_levels_byte_length (6), is_compressed (7).
          v2 = true
          let mut inner_last = 0
          let mut rep_len = 0
          for ;; {
            let hi = match r.field_header(inner_last) {
              Some(h) => h
              None => raise bad("a V2 page header is malformed")
            }
            if hi.wire is Stop {
              break
            }
            inner_last = hi.id
            match hi.id {
              1 =>
                match r.zigzag_i32() {
                  Some(v) => num_values = v
                  None => raise bad("a page count is malformed")
                }
              4 =>
                match r.zigzag_i32() {
                  Some(v) => encoding = v
                  None => raise bad("a page encoding is malformed")
                }
              5 =>
                match r.zigzag_i32() {
                  Some(v) => def_len = v
                  None => raise bad("a page level length is malformed")
                }
              6 =>
                match r.zigzag_i32() {
                  Some(v) => rep_len = v
                  None => raise bad("a page level length is malformed")
                }
              _ =>
                if !r.skip(hi.wire) {
                  raise bad("a V2 page header is malformed")
                }
            }
          }
          ignore(rep_len)
        }
        _ => if !r.skip(h.wire) { raise bad("a page header is malformed") }
      }
    }
    // `r.pos` is an offset into the chunk's own region; the page body
    // is the chunk bytes after the header, and the walk's file offset
    // advances by the same amount. The bound is spelled as a
    // subtraction — `body_in_chunk` never passes the chunk's own
    // length, so it cannot wrap, while the addition of a hostile
    // `compressed_size` could.
    let body_in_chunk = r.pos
    if compressed_size < 0 ||
      compressed_size > chunk_bytes.length() - body_in_chunk {
      raise bad("a page body leaves the chunk")
    }
    at = at + body_in_chunk + compressed_size
    // A page cannot name more values than the chunk still owes: the
    // count sizes every per-value allocation below, so it is checked
    // against the chunk's own total before anything is built by it —
    // a page header claiming two billion values in a three-row chunk
    // refuses here instead of allocating the array it names.
    if num_values < 0 || produced + num_values.to_int64() > total {
      raise bad(
        "a page of column \"\{chunk.name}\" claims \{num_values} values past its chunk",
      )
    }
    // The body's values ride the codec. V1 compresses levels and
    // values together; V2 keeps the level bytes raw at the page head
    // and compresses only the values after them (the flat schema's
    // repetition levels are zero-width, so the head is `def_len` bytes
    // long) — the codec's input is the values alone, and what it yields
    // is values from byte zero. Sending a V2 page's head through the
    // decompressor would reject every foreign V2 file.
    let values_input = if v2 {
      if def_len < 0 || def_len > compressed_size {
        raise bad("a V2 page's levels leave its body")
      }
      slice(chunk_bytes, body_in_chunk + def_len, compressed_size - def_len)
    } else {
      slice(chunk_bytes, body_in_chunk, compressed_size)
    }
    let body = match chunk.codec {
      0 => values_input
      1 =>
        match snappy_decompress(values_input) {
          Some(b) => b
          None => raise bad("a SNAPPY page body does not decompress")
        }
      2 =>
        @gzip.decompress(values_input) catch {
          _ => raise bad("a GZIP page body does not decompress")
        }
      c =>
        raise @types.DataError::Unsupported(
          "parquet column \"\{chunk.name}\" carries compression codec \{c}",
        )
    }
    // A dictionary page's body is the PLAIN value set itself — no
    // levels, no indices — so it is handled before the level decoding
    // the data pages carry.
    if page_type == 2 {
      dictionary = decode_plain_values(
        body,
        map,
        dictionary_capacity(body, map),
        chunk.name,
      )
      produced = produced + num_values.to_int64()
      continue
    }
    // V1: the body is levels-then-values, RLE-coded levels at width 1
    // — the decoder's own output array is the level array, no second
    // allocation. V2: the levels are raw bit-packed bytes at the page
    // head (one bit per cell, outside the compression); the slice above
    // already lifted the head off the codec input, so the body is
    // values from byte zero under every codec.
    let (page_defs, values_at) = if !v2 {
      let (decoded, consumed) = match rle_decode(body, num_values, 1) {
        Some(d) => d
        None => raise bad("definition levels do not decode")
      }
      (decoded, consumed)
    } else {
      let level_bytes = slice(chunk_bytes, body_in_chunk, def_len)
      let defs : Array[Int32] = Array::makei(num_values, _ => 1)
      for i in 0..<num_values {
        if i / 8 < level_bytes.length() {
          defs[i] = (level_bytes[i / 8].to_int() >> (i % 8)) & 1
        }
      }
      (defs, 0)
    }
    let value_bytes = slice(body, values_at, body.length() - values_at)
    if page_type != 0 {
      raise @types.DataError::Unsupported(
        "parquet column \"\{chunk.name}\" carries a page type \{page_type} MoonFrame does not read",
      )
    }
    let present_count = count_present(page_defs)
    match encoding {
      0 => {
        let decoded = decode_plain_values(
          value_bytes,
          map,
          present_count,
          chunk.name,
        )
        let mut at_value = 0
        for i in 0..<num_values {
          if page_defs[i] == 1 {
            values.push(Some(decoded[at_value]))
            at_value = at_value + 1
          } else {
            values.push(None)
          }
          defs.push(page_defs[i])
        }
      }
      2 | 8 => {
        let bit_width = if value_bytes.length() > 0 {
          value_bytes[0].to_int()
        } else {
          0
        }
        let index_stream = slice(value_bytes, 1, value_bytes.length() - 1)
        let (indices, _consumed) = match
          rle_decode(index_stream, present_count, bit_width) {
          Some(d) => d
          None => raise bad("dictionary indices do not decode")
        }
        let mut at_value = 0
        for i in 0..<num_values {
          if page_defs[i] == 1 {
            let idx = indices[at_value]
            if idx < 0 || idx >= dictionary.length() {
              raise bad("a dictionary index leaves the value set")
            }
            values.push(Some(dictionary[idx]))
            at_value = at_value + 1
          } else {
            values.push(None)
          }
          defs.push(page_defs[i])
        }
      }
      e =>
        raise @types.DataError::Unsupported(
          "parquet column \"\{chunk.name}\" carries encoding \{e} MoonFrame does not read",
        )
    }
    produced = produced + num_values.to_int64()
  }
  build_series(chunk.name, map, values)
}

///|
/// A byte slice, copied. A length past the buffer clamps to what is
/// there (a negative one to nothing) — the page walk's own bounds
/// checks refuse malformed sizes with a located error; this helper
/// never adds a second refusal shape of its own.
fn slice(bytes : Bytes, at : Int32, len : Int32) -> Bytes {
  if at < 0 || at >= bytes.length() || len <= 0 {
    return Bytes::from_array([])
  }
  let end = if at + len > bytes.length() { bytes.length() } else { at + len }
  Bytes::makei(end - at, i => bytes[at + i])
}

///|
/// How many definition levels are present.
fn count_present(defs : Array[Int32]) -> Int32 {
  let mut n = 0
  for d in defs {
    if d == 1 {
      n = n + 1
    }
  }
  n
}

///|
/// The BOOLEAN dictionary capacity: eight cells to a byte, clamped at
/// the Int32 ceiling so the product cannot wrap negative (a wrapped
/// capacity is an empty dictionary, and empty means every index
/// refuses). The clamp arm needs a dictionary body past 2^28 bytes —
/// more memory than a test may spend — so the function rides
/// `#coverage.skip`; the in-range product is exercised by every
/// dictionary round-trip.
#coverage.skip
fn boolean_dictionary_cap(bytes : Bytes) -> Int32 {
  let cap = bytes.length().to_int64() * 8L
  if cap > 2147483647L {
    2147483647
  } else {
    cap.to_int()
  }
}

///|
/// The dictionary capacity a dictionary page's bytes name.
fn dictionary_capacity(bytes : Bytes, map : DtypeMap) -> Int32 {
  match map.physical {
    Boolean => boolean_dictionary_cap(bytes)
    Int32P => bytes.length() / 4
    Int64P | DoubleP => bytes.length() / 8
    ByteArrayP => {
      let mut n = 0
      let mut at = 0
      while at + 4 <= bytes.length() {
        let len = le_i32(bytes, at)
        if len < 0 || at + 4 + len > bytes.length() {
          break
        }
        at = at + 4 + len
        n = n + 1
      }
      n
    }
  }
}

///|

///|
/// Decode `count` PLAIN values of the mapped physical type.
fn decode_plain_values(
  bytes : Bytes,
  map : DtypeMap,
  count : Int32,
  name : String,
) -> Array[@types.Scalar] raise @types.DataError {
  let out : Array[@types.Scalar] = []
  let mut at = 0
  for _ in 0..<count {
    match map.physical {
      Int64P => {
        if at + 8 > bytes.length() {
          raise bad("column \"\{name}\" PLAIN values end early")
        }
        let v = le_i64(bytes, at)
        at = at + 8
        out.push(scalar_of_physical(map, v, 0.0))
      }
      DoubleP => {
        if at + 8 > bytes.length() {
          raise bad("column \"\{name}\" PLAIN values end early")
        }
        let v = le_f64(bytes, at)
        at = at + 8
        out.push(scalar_of_physical(map, 0L, v))
      }
      Int32P => {
        if at + 4 > bytes.length() {
          raise bad("column \"\{name}\" PLAIN values end early")
        }
        let v = le_i32(bytes, at)
        at = at + 4
        out.push(scalar_of_physical(map, v.to_int64(), 0.0))
      }
      Boolean => {
        // PLAIN BOOLEAN is bit-packed, eight cells to a byte: `at` is a
        // bit index, so the bound is the byte it lands in. Comparing
        // the bit index against the byte count itself rejects every
        // legal page from its ninth cell on.
        if at / 8 >= bytes.length() {
          raise bad("column \"\{name}\" PLAIN values end early")
        }
        let bit = bool_bit(bytes, at)
        at = at + 1
        out.push(@types.Scalar::Bool(bit))
      }
      ByteArrayP =>
        match le_bytes_prefix(bytes, at) {
          Some((start, len)) => {
            let text_bytes = slice(bytes, start, len)
            let text = @utf8.decode(text_bytes) catch {
              _ => raise bad("column \"\{name}\" carries a non-UTF-8 cell")
            }
            out.push(@types.Scalar::String(text))
            at = start + len
          }
          None => raise bad("column \"\{name}\" PLAIN values end early")
        }
    }
  }
  out
}

///|
/// The scalar a numeric physical value names under its map.
fn scalar_of_physical(
  map : DtypeMap,
  int_value : Int64,
  float_value : Double,
) -> @types.Scalar {
  match map.dtype {
    Timestamp => @types.Scalar::Timestamp(int_value)
    Decimal(scale) => @types.Scalar::Decimal(scale, int_value)
    Date => @types.Scalar::Date(int_value)
    Float => @types.Scalar::Float(float_value)
    // `Bool` and `String` decode through their own physical arms (the
    // bit reader and the length-prefixed reader), so the numeric arms
    // above plus this `Int` spelling cover everything that reaches here.
    // A written `Duration` reads back through its bare INT64 as an `Int`
    // (no converted annotation names a microsecond span), so the map it
    // decodes under is `Int` and its arm is the enum's completeness
    // fence.
    Int | Bool | String | Duration | Null => @types.Scalar::Int(int_value)
  }
}
