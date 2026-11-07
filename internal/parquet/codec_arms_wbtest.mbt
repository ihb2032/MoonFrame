// Whitebox arm-coverage for the codec's refusal and skip paths — the
// truncation arms of snappy and the thrift skipper, the schema mapping
// refusals, the RLE refusal shapes, the writer's own refusals — each
// fed a hand-built byte sequence that reaches exactly that arm. The
// happy paths live in the round-trip file; this is the negative space.

// ── snappy ───────────────────────────────────────────────────────────

///|
test "snappy refuses its malformed shapes" {
  // No preamble varint at all.
  assert_true(snappy_decompress(b"") is None)
  // A declared length past the guard.
  let huge : Array[Byte] = [
    (0xFF).to_byte(),
    (0xFF).to_byte(),
    (0xFF).to_byte(),
    (0xFF).to_byte(),
    (0xFF).to_byte(),
    (0x7F).to_byte(),
  ]
  assert_true(snappy_decompress(Bytes::from_array(huge)) is None)
  // A literal that runs past the input: length 5, two bytes present.
  assert_true(snappy_decompress(b"\x05\x08ab") is None)
  // A copy with an offset behind the start (copy1).
  assert_true(snappy_decompress(b"\x04\x08ab\x21\x01") is None)
  // A copy1 truncated after its tag.
  assert_true(snappy_decompress(b"\x04\x08a\x21") is None)
  // A copy2 truncated mid-offset.
  assert_true(snappy_decompress(b"\x04\x08a\x0E\x03") is None)
  // A copy4: 32-bit offset spelling, truncated.
  assert_true(snappy_decompress(b"\x06\x08a\x1D\x01\x00") is None)
  // A copy4 whose offset lands behind the start (fully spelled).
  assert_true(snappy_decompress(b"\x06\x08a\x1D\x01\x00\x00\x00\x00") is None)
  // A copy that writes past the declared length.
  assert_true(snappy_decompress(b"\x04\x08a\x0E\x0A\x00") is None)
  // A 60-extra-byte literal header (tag 0xF0) truncated in its extra
  // bytes.
  assert_true(snappy_decompress(b"\x08\xF0\xFF") is None)
  // And one that runs past the input after a wide literal header.
  assert_true(snappy_decompress(b"\x0A\xFD\x01ab") is None)
  // A stream that declares more than it writes: length 4, one literal
  // of one byte only.
  assert_true(snappy_decompress(b"\x04\x08a") is None)
  // A 4-byte extended literal length whose high byte folds past 2^31 —
  // the accumulation rides Int64 whole, so the bound refuses the
  // length instead of its truncated fold slipping past.
  let wide_bomb : Array[Byte] = [
    (0x10).to_byte(), // declared: 16 bytes
    (0xFC).to_byte(), // literal, 4 extra length bytes
    (0xFF).to_byte(),
    (0xFF).to_byte(),
    (0xFF).to_byte(),
    (0x80).to_byte(), // 0x80FFFFFF + 1 — past 2^31
  ]
  assert_true(snappy_decompress(Bytes::from_array(wide_bomb)) is None)
  // The same fold landing exactly on 2^32: once truncatable to zero, a
  // claim the Int64 accumulation still refuses against the bound.
  let wrap_bomb : Array[Byte] = [
    (0x10).to_byte(),
    (0xFC).to_byte(),
    (0x00).to_byte(),
    (0x00).to_byte(),
    (0x00).to_byte(),
    (0x01).to_byte(), // 2^32 + 1
  ]
  assert_true(snappy_decompress(Bytes::from_array(wrap_bomb)) is None)
}

///|
test "a GZIP page body past the cap refuses naming the cap" {
  // The cap rides the inflater itself, never a declared size — the
  // whitebox spelling passes a small one, because inflating a real
  // gigabyte past the production cap is exactly the cost the guard
  // exists to spare.
  let payload = Bytes::makei(200, i => (i * 31 % 251).to_byte())
  let compressed = @gzip.compress(payload)
  let result = Ok(ignore(gzip_page_body_capped(compressed, 8))) catch {
    e => Err(e)
  }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("cap"),
  )
  // The same body under the production cap reads: the helper's happy
  // arm is the one every GZIP page rides.
  assert_eq(gzip_page_body(compressed), payload)
}

