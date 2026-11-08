// The parquet file reader — the footer walk (thrift FileMetaData: the
// schema elements, the row groups' column chunks), then per column: the
// page headers, the compressed bodies, the RLE definition levels, and
// the PLAIN or dictionary-decoded values. V1 and V2 data pages both
// decode; the encodings and physical types MoonFrame does not carry
// refuse with the column named. Projection rides the caller: only the
// columns it names are walked at all.

///|
/// The most cells one column chunk may declare — the allocation-budget
/// guard, the reader's own spelling of the cap the io layer's gzip read
/// carries (`max_output` on one decompression): the file-length bound
/// already holds a chunk to eight one-bit cells per byte of file, but a
/// twenty-megabyte file can still legally claim a hundred and sixty
/// million of them, and every cell past here sizes boxed values the
/// decode would build — past the budget the column refuses loudly
/// instead of letting the expansion run the process out of memory.
const PARQUET_CELL_BUDGET : Int64 = 1L << 27

///|
/// One column's footer facts, before the schema pairing. The physical
/// tag rides the chunk because the pairing compares it — the schema's
/// own element names the dtype the chunk decodes under, and a
/// disagreement between the two is the pairing's refusal.
priv struct RawChunk {
  name : String
  physical : Int32
  codec : Int32
  num_values : Int64
  pages_at : Int64
  compressed : Int64
}

