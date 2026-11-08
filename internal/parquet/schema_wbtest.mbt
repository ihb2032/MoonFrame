// Whitebox pin for the read-side tag mapping: a converted annotation no
// MoonFrame dtype carries refuses the column — the literal-free reading
// twin of `converted_tag` maps only the four annotations the writer spells.

///|
test "schema mapping: an unknown converted tag refuses the column" {
  assert_true(map_from_schema(1, Some(99), None, None, None) is None)
  assert_true(map_from_schema(2, Some(99), None, None, None) is None)
}

///|
test "a schema element whose decimal precision is cut refuses" {
  // Field 8's header as the stream's last byte: the walk enters the
  // precision field and its varint reads nothing. The schema list is
  // handed to the reader positioned at its own list header (the
  // enclosing footer field's header already walked past) — one INT64
  // DECIMAL element, scale 2, the precision header unpayloaded.
  let w = thrift_writer()
  w.field_header(2, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i32_field(1, 2)
  w.i32_field(6, 5)
  w.i32_field(7, 2)
  w.field_header(8, 5)
  let bytes = w.finish()
  let r = thrift_reader(bytes)
  r.pos = 1
  let into : Array[SchemaElem] = []
  assert_true(!schema_read_list(r, into))
  assert_eq(into.length(), 0)
}

///|
test "a FIXED_LEN_BYTE_ARRAY element whose type length is cut refuses" {
  // The same refusal at field 2: the FIXED_LEN_BYTE_ARRAY element's
  // width header as the stream's last byte, its varint unpayloaded.
  let w = thrift_writer()
  w.field_header(2, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i32_field(1, 7)
  w.field_header(2, 5)
  let bytes = w.finish()
  let r = thrift_reader(bytes)
  r.pos = 1
  let into : Array[SchemaElem] = []
  assert_true(!schema_read_list(r, into))
  assert_eq(into.length(), 0)
}