///|
test "snappy decodes a 61-length literal and a copy4" {
  // A literal of 61 bytes: tag 0xF0 (60 = extra 1 byte), one extra
  // byte naming 60 (len - 1), then 61 payload bytes.
  let payload = Bytes::makei(61, i => ('a'.to_int() + i).to_byte())
  let stream : Array[Byte] = [
    (0x3D).to_byte(),
    (0xF0).to_byte(),
    (0x3C).to_byte(),
  ]
  for b in payload {
    stream.push(b)
  }
  match snappy_decompress(Bytes::from_array(stream)) {
    Some(out) => assert_eq(out.length(), 61)
    None => fail("61-length literal refused")
  }
  // A copy4 over two literals: "abcdef", then copy4 offset 6 length 5
  // → "abcdefabcde" (11).
  let copy4 : Array[Byte] = [(0x0B).to_byte(), (0x18).to_byte()]
  let lit : Array[Byte] = [(0x18).to_byte()]
  for i in 0..<6 {
    lit.push(('a'.to_int() + i).to_byte())
  }
  copy4.push((0x13).to_byte()) // (5-1)<<2 | 3
  copy4.push((0x06).to_byte())
  copy4.push((0x00).to_byte())
  copy4.push((0x00).to_byte())
  copy4.push((0x00).to_byte())
  let whole = Bytes::from_array(copy4)
  ignore(whole)
  ignore(lit)
  // spelled as one array: preamble 11, literal "abcdef" (tag (6-1)<<2 =
  // 0x14), copy4 tag 0x13, offset LE 06000000.
  let stream2 : Array[Byte] = [
    (0x0B).to_byte(),
    (0x14).to_byte(),
    'a'.to_int().to_byte(),
    'b'.to_int().to_byte(),
    'c'.to_int().to_byte(),
    'd'.to_int().to_byte(),
    'e'.to_int().to_byte(),
    'f'.to_int().to_byte(),
    (0x13).to_byte(),
    (0x06).to_byte(),
    (0x00).to_byte(),
    (0x00).to_byte(),
    (0x00).to_byte(),
  ]
  match snappy_decompress(Bytes::from_array(stream2)) {
    Some(out) => {
      assert_eq(out.length(), 11)
      assert_eq(out[10], 'e'.to_int().to_byte())
    }
    None => fail("copy4 refused")
  }
}

// ── thrift skipper ───────────────────────────────────────────────────

///|
test "the thrift skipper walks every wire type" {
  // A struct carrying: an unknown binary field, an unknown list of
  // i32 (short form), an unknown long-form list of structs, an unknown
  // nested struct, and the known i32 at id 1.
  let w = thrift_writer()
  w.i32_field(1, 7)
  w.binary_field(5, b"skip-me")
  // Short list: two i32 elements.
  w.field_header(6, 9)
  w.list_header(2, 5)
  w.i32_list_elem(1)
  w.i32_list_elem(2)
  // Long list (>14 elements) of structs, each with one i32.
  w.field_header(7, 9)
  w.list_header(20, 12)
  for _ in 0..<20 {
    w.struct_field_begin_list_elem()
    w.i32_field(1, 3)
    w.struct_end()
  }
  // A nested struct with a nested list inside it.
  w.struct_field_begin(8)
  w.field_header(2, 9)
  w.list_header(1, 8)
  w.text_list_elem("inner")
  w.struct_end()
  w.struct_end()
  let r = thrift_reader(w.finish())
  let mut value = 0
  let mut last = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    if h.id == 1 {
      value = r.zigzag_i32().unwrap()
    } else {
      assert_true(r.skip(h.wire))
    }
  }
  assert_eq(value, 7)
  // A list with an element type nothing carries (13 = map) refuses.
  let w2 = thrift_writer()
  w2.field_header(1, 9)
  w2.list_header(1, 13)
  let r2 = thrift_reader(w2.finish())
  let h2 = r2.field_header(0).unwrap()
  assert_true(!r2.skip(h2.wire))
  // A huge bool-element list over no bytes: each element consumes one
  // byte of its own, so the count is a claim the stream cannot pay —
  // the skip refuses at the first missing byte instead of spinning the
  // count against nothing. The header spells the long form (0xF1) with
  // a count of 0x0800_0000, inside the skipper's own ceiling.
  let bool_bomb : Array[Byte] = [(0xF1).to_byte()]
  push_varint_bytes(bool_bomb, 0x0800_0000UL)
  assert_true(!thrift_reader(Bytes::from_array(bool_bomb)).skip(ListV))
  // A field with a wire nibble nothing carries (7) refuses to header.
  let bad_header : Array[Byte] = [(0x17).to_byte()]
  assert_true(
    thrift_reader(Bytes::from_array(bad_header)).field_header(0) is None,
  )
}

