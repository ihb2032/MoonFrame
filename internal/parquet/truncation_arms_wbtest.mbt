// Whitebox direct truncation arms — the footer walkers and the compact
// primitives fed byte sequences cut at each field, so every `None =>`
// refusal is reached without a whole file around it. The sweeps in the
// malformed-file test cover the same arms end-to-end; these pin them
// one at a time, where a sweep's cut cannot land.

// ── schema element fields ────────────────────────────────────────────

///|
/// The schema list element whose field `id` names a value the buffer
/// ends before: one field header, no payload.
fn header_only(id : Int32, wire : Int32) -> Bytes {
  let w = thrift_writer()
  w.field_header(id, wire)
  w.finish()
}

//|
// The list-prefixed spelling — the walkers that read a struct ELEMENT
// list consume its header before any element field.

///|
fn elem_header_only(id : Int32, wire : Int32) -> Bytes {
  let w = thrift_writer()
  w.list_header(1, 12)
  w.field_header(id, wire)
  w.finish()
}

///|
test "schema element fields refuse on a cut payload" {
  // Field 1 (physical): header, then EOF.
  assert_true(!schema_read_list(thrift_reader(elem_header_only(1, 5)), []))
  // Field 3 (repetition type).
  assert_true(!schema_read_list(thrift_reader(elem_header_only(3, 5)), []))
  // Field 4 (name).
  assert_true(!schema_read_list(thrift_reader(elem_header_only(4, 8)), []))
  // Field 5 (child count).
  assert_true(!schema_read_list(thrift_reader(elem_header_only(5, 5)), []))
  // Field 6 (converted type).
  assert_true(!schema_read_list(thrift_reader(elem_header_only(6, 5)), []))
  // Field 7 (decimal scale).
  assert_true(!schema_read_list(thrift_reader(elem_header_only(7, 5)), []))
  // An unknown field whose skip fails: a binary field cut mid-length.
  assert_true(!schema_read_list(thrift_reader(elem_header_only(9, 8)), []))
  // The element that never ends: a field header, EOF — `done` stays
  // false.
  assert_true(!schema_read_list(thrift_reader(elem_header_only(1, 5)), []))
  // A list header whose element type mismatches (5 = i32, wanted 12).
  let w = thrift_writer()
  w.list_header(1, 5)
  assert_true(!schema_read_list(thrift_reader(w.finish()), []))
  // A long-form list header whose count varint is cut.
  let raw : Array[Byte] = [(0xFC).to_byte()]
  assert_true(!schema_read_list(thrift_reader(Bytes::from_array(raw)), []))
}

// ── row-group and chunk fields ───────────────────────────────────────

///|
test "row-group and chunk readers refuse on cut payloads" {
  // A row-group struct whose columns list header mismatches: the field
  // 1 header opens, the list header names i32 elements.
  let w = thrift_writer()
  w.field_header(1, 9)
  w.list_header(1, 5)
  assert_true(!row_groups_read(thrift_reader(w.finish()), []))
  // The columns list header itself cut after the long-form marker.
  let raw : Array[Byte] = [(0x19).to_byte(), (0xF9).to_byte()]
  assert_true(!row_groups_read(thrift_reader(Bytes::from_array(raw)), []))
  // A chunk list whose ColumnChunk struct is cut: field 3 header, EOF.
  let w2 = thrift_writer()
  w2.field_header(3, 12)
  assert_true(!column_chunks_read(thrift_reader(w2.finish()), []))
  // A ColumnMetaData field cut: field 1 header, EOF.
  let w3 = thrift_writer()
  w3.field_header(1, 5)
  assert_true(!column_meta_read(thrift_reader(w3.finish()), []))
  // Field 3 (path_in_schema) with a mismatched element type.
  let w4 = thrift_writer()
  w4.field_header(3, 9)
  w4.list_header(2, 12)
  assert_true(!column_meta_read(thrift_reader(w4.finish()), []))
  // Field 3 with a nested path (two elements — the flat schema names
  // one).
  let w5 = thrift_writer()
  w5.field_header(3, 9)
  w5.list_header(2, 8)
  w5.text_list_elem("a")
  w5.text_list_elem("b")
  assert_true(!column_meta_read(thrift_reader(w5.finish()), []))
  // The path string itself cut.
  let w6 = thrift_writer()
  w6.field_header(3, 9)
  w6.list_header(1, 8)
  let cut6 : Array[Byte] = []
  for b in w6.finish() {
    cut6.push(b)
  }
  // The list header opens one string element; the bytes end before it.
  assert_true(!column_meta_read(thrift_reader(Bytes::from_array(cut6)), []))
  // Fields 4 / 5 / 7 / 9 / 11 cut mid-value.
  for id in [4, 5, 7, 9, 11] {
    let wire = if id == 4 { 5 } else { 6 }
    assert_true(!column_meta_read(thrift_reader(header_only(id, wire)), []))
  }
  // The struct never ends (the `done` arm).
  assert_true(!column_meta_read(thrift_reader(header_only(1, 5)), []))
}