///|
/// The paired column: a chunk plus its schema row's dtype map, and
/// whether that row spells REQUIRED — a required column's max definition
/// level is 0, so its pages carry no level section at all.
priv struct ColumnRead {
  chunk : RawChunk
  map : DtypeMap
  required : Bool
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
/// Parse a whole parquet file's footer: the magic at both ends, the
/// length, the FileMetaData thrift, and the chunk→schema pairing.
fn read_footer(bytes : Bytes) -> ParquetFooter raise @types.DataError {
  let n = bytes.length()
  if n < 12 ||
    bytes[n - 4] != b'P' ||
    bytes[n - 3] != b'A' ||
    bytes[n - 2] != b'R' ||
    bytes[n - 1] != b'1' {
    raise bad("not a parquet file: the trailing magic is missing")
  }
  // The format opens with the same magic it closes with — a reader that
  // checked only the trailing half would accept any garbage prefixed to
  // a legal file as though the file were parquet from byte zero.
  if bytes[0] != b'P' ||
    bytes[1] != b'A' ||
    bytes[2] != b'R' ||
    bytes[3] != b'1' {
    raise bad("not a parquet file: the leading magic is missing")
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
  if !walk_fields_raise(r, (id, wire) => {
      match id {
        2 => {
          if !schema_read_list(r, schema) {
            raise bad("the schema list is malformed")
          }
          refuse_nested_groups(schema)
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
          if !r.skip(wire) {
            raise bad("the footer carries an undecodable field")
          }
      }
    }) {
    raise bad("the footer ends mid-field")
  }
  // Pair each chunk with its schema element by column name; the root
  // element (index 0) is the schema's own head, not a column.
  let columns : Array[ColumnRead] = []
  for chunk in chunks {
    let mut paired : (DtypeMap, Bool)? = None
    for i in 1..<schema.length() {
      if schema[i].name == chunk.name {
        if schema[i].repetition == 2 {
          raise bad(
            "column \"\{chunk.name}\" is REPEATED, a nested shape MoonFrame does not read",
          )
        }
        // The chunk's own metadata names the physical type a second
        // time, and the two spellings must agree: a chunk decoding
        // INT64 bytes under an INT32 schema row (or any other
        // disagreement) would decode confidently wrong cells, so the
        // pairing refuses naming both tags.
        if schema[i].physical != chunk.physical {
          raise @types.DataError::InvalidOperation(
            "column \"\{chunk.name}\" carries physical type \{chunk.physical} in its chunk metadata but physical type \{schema[i].physical} in its schema",
          )
        }
        paired = match
          map_from_schema(
            schema[i].physical,
            schema[i].converted,
            schema[i].decimal_scale,
            schema[i].decimal_precision,
          ) {
          Some(map) => Some((map, schema[i].repetition == 0))
          None => None
        }
        break
      }
    }
    match paired {
      Some((map, required)) => columns.push({ chunk, map, required, })
      None =>
        raise @types.DataError::Unsupported(
          "parquet column \"\{chunk.name}\" carries a dtype MoonFrame cannot map",
        )
    }
  }
  { columns, num_rows, }
}

///|
/// A schema element naming children is a nested schema's node — the
/// flat schema is the only shape this reader walks. A group carries no
/// physical type, so a chunk paired against one would decode under a
/// meaningless map; the file refuses naming the group instead. The root
/// (the list's first element) names the columns themselves and is the
/// one group every legal file carries.
fn refuse_nested_groups(
  schema : Array[SchemaElem],
) -> Unit raise @types.DataError {
  for i in 1..<schema.length() {
    if schema[i].num_children > 0 {
      raise bad(
        "the schema carries the nested group \"\{schema[i].name}\", which MoonFrame does not read",
      )
    }
  }
}

///|
/// One schema element's decoded facts. `physical` is `-1` where the
/// element names none (a group names children instead; a leaf without a
/// type is malformed), and `repetition` is `-1` where the element spells
/// none — the flat reader then treats it as OPTIONAL, the shape every
/// nullable leaf carries.
priv struct SchemaElem {
  name : String
  physical : Int32
  repetition : Int32
  num_children : Int32
  converted : Int32?
  decimal_scale : Int32?
  decimal_precision : Int32?
}

///|
/// Read the schema list itself: the size byte / varint, then each
/// element struct's fields — the physical type (1), the repetition type
/// (3), the name (4), the child count (5), the converted annotation (6),
/// the decimal scale (7), and the decimal precision (8).
fn schema_read_list(r : ThriftReader, into : Array[SchemaElem]) -> Bool {
  let count = match list_header(r, 12) {
    Some(c) => c
    None => return false
  }
  for _ in 0..<count {
    let mut name = ""
    let mut physical = -1
    let mut repetition = -1
    let mut num_children = 0
    let mut converted : Int32? = None
    let mut scale : Int32? = None
    let mut precision : Int32? = None
    let walked = walk_fields(r, (id, wire) => {
      match id {
        1 =>
          match r.zigzag_i32() {
            Some(v) => {
              physical = v
              true
            }
            None => false
          }
        3 =>
          match r.zigzag_i32() {
            Some(v) => {
              repetition = v
              true
            }
            None => false
          }
        4 =>
          match r.text() {
            Some(v) => {
              name = v
              true
            }
            None => false
          }
        5 =>
          match r.zigzag_i32() {
            Some(v) => {
              num_children = v
              true
            }
            None => false
          }
        6 =>
          match r.zigzag_i32() {
            Some(v) => {
              converted = Some(v)
              true
            }
            None => false
          }
        7 =>
          match r.zigzag_i32() {
            Some(v) => {
              scale = Some(v)
              true
            }
            None => false
          }
        8 =>
          match r.zigzag_i32() {
            Some(v) => {
              precision = Some(v)
              true
            }
            None => false
          }
        _ => r.skip(wire)
      }
    })
    if !walked {
      return false
    }
    into.push({
      name,
      physical,
      repetition,
      num_children,
      converted,
      decimal_scale: scale,
      decimal_precision: precision,
    })
  }
  true
}

///|
/// A list header: the (size<<4)|elem byte or the 0xF long form. Returns
/// the element count, or `None` on a mismatched element type. The
/// long-form count rides the same ceiling the skipper holds — past it
/// the varint is a bomb's claim, and its truncating Int32 fold would
/// read a huge count as zero (or as a negative the callers' loops treat
/// as no elements) instead of refusing.
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
          Some(v) => if v > 0x1000_0000UL { None } else { Some(v.to_int()) }
          None => None
        }
      } else {
        Some(size)
      }
    }
  }
}

///|
/// Walk one thrift struct's fields in arrival order, handing each field's
/// id and wire type to `visit` until the Stop marker. `visit` returns
/// false to refuse the struct (a malformed payload it failed to read);
/// the walker itself refuses a reader that runs out mid-struct by
/// returning false. One spelling of the protocol — headers arrive in
/// ascending id order with the last seen id handed back to the reader,
/// and a struct ends at its Stop marker — shared by every footer and
/// page-header struct reader. The raising twin below carries the same
/// walk for the readers whose visits raise.
fn walk_fields(r : ThriftReader, visit : (Int32, WireType) -> Bool) -> Bool {
  let mut last = 0
  for ;; {
    let header = match r.field_header(last) {
      Some(h) => h
      None => return false
    }
    if header.wire is Stop {
      return true
    }
    last = header.id
    if !visit(header.id, header.wire) {
      return false
    }
  }
}