// ── schema mapping ───────────────────────────────────────────────────

///|
test "the schema mapping refuses what MoonFrame cannot carry" {
  // FLOAT (4): would narrow a Double.
  assert_true(map_from_schema(4, None, None, None) is None)
  // INT96 (3) and FIXED_LEN_BYTE_ARRAY (7): dtypes MoonFrame does not
  // spell.
  assert_true(map_from_schema(3, None, None, None) is None)
  assert_true(map_from_schema(7, Some(5), None, None) is None)
  // A DECIMAL without a scale, or with one past the precision's own
  // envelope — the format makes the precision required and, over the
  // INT64 payload, one to eighteen digits with the scale never past it.
  assert_true(map_from_schema(2, Some(5), None, None) is None)
  assert_true(map_from_schema(2, Some(5), Some(2), None) is None)
  assert_true(map_from_schema(2, Some(5), Some(2), Some(0)) is None)
  assert_true(map_from_schema(2, Some(5), Some(2), Some(19)) is None)
  assert_true(map_from_schema(2, Some(5), Some(5), Some(4)) is None)
  assert_true(map_from_schema(2, Some(5), Some(-1), Some(18)) is None)
  // A BYTE_ARRAY without UTF8 is raw binary, not a String.
  assert_true(map_from_schema(6, None, None, None) is None)
  // A DATE must ride INT32; a TIMESTAMP_MICROS must ride INT64.
  assert_true(map_from_schema(2, Some(6), None, None) is None)
  assert_true(map_from_schema(1, Some(10), None, None) is None)
  // And the mapping the riders ride — a bare INT32 among them, the
  // signed shape a foreign int column carries.
  assert_true(map_from_schema(1, None, None, None) is Some(_))
  assert_true(map_from_schema(1, Some(6), None, None) is Some(_))
  assert_true(map_from_schema(2, Some(10), None, None) is Some(_))
  assert_true(map_from_schema(2, Some(5), Some(2), Some(18)) is Some(_))
  assert_true(map_from_schema(2, Some(5), Some(18), Some(18)) is Some(_))
  assert_eq(decimal_precision(), 18)
  // The dtype table's own refusal: a Null column cannot ride.
  assert_true(dtype_map(@types.DataType::Null) is None)
}

// ── rle refusals ─────────────────────────────────────────────────────

///|
test "rle refuses its malformed shapes" {
  // An RLE run past the count.
  assert_true(rle_decode(b"\x10\x01", 7, 1, 7) is None)
  // A bit-packed run shorter than the count needs.
  assert_true(rle_decode(b"\x03\x88\xC6\xFA", 9, 3, 9) is None)
  // A truncated value byte in an RLE run.
  assert_true(rle_decode(b"\x10", 8, 8, 8) is None)
  // A truncated bit-packed group.
  assert_true(rle_decode(b"\x03\x88", 8, 3, 8) is None)
  // A varint header that never terminates.
  let endless : Array[Byte] = Array::make(12, (0xFF).to_byte())
  assert_true(rle_decode(Bytes::from_array(endless), 8, 3, 8) is None)
  // A groups count past the guard.
  let huge : Array[Byte] = []
  push_varint_bytes(huge, (0x1000_0001UL << 1) | 1UL)
  assert_true(rle_decode(Bytes::from_array(huge), 8, 3, 8) is None)
}