// ── the thrift primitives' own arms ──────────────────────────────────

///|
test "the compact primitives refuse their cut shapes" {
  // A varint that never terminates.
  let endless : Array[Byte] = Array::make(12, (0xFF).to_byte())
  assert_true(thrift_reader(Bytes::from_array(endless)).varint() is None)
  // A varint whose zigzag decode overflows Int32.
  let wide : Array[Byte] = []
  push_varint_bytes(wide, 0xFFFFFFFFFFFFFFF0UL)
  assert_true(thrift_reader(Bytes::from_array(wide)).zigzag_i32() is None)
  // A binary length past the guard.
  let guarded : Array[Byte] = []
  push_varint_bytes(guarded, 0x2000_0000UL)
  assert_true(thrift_reader(Bytes::from_array(guarded)).binary() is None)
  // A binary length past the buffer.
  let over : Array[Byte] = []
  push_varint_bytes(over, 0x10UL)
  assert_true(thrift_reader(Bytes::from_array(over)).binary() is None)
  // An absolute field id (delta 0) whose zigzag varint is cut: the
  // header byte names delta 0, then EOF.
  assert_true(thrift_reader(b"\x05").field_header(0) is None)
}

// ── the skipper's remaining shapes ───────────────────────────────────

///|
test "the skipper refuses its cut list shapes" {
  // A list whose element type is bool (1): skipping consumes nothing
  // per element, but a count varint cut in the long form refuses.
  let w = thrift_writer()
  w.field_header(1, 9)
  w.list_header(15, 5)
  let bytes = w.finish()
  // The long-form count varint is absent — the header byte names 15.
  let r = thrift_reader(bytes)
  let h = r.field_header(0).unwrap()
  assert_true(!r.skip(h.wire))
  // A list of binaries whose first element's length is cut.
  let w2 = thrift_writer()
  w2.field_header(1, 9)
  w2.list_header(1, 8)
  let bytes2 = w2.finish()
  let r2 = thrift_reader(bytes2)
  let h2 = r2.field_header(0).unwrap()
  assert_true(!r2.skip(h2.wire))
  // A list of i32 whose element varint is cut.
  let w3 = thrift_writer()
  w3.field_header(1, 9)
  w3.list_header(1, 5)
  let bytes3 = w3.finish()
  let r3 = thrift_reader(bytes3)
  let h3 = r3.field_header(0).unwrap()
  assert_true(!r3.skip(h3.wire))
  // A nested struct that ends mid-field.
  let w4 = thrift_writer()
  w4.field_header(1, 12)
  let bytes4 = w4.finish()
  let r4 = thrift_reader(bytes4)
  let h4 = r4.field_header(0).unwrap()
  assert_true(!r4.skip(h4.wire))
  // A list whose element type is a map (13) refuses.
  let w5 = thrift_writer()
  w5.field_header(1, 9)
  w5.list_header(1, 13)
  let bytes5 = w5.finish()
  let r5 = thrift_reader(bytes5)
  let h5 = r5.field_header(0).unwrap()
  assert_true(!r5.skip(h5.wire))
  // A list count past the guard.
  let huge : Array[Byte] = [(0xF9).to_byte()]
  push_varint_bytes(huge, 0x2000_0001UL)
  let r6 = thrift_reader(Bytes::from_array(huge))
  // The first byte is the list header (elem 9); the varint overflows.
  assert_true(!r6.skip(ListV))
}

///|
test "the skipper walks bool and nested-list elements and cut counts" {
  // A list of bool elements: header (2<<4)|1, elements consume nothing
  // (the value rides the wire type), then the enclosing struct's stop.
  let bools : Array[Byte] = [
    (0x19).to_byte(),
    (0x21).to_byte(),
    (0x00).to_byte(),
  ]
  let r1 = thrift_reader(Bytes::from_array(bools))
  let h1 = r1.field_header(0).unwrap()
  assert_true(r1.skip(h1.wire))
  // A list of one list: outer header (1<<4)|9, inner header (1<<4)|5,
  // one i32 element, stop.
  let nested : Array[Byte] = [
    (0x19).to_byte(),
    (0x19).to_byte(),
    (0x15).to_byte(),
    (0x02).to_byte(),
    (0x00).to_byte(),
  ]
  let r2 = thrift_reader(Bytes::from_array(nested))
  let h2 = r2.field_header(0).unwrap()
  assert_true(r2.skip(h2.wire))
  // A long-form list count (size nibble 15) whose varint is cut.
  let cut : Array[Byte] = [(0xF5).to_byte()]
  assert_true(!thrift_reader(Bytes::from_array(cut)).skip(ListV))
}