///|
/// The raising twin of `walk_fields`, for the readers whose visits raise
/// their own named refusals — the same walk, the same protocol.
fn walk_fields_raise(
  r : ThriftReader,
  visit : (Int32, WireType) -> Unit raise @types.DataError,
) -> Bool raise @types.DataError {
  let mut last = 0
  for ;; {
    let header = match r.field_header(last) {
      Some(h) => h
      None => return false
    }
    if header.wire is Stop {
      return true
    }
    last = header.id
    visit(header.id, header.wire)
  }
}

///|
/// The row-group list (field 4's payload): every group's column chunks,
/// concatenated in order — for the one group this reader walks. A file
/// declaring more than one names a shape MoonFrame does not read yet:
/// concatenating the groups' chunks would splice same-named columns
/// into one file-wide chunk list, so the count refuses here instead.
fn row_groups_read(
  r : ThriftReader,
  into : Array[RawChunk],
) -> Bool raise @types.DataError {
  let count = match list_header(r, 12) {
    Some(c) => c
    None => return false
  }
  if count > 1 {
    raise @types.DataError::Unsupported(
      "multi-row-group parquet files are not supported yet: the file declares \{count} row groups",
    )
  }
  for _ in 0..<count {
    if !walk_fields(r, (id, wire) => {
        if id == 1 {
          column_chunks_read(r, into)
        } else {
          r.skip(wire)
        }
      }) {
      return false
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
    if !walk_fields(r, (id, wire) => {
        if id == 3 {
          column_meta_read(r, into)
        } else {
          r.skip(wire)
        }
      }) {
      return false
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
  let mut physical = 0
  let mut codec = 0
  let mut num_values = 0L
  let mut compressed = 0L
  let mut data_page_offset = 0L
  let mut dictionary_page_offset = 0L
  let mut path = ""
  let walked = walk_fields(r, (id, wire) => {
    match id {
      1 =>
        match r.zigzag_i32() {
          Some(v) => {
            physical = v
            true
          }
          None => false
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
          Some(v) => {
            path = v
            true
          }
          None => false
        }
      }
      4 =>
        match r.zigzag_i32() {
          Some(v) => {
            codec = v
            true
          }
          None => false
        }
      5 =>
        match r.zigzag_i64() {
          Some(v) => {
            num_values = v
            true
          }
          None => false
        }
      7 =>
        match r.zigzag_i64() {
          Some(v) => {
            compressed = v
            true
          }
          None => false
        }
      9 =>
        match r.zigzag_i64() {
          Some(v) => {
            data_page_offset = v
            true
          }
          None => false
        }
      11 =>
        match r.zigzag_i64() {
          Some(v) => {
            dictionary_page_offset = v
            true
          }
          None => false
        }
      _ => r.skip(wire)
    }
  })
  if !walked {
    return false
  }
  let pages_at = if dictionary_page_offset > 0 &&
    (data_page_offset == 0 || dictionary_page_offset < data_page_offset) {
    dictionary_page_offset
  } else {
    data_page_offset
  }
  into.push({ name: path, physical, codec, num_values, pages_at, compressed, })
  true
}

// ── the page walk ────────────────────────────────────────────────────

///|
/// The most decompressed bytes one GZIP page body may produce — the
/// page-level spelling of the io layer's gzip read cap, where the
/// SNAPPY codec's own declared-length guard refuses the same
/// decompression bomb before its expansion runs. A compressed page of a
/// few bytes can name gigabytes of payload; past this cap the page
/// refuses instead of letting the inflation run the process out of
/// memory.
const GZIP_PAGE_MAX_OUTPUT : Int32 = 0x4000_0000

///|
/// Decompress one GZIP page body under the page cap — the cap rides the
/// inflater itself, never a declared size the stream could misname, so
/// only the bytes actually produced count against it.
fn gzip_page_body(bytes : Bytes) -> Bytes raise @types.DataError {
  gzip_page_body_capped(bytes, GZIP_PAGE_MAX_OUTPUT)
}

///|
/// `gzip_page_body` with the cap as a parameter — production reads pass
/// `GZIP_PAGE_MAX_OUTPUT`; the whitebox tests pass a small one, because
/// inflating a real gigabyte past the production cap is exactly the
/// cost the guard exists to spare.
fn gzip_page_body_capped(
  bytes : Bytes,
  cap : Int32,
) -> Bytes raise @types.DataError {
  @gzip.decompress(bytes, max_output=cap) catch {
    // The cap's refusal, kept apart from the malformed-stream arm: the
    // message names the cap rather than claiming the stream is invalid.
    @gzip.GzipError(OutputLimitExceeded(limit~, observed~), _detail) =>
      raise bad(
        "a GZIP page body inflates past the \{limit}-byte decompression cap (already \{observed} bytes produced)",
      )
    _ => raise bad("a GZIP page body does not decompress")
  }
}

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
  // The absolute cell budget: the file-length bound above still admits
  // a small file legally claiming an expansion-sized count, and every
  // cell the count names becomes a boxed value below — so a count past
  // the budget refuses here, before any allocation it would size.
  if total > PARQUET_CELL_BUDGET {
    raise @types.DataError::InvalidOperation(
      "column \"\{chunk.name}\" declares \{total} values, past the \{PARQUET_CELL_BUDGET}-cell budget a single column read accepts",
    )
  }
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
  // The chunk's own byte region, sliced once — the page walk parses
  // inside it, so a truncated or over-long chunk size refuses at its
  // boundary instead of reading the bytes that follow the chunk as
  // though they were its own, and the walk below advances through it by
  // page offsets instead of re-copying the whole remaining chunk per
  // page.
  let chunk_bytes = slice(
    bytes,
    chunk_start.to_int(),
    (chunk_end - chunk_start).to_int(),
  )
  let end = chunk_bytes.length()
  let mut at = 0
  let mut produced = 0L
  while produced < total {
    if at >= end {
      raise bad("column \"\{chunk.name}\" ends before its values")
    }
    // One page header, parsed in place at the page's own offset.
    let r = thrift_reader(chunk_bytes)
    r.pos = at
    let mut compressed_size = 0
    let mut page_type = 0
    let mut num_values = 0
    let mut encoding = 0
    let mut v2 = false
    let mut def_len = 0
    let mut rep_len = 0
    let mut page_compressed = true
    if !walk_fields_raise(r, (id, wire) => {
        match id {
          1 =>
            match r.zigzag_i32() {
              Some(v) => page_type = v
              None => raise bad("a page type is malformed")
            }
          3 =>
            match r.zigzag_i32() {
              Some(v) => compressed_size = v
              None => raise bad("a page size is malformed")
            }
          5 =>
            // DataPageHeader (V1): num_values (1), encoding (2),
            // definition_level_encoding (3). A page declaring its
            // definition levels BIT_PACKED (4) names the deprecated
            // pre-hybrid spelling — the level decoder walks the RLE /
            // bit-packed hybrid only, so the page refuses naming the
            // encoding instead of misreading the run.
            if !walk_fields_raise(r, (inner_id, inner_wire) => {
                match inner_id {
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
                  3 =>
                    match r.zigzag_i32() {
                      Some(4) =>
                        raise @types.DataError::Unsupported(
                          "a V1 page of column \"\{chunk.name}\" declares BIT_PACKED definition levels, a deprecated encoding MoonFrame does not read",
                        )
                      Some(_) => ()
                      None => raise bad("a V1 level encoding is malformed")
                    }
                  _ =>
                    if !r.skip(inner_wire) {
                      raise bad("a V1 page header is malformed")
                    }
                }
              }) {
              raise bad("a V1 page header is malformed")
            }
          7 => {
            // DictionaryPageHeader: num_values (1) and encoding (2), the
            // ids the parquet thrift bindings define; the body that
            // follows is PLAIN over the whole value set.
            let mut dict_encoding = 0
            if !walk_fields_raise(r, (inner_id, inner_wire) => {
                match inner_id {
                  1 =>
                    // The count names dictionary entries, not frame
                    // rows — read past it and move on.
                    match r.zigzag_i32() {
                      Some(_) => ()
                      None => raise bad("a dictionary count is malformed")
                    }
                  2 =>
                    match r.zigzag_i32() {
                      Some(v) => dict_encoding = v
                      None => raise bad("a dictionary encoding is malformed")
                    }
                  _ =>
                    if !r.skip(inner_wire) {
                      raise bad("a dictionary header is malformed")
                    }
                }
              }) {
              raise bad("a dictionary header is malformed")
            }
            if dict_encoding != 0 {
              if dict_encoding != 2 && dict_encoding != 8 {
                raise bad("a dictionary page carries an unsupported encoding")
              }
            }
          }
          8 => {
            // DataPageHeaderV2: num_values (1), num_nulls (2), num_rows
            // (3), encoding (4), definition_levels_byte_length (5),
            // repetition_levels_byte_length (6), is_compressed (7).
            v2 = true
            if !walk_fields_raise(r, (inner_id, inner_wire) => {
                match inner_id {
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
                  7 =>
                    // The compact protocol's bool rides the field header's
                    // own type nibble — the wire type is the value. Any
                    // other wire a hostile header spells is skipped by its
                    // own type, the unknown-field rule.
                    match inner_wire {
                      BoolTrue => page_compressed = true
                      BoolFalse => page_compressed = false
                      Stop | ByteV | I32V | I64V | BinaryV | ListV | StructV =>
                        if !r.skip(inner_wire) {
                          raise bad("a V2 page header is malformed")
                        }
                    }
                  _ =>
                    if !r.skip(inner_wire) {
                      raise bad("a V2 page header is malformed")
                    }
                }
              }) {
              raise bad("a V2 page header is malformed")
            }
          }
          _ => if !r.skip(wire) { raise bad("a page header is malformed") }
        }
      }) {
      raise bad("a page header is malformed")
    }
    // `r.pos` is the chunk-relative offset past the header — where the
    // page body sits — and the walk's own offset advances past header
    // and body together. The bound is spelled as a subtraction —
    // `body_at` never passes the chunk's own length, so it cannot wrap,
    // while the addition of a hostile `compressed_size` could.
    let body_at = r.pos
    if compressed_size < 0 || compressed_size > end - body_at {
      raise bad("a page body leaves the chunk")
    }
    at = body_at + compressed_size
    // A data page cannot name more values than the chunk still owes:
    // the count sizes every per-value allocation below, so it is checked
    // against the chunk's own total before anything is built by it — a
    // page header claiming two billion values in a three-row chunk
    // refuses here instead of allocating the array it names. A
    // dictionary page's count names its entries, not frame rows, so it
    // stands outside the check and outside `produced`.
    if page_type != 2 &&
      (num_values < 0 || produced + num_values.to_int64() > total) {
      raise bad(
        "a page of column \"\{chunk.name}\" claims \{num_values} values past its chunk",
      )
    }
    // The body's values ride the codec. V1 compresses levels and
    // values together; V2 keeps both level runs raw at the page head —
    // `rep_len` bytes of repetition levels, then `def_len` bytes of
    // definition levels, never compressed — and compresses only the
    // values after them, so the codec's input is the values alone and
    // what it yields is values from byte zero. Sending a V2 page's head
    // through the decompressor would reject every foreign V2 file. The
    // bounds are subtraction forms throughout (`compressed_size` is
    // already known non-negative and `def_len` no greater than it), so a
    // hostile level length cannot wrap the sum back inside.
    let values_input = if v2 {
      if def_len < 0 ||
        rep_len < 0 ||
        def_len > compressed_size ||
        rep_len > compressed_size - def_len {
        raise bad("a V2 page's levels leave its body")
      }
      slice(
        chunk_bytes,
        body_at + rep_len + def_len,
        compressed_size - rep_len - def_len,
      )
    } else {
      slice(chunk_bytes, body_at, compressed_size)
    }
    // The values ride the chunk's codec — unless the page is a V2 one
    // whose header spells is_compressed=false, a page-level opt-out
    // from the codec however the column metadata votes: its values are
    // raw where they sit.
    let body = if v2 && !page_compressed {
      values_input
    } else {
      match chunk.codec {
        0 => values_input
        1 =>
          match snappy_decompress(values_input) {
            Some(b) => b
            None => raise bad("a SNAPPY page body does not decompress")
          }
        2 => gzip_page_body(values_input)
        c =>
          raise @types.DataError::Unsupported(
            "parquet column \"\{chunk.name}\" carries compression codec \{c}",
          )
      }
    }
    // A dictionary page's body is the PLAIN value set itself — no
    // levels, no indices — so it is handled before the level decoding
    // the data pages carry. It owes the chunk no rows: the chunk's
    // num_values counts the data pages' cells alone, so the walk's
    // produced total does not move here.
    if page_type == 2 {
      dictionary = decode_plain_values(
        body,
        map,
        dictionary_capacity(body, map),
        chunk.name,
      )
      continue
    }
    // The level decoder's own ceiling: the cells the chunk still owes,
    // already bounded by the budget the chunk's total passed — the page
    // count check above has vouched that `num_values` sits inside it.
    let remaining = (total - produced).to_int()
    // A REQUIRED column's max definition level is 0, so neither page
    // version writes a level section: the body is values from byte zero
    // and every cell is present. V1 otherwise opens its level run with
    // a 4-byte little-endian length naming the encoded run's byte
    // count, the RLE-coded levels at width 1 behind it, and the values
    // after both. V2 carries its levels as an RLE / bit-packed hybrid
    // stream at the column's own def-level bit width (1 under the flat
    // schema's OPTIONAL leaves), raw at the page head with no length
    // prefix — the header's definition_levels_byte_length names the
    // run's size, and the flat schema's zero repetition width puts the
    // definition run first.
    let (page_defs, values_at) = if column.required {
      (Array::makei(num_values, _ => 1), 0)
    } else if !v2 {
      if body.length() < 4 {
        raise bad("a V1 page's level prefix ends early")
      }
      let level_len = le_i32(body, 0)
      if level_len < 0 || level_len > body.length() - 4 {
        raise bad("a V1 page's level length leaves its body")
      }
      match rle_decode(slice(body, 4, level_len), num_values, 1, remaining) {
        Some((decoded, _)) => (decoded, 4 + level_len)
        None => raise bad("definition levels do not decode")
      }
    } else {
      match
        rle_decode(
          slice(chunk_bytes, body_at + rep_len, def_len),
          num_values,
          1,
          remaining,
        ) {
        Some((decoded, _)) => (decoded, 0)
        None => raise bad("definition levels do not decode")
      }
    }
    let value_bytes = slice(body, values_at, body.length() - values_at)
    // The V2 data page rides its own page type (3) alongside the header
    // field that already named it; a DATA_PAGE header spelling type 0
    // with a V2 header inside stays readable (a writer's misspelling
    // the field spells unambiguously). Every other page type — an index
    // page, something unknown — refuses.
    if page_type != 0 && !(page_type == 3 && v2) {
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
          rle_decode(index_stream, present_count, bit_width, remaining) {
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
/// never adds a second refusal shape of its own. The clamp is spelled
/// as a subtraction — `at` already sits inside the buffer, so the
/// difference cannot wrap, while `at + len` could fold a hostile length
/// near the Int32 ceiling back inside (or past) the bound.
fn slice(bytes : Bytes, at : Int32, len : Int32) -> Bytes {
  if at < 0 || at >= bytes.length() || len <= 0 {
    return Bytes::from_array([])
  }
  let end = if len > bytes.length() - at { bytes.length() } else { at + len }
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
/// the cell budget so the product cannot wrap negative (a wrapped
/// capacity is an empty dictionary, and empty means every index
/// refuses) and the decode it sizes stays inside the cells one column
/// read accepts. The clamp arm needs a dictionary body past the budget's
/// own eighth — more memory than a test may spend — so the function
/// rides `#coverage.skip`; the in-range product is exercised by every
/// dictionary round-trip.
#coverage.skip
fn boolean_dictionary_cap(bytes : Bytes) -> Int32 {
  let cap = bytes.length().to_int64() * 8L
  if cap > PARQUET_CELL_BUDGET {
    PARQUET_CELL_BUDGET.to_int()
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
    // The unscaled magnitude lifts into the Dec128 value exactly at the
    // annotation's scale — a 19-digit Int64 at most, far inside the
    // format's 34.
    Decimal =>
      @types.Scalar::Decimal(
        @types.Dec128::of_int64_scale(int_value, scale=map.decimal_scale),
      )
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