// ── the writer's refusals ────────────────────────────────────────────

///|
test "the writer refuses what it cannot spell" {
  // A Null-dtype column cannot be built at all (no Series constructor
  // carries the dtype), so the unmappable-dtype raise guards a future
  // dtype landing without a parquet row — unreachable today, and the
  // mapping's own refusal is pinned directly in the schema test above.
  // What a caller CAN hand the writer: a Date day count past the INT32
  // the annotation rides.
  let far : Array[@series.Series] = [
    @series.Series::from_date_options("d", [Some(9_223_372_036_854_775_807L)]),
  ]
  let far_result = Ok(ignore(write_parquet_bytes(far, ["d"], Uncompressed))) catch {
    e => Err(e)
  }
  assert_true(far_result is Err(@types.DataError::InvalidOperation(_)))
  // And columns of differing lengths: the frame's one height is the
  // count every chunk names, so a disagreement raises LengthMismatch
  // instead of writing a file whose chunks contradict each other.
  let ragged : Array[@series.Series] = [
    @series.Series::from_ints("a", [1, 2]),
    @series.Series::from_ints("b", [1]),
  ]
  let ragged_result = Ok(
    ignore(write_parquet_bytes(ragged, ["a", "b"], Uncompressed)),
  ) catch {
    e => Err(e)
  }
  assert_true(ragged_result is Err(@types.DataError::LengthMismatch(2, 1)))
}

// ── the read path's own refusals ─────────────────────────────────────

///|
test "read_parquet_columns refuses an unsupported codec and encoding" {
  // Hand-write a file whose single column chunk names a codec MoonFrame
  // does not decode (LZO = 3): the footer is hand-built thrift over an
  // empty page, so the refusal comes from the page walk.
  let w = thrift_writer()
  w.i32_field(1, 1)
  // Schema: root + one INT64 column.
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
  w.i64_field(3, 1L)
  // One row group, one chunk, one page with codec 3.
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
  w.i32_field(4, 3)
  // The chunk size covers the page header the walk must parse.
  // (Spelled 64 — wide enough for the header below.)
  w.i64_field(5, 1L)
  w.i64_field(6, 64L)
  w.i64_field(7, 64L)
  w.i64_field(9, 4L)
  w.struct_end()
  w.struct_end()
  w.i64_field(2, 1L)
  w.i64_field(3, 1L)
  w.struct_end()
  w.struct_end()
  w.text_field(6, "MoonFrame-test")
  w.struct_end()
  let footer = w.finish()
  // The page at offset 4: a DATA_PAGE header with sizes naming an empty
  // body, then the footer.
  let pw = thrift_writer()
  pw.i32_field(1, 0)
  pw.i32_field(2, 0)
  pw.i32_field(3, 0)
  pw.struct_field_begin(5)
  pw.i32_field(1, 1)
  pw.i32_field(2, 0)
  pw.i32_field(3, 3)
  pw.i32_field(4, 3)
  pw.struct_end()
  pw.struct_end()
  let page_header = pw.finish()
  let out : Array[Byte] = []
  for b in b"PAR1" {
    out.push(b)
  }
  let page_offset = out.length()
  for b in page_header {
    out.push(b)
  }
  for b in footer {
    out.push(b)
  }
  push_le_i32(out, footer.length())
  for b in b"PAR1" {
    out.push(b)
  }
  ignore(page_offset)
  let result = Ok(ignore(read_parquet_columns(Bytes::from_array(out), None))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::Unsupported(_)))
}
