// Whitebox tests of the Avro codec's own parts: the schema reader's
// refusals, the cursor's bounds, the block codecs' failures, the shapes
// only a hand-built container reaches, and the writer's encoder against
// cells its own types never meet. The cells a reference implementation
// writes are the blackbox tests' business; these pin the arms around them.

///|
fn parse_error(text : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("malformed Avro: \{text}"),
  )
}

///|
fn unsupported(text : String) -> @types.DataError {
  @types.DataError::Unsupported("Avro: \{text}")
}

///|
fn invalid(text : String) -> @types.DataError {
  @types.DataError::InvalidOperation(text)
}

///|
/// A file header holding `schema` under `codec`: the magic, the two
/// metadata entries, and the marker.
fn header_of(schema : String, codec : String) -> Bytes {
  let out : Array[Byte] = []
  for b in b"Obj\x01" {
    out.push(b)
  }
  push_long(out, 2L)
  push_string(out, "avro.schema")
  push_string(out, schema)
  push_string(out, "avro.codec")
  push_string(out, codec)
  push_long(out, 0L)
  for b in sync_marker(schema) {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A block of `count` records over `body`, closed by `marker`.
fn block_of(count : Int64, body : Bytes, marker : Bytes) -> Bytes {
  let out : Array[Byte] = []
  push_long(out, count)
  push_long(out, body.length().to_int64())
  for b in body {
    out.push(b)
  }
  for b in marker {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn joined(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// One file under the null codec: the header, and one block of `count`
/// records over `body`, closed by the header's own marker.
fn file_of(schema : String, count : Int64, body : Bytes) -> Bytes {
  joined([header_of(schema, "null"), block_of(count, body, sync_marker(schema))])
}

///|
/// A record schema over `fields`: the text between the brackets when it
/// is given bracketed, or one field's own text.
fn record_of(fields : String) -> String {
  let list = if fields.has_prefix("[") { fields } else { "[\{fields}]" }
  "{\"type\":\"record\",\"name\":\"R\",\"fields\":\{list}}"
}

///|
/// The refusal a read raised, failing the test when it read.
fn read_refusal(bytes : Bytes) -> @types.DataError raise {
  let read : Result[(Array[(String, @series.Series)], Int32), @types.DataError] = Ok(
    read_avro_frame(bytes, None),
  ) catch {
    e => Err(e)
  }
  match read {
    Ok(_) => fail("the read was expected to refuse")
    Err(e) => e
  }
}

///|
/// A cursor over bytes built by `build`.
fn cursor(build : (Array[Byte]) -> Unit) -> Cursor {
  let out : Array[Byte] = []
  build(out)
  Cursor::{ bytes: Bytes::from_array(out), at: 0, }
}

///|
/// The schema one JSON text reads as.
fn schema_of(text : String) -> AvroType raise {
  let json = @json.parse(text.clamped_view()) catch {
    _ => fail("the schema text is not JSON")
  }
  let reader = SchemaReader::{ names: Map([]), defining: [], }
  reader.read(json, 0)
}

///|
/// The refusal a schema text raised, failing the test when it read.
fn schema_refusal(text : String) -> @types.DataError raise {
  let json = @json.parse(text.clamped_view()) catch {
    _ => fail("the schema text is not JSON")
  }
  let reader = SchemaReader::{ names: Map([]), defining: [], }
  let read : Result[AvroType, @types.DataError] = Ok(reader.read(json, 0)) catch {
    e => Err(e)
  }
  match read {
    Ok(_) => fail("the schema was expected to refuse")
    Err(e) => e
  }
}

///|
/// The type of the field `name` of a record schema text.
fn field_type(schema : String, name : String) -> AvroType raise {
  match schema_of(schema) {
    TRecord(fields) => {
      for field in fields {
        if field.name == name {
          return field.ty
        }
      }
      fail("no field named \{name}")
    }
    _ => fail("not a record")
  }
}

///|
/// The bytes a list of bytes spells.
fn spelling(array : Array[Byte]) -> Bytes {
  Bytes::from_array(array)
}

///|
test "the schema reader refuses a schema that does not hold together" {
  let cases : ReadOnlyArray[(String, String)] = [
    (
      "5", "a schema entry that is neither a name, a union, or a type definition",
    ),
    ("{\"name\":\"x\"}", "a type definition with no \"type\""),
    (
      "{\"type\":\"Missing\"}", "a schema refers to the type \"Missing\", which it never defines",
    ),
    ("{\"type\":\"array\"}", "an array with no \"items\""),
    ("{\"type\":\"map\"}", "a map with no \"values\""),
    ("{\"type\":\"int\",\"logicalType\":5}", "a logicalType that is not a name"),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\"}", "a decimal with no precision",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":0}", "a decimal with precision 0, outside 1 to 38",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":39}", "a decimal with precision 39, outside 1 to 38",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":2,\"scale\":3}",
      "a decimal with scale 3, outside 0 to its precision",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":2,\"scale\":-1}",
      "a decimal with scale -1, outside 0 to its precision",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":1.5}", "a decimal's precision that is not a 32-bit whole number",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":\"ten\"}", "a decimal's precision that is not a number",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":10,\"scale\":1.5}",
      "a decimal's scale that is not a 32-bit whole number",
    ),
    (
      "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":10,\"scale\":[]}",
      "a decimal's scale that is not a number",
    ),
    (
      "{\"type\":\"record\",\"name\":5,\"fields\":[]}", "a type definition whose \"name\" is not a string",
    ),
    (
      "{\"type\":\"record\",\"name\":\"R\",\"namespace\":5,\"fields\":[]}", "a type definition whose namespace is not a string",
    ),
    (
      "{\"type\":\"record\",\"name\":\"R\",\"fields\":5}", "the record \"R\" whose fields are not an array",
    ),
    ("{\"type\":\"record\",\"name\":\"R\"}", "the record \"R\" with no fields"),
    (
      "{\"type\":\"record\",\"name\":\"R\",\"fields\":[{\"name\":\"a\"}]}", "the field \"a\" of \"R\" with no type",
    ),
    (
      "{\"type\":\"record\",\"name\":\"R\",\"fields\":[{\"name\":\"a\",\"type\":\"int\"},{\"name\":\"a\",\"type\":\"int\"}]}",
      "the record \"R\" with two fields named \"a\"",
    ),
    (
      "{\"type\":\"record\",\"name\":\"R\",\"fields\":[5]}", "a field of \"R\" that is not an object",
    ),
    (
      "{\"type\":\"enum\",\"name\":\"E\",\"symbols\":5}", "the enum \"E\" whose symbols are not an array",
    ),
    ("{\"type\":\"enum\",\"name\":\"E\"}", "the enum \"E\" with no symbols"),
    (
      "{\"type\":\"enum\",\"name\":\"E\",\"symbols\":[\"a\",\"a\"]}", "the enum \"E\" with the symbol \"a\" twice",
    ),
    (
      "{\"type\":\"enum\",\"name\":\"E\",\"symbols\":[5]}", "a symbol of \"E\" that is not a string",
    ),
    (
      "{\"type\":\"enum\",\"name\":\"E\",\"symbols\":[]}", "the enum \"E\" with no symbol",
    ),
    ("{\"type\":\"fixed\",\"name\":\"F\"}", "the fixed type \"F\" with no size"),
    (
      "{\"type\":\"fixed\",\"name\":\"F\",\"size\":0}", "the fixed type \"F\" with size 0",
    ),
    (
      "{\"type\":\"fixed\",\"name\":\"F\",\"size\":0.5}", "the size of a fixed type that is not a 32-bit whole number",
    ),
  ]
  for (text, message) in cases {
    assert_eq(schema_refusal(text), parse_error(message))
  }
  // Nested past the bound: sixty-five unions around an int.
  let opens = "[".repeat(65)
  let closes = "]".repeat(65)
  let deep = "\{opens}\"int\"\{closes}"
  assert_eq(
    schema_refusal(deep),
    parse_error("a schema nested deeper than 64 types"),
  )
}

///|
test "the schema reader refuses a type that contains itself" {
  let direct = record_of("[{\"name\":\"next\",\"type\":[\"null\",\"R\"]}]")
  assert_eq(
    schema_refusal(direct),
    unsupported("a schema whose type \"R\" contains itself"),
  )
  // By its short name, under a namespace, and through a list.
  let namespaced = record_of(
    "[{\"name\":\"R\",\"type\":{\"type\":\"record\",\"name\":\"R\",\"namespace\":\"ns\",\"fields\":[{\"name\":\"more\",\"type\":{\"type\":\"array\",\"items\":\"R\"}}]}}]",
  )
  assert_eq(
    schema_refusal(namespaced),
    unsupported("a schema whose type \"R\" contains itself"),
  )
  // By its full name.
  let full = record_of(
    "[{\"name\":\"R\",\"type\":{\"type\":\"record\",\"name\":\"R\",\"namespace\":\"ns\",\"fields\":[{\"name\":\"more\",\"type\":\"ns.R\"}]}}]",
  )
  assert_eq(
    schema_refusal(full),
    unsupported("a schema whose type \"ns.R\" contains itself"),
  )
}

///|
test "the schema reader keeps what a column reads" {
  // A named type is kept under its full name and its own.
  let named = record_of(
    "[{\"name\":\"c\",\"type\":[\"null\",{\"type\":\"record\",\"name\":\"Color\",\"namespace\":\"ns\",\"fields\":[{\"name\":\"r\",\"type\":\"int\"}]}]},{\"name\":\"d\",\"type\":[\"null\",\"Color\"]},{\"name\":\"e\",\"type\":[\"null\",\"ns.Color\"]}]",
  )
  for name in ["d", "e"] {
    assert_true(field_type(named, name) is TUnion(_))
    assert_true(
      cell_type(field_type(named, name), name).1 is @types.DataType::Struct(_),
    )
  }
  // A record's name carrying dots is its full name already: the
  // namespace beside it does not apply.
  let dotted = "{\"type\":\"record\",\"name\":\"a.R\",\"namespace\":\"ns\",\"fields\":[{\"name\":\"x\",\"type\":\"int\"}]}"
  assert_true(field_type(dotted, "x") is TInt(Plain))
  // A field's type given as a union, and as a nested definition the
  // outer attributes annotate.
  let shaped = record_of(
    "[{\"name\":\"u\",\"type\":[\"null\",\"int\"]},{\"name\":\"d\",\"type\":{\"type\":\"int\",\"logicalType\":\"date\"}}]",
  )
  assert_true(field_type(shaped, "u") is TUnion(_))
  assert_true(field_type(shaped, "d") is TInt(Date))
  // Every logical type a long carries, and one it does not know.
  let longs = record_of(
    "[{\"name\":\"a\",\"type\":{\"type\":\"long\",\"logicalType\":\"bogus\"}},{\"name\":\"b\",\"type\":{\"type\":\"long\",\"logicalType\":\"time-micros\"}},{\"name\":\"c\",\"type\":{\"type\":\"long\",\"logicalType\":\"timestamp-millis\"}},{\"name\":\"e\",\"type\":{\"type\":\"long\",\"logicalType\":\"timestamp-micros\"}},{\"name\":\"f\",\"type\":{\"type\":\"long\",\"logicalType\":\"local-timestamp-millis\"}},{\"name\":\"g\",\"type\":{\"type\":\"long\",\"logicalType\":\"local-timestamp-micros\"}},{\"name\":\"h\",\"type\":{\"type\":\"long\",\"logicalType\":\"timestamp-nanos\"}},{\"name\":\"i\",\"type\":{\"type\":\"long\",\"logicalType\":\"time-nanos\"}}]",
  )
  assert_true(field_type(longs, "a") is TLong(Plain))
  assert_true(field_type(longs, "b") is TLong(TimeMicros))
  assert_true(field_type(longs, "c") is TLong(TimestampMillis))
  assert_true(field_type(longs, "e") is TLong(TimestampMicros))
  assert_true(field_type(longs, "f") is TLong(TimestampMillis))
  assert_true(field_type(longs, "g") is TLong(TimestampMicros))
  assert_true(field_type(longs, "h") is TLong(Nanos))
  assert_true(field_type(longs, "i") is TLong(Nanos))
  // A decimal without a scale has none; an int's logical types; a
  // string's; a fixed type's; a bytes field under a logical type the
  // format does not define for it.
  let others = record_of(
    "[{\"name\":\"a\",\"type\":{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":10}},{\"name\":\"b\",\"type\":{\"type\":\"int\",\"logicalType\":\"time-millis\"}},{\"name\":\"c\",\"type\":{\"type\":\"string\",\"logicalType\":\"uuid\"}},{\"name\":\"d\",\"type\":{\"type\":\"fixed\",\"name\":\"F\",\"size\":3}},{\"name\":\"e\",\"type\":{\"type\":\"fixed\",\"name\":\"G\",\"size\":3,\"logicalType\":\"duration\"}},{\"name\":\"f\",\"type\":{\"type\":\"fixed\",\"name\":\"H\",\"size\":3,\"logicalType\":\"decimal\",\"precision\":3,\"scale\":1}},{\"name\":\"g\",\"type\":{\"type\":\"bytes\",\"logicalType\":\"uuid\"}},{\"name\":\"h\",\"type\":{\"type\":\"int\",\"logicalType\":\"date\"}},{\"name\":\"i\",\"type\":{\"type\":\"int\",\"logicalType\":\"bogus\"}}]",
  )
  assert_true(field_type(others, "a") is TBytes(Some(_)))
  assert_true(field_type(others, "b") is TInt(TimeMillis))
  assert_true(field_type(others, "c") is TString)
  assert_true(field_type(others, "d") is TFixed(3, Plain))
  assert_true(field_type(others, "e") is TFixed(3, Duration))
  assert_true(field_type(others, "f") is TFixed(3, Decimal(_)))
  assert_true(field_type(others, "g") is TBytes(None))
  assert_true(field_type(others, "h") is TInt(Date))
  assert_true(field_type(others, "i") is TInt(Plain))
  // A definition whose type is a definition of its own, annotated from
  // outside it; and a fixed type under a logical type the format does
  // not define for it.
  let wrapped = record_of(
    "[{\"name\":\"j\",\"type\":{\"type\":{\"type\":\"int\"},\"logicalType\":\"date\"}},{\"name\":\"k\",\"type\":{\"type\":\"fixed\",\"name\":\"K\",\"size\":3,\"logicalType\":\"bogus\"}}]",
  )
  assert_true(field_type(wrapped, "j") is TInt(Date))
  assert_true(field_type(wrapped, "k") is TFixed(3, Plain))
  // Arrays and maps of every kind.
  let collections = record_of(
    "[{\"name\":\"a\",\"type\":{\"type\":\"array\",\"items\":\"int\"}},{\"name\":\"m\",\"type\":{\"type\":\"map\",\"values\":\"long\"}}]",
  )
  assert_true(field_type(collections, "a") is TArray(_))
  assert_true(field_type(collections, "m") is TMap(_))
  if field_type(collections, "a") is TArray(items) {
    assert_true(items is TInt(Plain))
  } else {
    fail("the array's items are lost")
  }
}

///|
test "the cursor refuses to walk past its block" {
  let past = cursor(out => push_long(out, 300L))
  assert_eq(past.long(), 300L)
  let end = cursor(out => out.push(b'a'))
  let outcome : Result[Bytes, @types.DataError] = Ok(end.take(2)) catch {
    e => Err(e)
  }
  assert_eq(outcome, Err(parse_error("a block ends inside a value")))
  let wide = cursor(out => {
    for _ in 0..<9 {
      out.push(b'\x80')
    }
    out.push(b'\x02')
  })
  let wide_outcome : Result[UInt64, @types.DataError] = Ok(wide.varint()) catch {
    e => Err(e)
  }
  assert_eq(
    wide_outcome,
    Err(parse_error("a variable-length integer wider than 64 bits")),
  )
  // The widest count: ten bytes, the last carrying the sixty-third bit —
  // the least count a long holds, whose zigzag spelling is every bit set.
  let least = cursor(out => push_long(out, -9223372036854775808L))
  assert_eq(least.varint(), 0xFFFF_FFFF_FFFF_FFFFUL)
  assert_eq(
    cursor(out => push_long(out, -9223372036854775808L)).long(),
    -9223372036854775808L,
  )
  assert_eq(cursor(out => push_long(out, 300L)).long(), 300L)
  // An int past 32 bits, a length past the block, a negative length.
  let big = cursor(out => push_long(out, 1099511627776L))
  let big_outcome : Result[Int32, @types.DataError] = Ok(big.int()) catch {
    e => Err(e)
  }
  assert_eq(big_outcome, Err(parse_error("an int encoded outside 32 bits")))
  let negative = cursor(out => push_long(out, -1L))
  let negative_outcome : Result[Int32, @types.DataError] = Ok(negative.length()) catch {
    e => Err(e)
  }
  assert_eq(
    negative_outcome,
    Err(parse_error("a length of -1 bytes that the block cannot hold")),
  )
  let long_length = cursor(out => {
    push_long(out, 99L)
    out.push(b'\x00')
  })
  let long_outcome : Result[Int32, @types.DataError] = Ok(long_length.length()) catch {
    e => Err(e)
  }
  assert_eq(
    long_outcome,
    Err(parse_error("a length of 99 bytes that the block cannot hold")),
  )
  // A collection block's count.
  let least = cursor(out => push_long(out, -9223372036854775808L))
  let least_outcome : Result[Int64, @types.DataError] = Ok(least.block_count()) catch {
    e => Err(e)
  }
  assert_eq(
    least_outcome,
    Err(parse_error("a collection block of -9223372036854775808 items")),
  )
  let sized = cursor(out => {
    push_long(out, -2L)
    push_long(out, 64L)
    out.push(b'\x00')
  })
  assert_eq(sized.block_count(), 2L)
  assert_eq(sized.at, 3)
  // The item budget.
  let budget = Budget::{ items: MAX_ITEMS, }
  let over : Result[Unit, @types.DataError] = Ok(budget.charge(1L)) catch {
    e => Err(e)
  }
  assert_eq(
    over,
    Err(parse_error("more than \{MAX_ITEMS} collection items in one file")),
  )
  // A string that is not UTF-8.
  let bad_text = cursor(out => {
    push_long(out, 1L)
    out.push(b'\xFF')
  })
  let text : Result[@types.Scalar, @types.DataError] = Ok(
    decode_value(bad_text, CString, Budget::{ items: 0L, }, "s"),
  ) catch {
    e => Err(e)
  }
  assert_eq(text, Err(parse_error("a string that is not valid UTF-8")))
}

///|
test "the block codecs refuse what does not decompress, and check what does" {
  let deflate : Result[Bytes, @types.DataError] = Ok(
    inflate(Deflate, b"garbage"),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    deflate,
    Err(
      parse_error(
        "a deflate block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
      ),
    ),
  )
  let short : Result[Bytes, @types.DataError] = Ok(inflate(Snappy, b"\x01\x02")) catch {
    e => Err(e)
  }
  assert_eq(short, Err(parse_error("a snappy block shorter than its checksum")))
  let broken : Result[Bytes, @types.DataError] = Ok(
    inflate(Snappy, b"\x05\x00\x00\x00\x00"),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    broken,
    Err(
      parse_error(
        "a snappy block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
      ),
    ),
  )
  let stale : Result[Bytes, @types.DataError] = Ok(
    inflate(Snappy, with_checksum(@snappy.compress_raw(b"abc"), b"abd")),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    stale,
    Err(parse_error("a snappy block whose checksum does not match its bytes")),
  )
  let zstandard : Result[Bytes, @types.DataError] = Ok(
    inflate(Zstd, b"garbage"),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    zstandard,
    Err(
      parse_error(
        "a zstandard block that does not decompress within \{MAX_BLOCK_BYTES} bytes",
      ),
    ),
  )
  // What does decompress, under every codec, is what was compressed.
  let body = Bytes::makei(100000, i => if i % 97 == 0 { b'z' } else { b'a' })
  for codec in [Codec::Null, Codec::Deflate, Codec::Snappy, Codec::Zstd] {
    assert_eq(inflate(codec, compress(codec, body)), body)
  }
  // The checksum is the standard CRC-32's.
  assert_eq(crc32(b"123456789"), 0xCBF43926U)
  assert_eq(be32(b"\x01\x02\x03\x04", 0), 0x01020304U)
  assert_false(same_bytes(b"ab", b"abc"))
  assert_false(same_bytes(b"ab", b"ba"))
  assert_true(same_bytes(b"ab", b"ab"))
}

///|
test "a codec's two names" {
  assert_eq(codec_named("null"), Codec::Null)
  assert_eq(codec_named("deflate"), Codec::Deflate)
  assert_eq(codec_named("snappy"), Codec::Snappy)
  assert_eq(codec_named("zstandard"), Codec::Zstd)
  let unknown : Result[Codec, @types.DataError] = Ok(codec_named("lz4")) catch {
    e => Err(e)
  }
  assert_eq(unknown, Err(unsupported("a block codec named \"lz4\"")))
  assert_eq(
    [
      Codec::Null.name(),
      Codec::Deflate.name(),
      Codec::Snappy.name(),
      Codec::Zstd.name(),
    ],
    ["null", "deflate", "snappy", "zstandard"],
  )
}

///|
test "a hand-built container reaches the shapes no reference file holds" {
  // A field typed null alone reads as an all-null column.
  let nulls = record_of(
    "[{\"name\":\"n\",\"type\":\"null\"},{\"name\":\"k\",\"type\":\"int\"}]",
  )
  let (frame, records) = read_avro_frame(
    file_of(
      nulls,
      2L,
      joined([
        cursor(out => push_long(out, 4L)).bytes,
        cursor(out => push_long(out, 5L)).bytes,
      ]),
    ),
    None,
  )
  assert_eq(records, 2)
  assert_eq(frame.length(), 2)
  assert_eq(frame[0].1.to_scalars(), [@types.Scalar::Null, @types.Scalar::Null])
  assert_eq(frame[0].1.dtype(), @types.DataType::String)
  assert_eq(frame[1].1.to_scalars(), [
    @types.Scalar::Int(4L),
    @types.Scalar::Int(5L),
  ])
  // The union with its value first, and a union of one branch.
  let unions = record_of(
    "[{\"name\":\"v\",\"type\":[\"int\",\"null\"]},{\"name\":\"s\",\"type\":[\"int\"]}]",
  )
  let body = cursor(out => {
      push_long(out, 0L)
      push_long(out, 9L)
      push_long(out, 7L)
      push_long(out, 1L)
      push_long(out, 8L)
    }).bytes
  let (union_frame, _) = read_avro_frame(file_of(unions, 2L, body), None)
  assert_eq(union_frame[0].1.to_scalars(), [
    @types.Scalar::Int(9L),
    @types.Scalar::Null,
  ])
  assert_eq(union_frame[1].1.to_scalars(), [
    @types.Scalar::Int(7L),
    @types.Scalar::Int(8L),
  ])
  // Indexes outside their branches and symbols.
  assert_eq(
    read_refusal(
      file_of(
        record_of("[{\"name\":\"u\",\"type\":[\"null\",\"int\"]}]"),
        1L,
        cursor(out => {
          push_long(out, 7L)
          push_long(out, 0L)
        }).bytes,
      ),
    ),
    parse_error("a union index 7 outside its branches at \"u\""),
  )
  assert_eq(
    read_refusal(
      file_of(
        record_of(
          "[{\"name\":\"e\",\"type\":{\"type\":\"enum\",\"name\":\"E\",\"symbols\":[\"a\",\"b\"]}}]",
        ),
        1L,
        cursor(out => push_long(out, 10L)).bytes,
      ),
    ),
    parse_error("an enum index outside its symbols at \"e\""),
  )
  // A top-level schema that is not a record.
  for schema in ["\"int\"", "[\"null\",\"int\"]"] {
    assert_eq(
      read_refusal(file_of(schema, 0L, b"")),
      unsupported("a file whose top-level schema is not a record"),
    )
  }
  // The framing: a block of no record, a size past the file, a marker
  // that differs, bytes past the last record, a header that ends inside
  // its marker, bytes that are not the magic, and metadata past the
  // bound.
  let schema = record_of("[{\"name\":\"k\",\"type\":\"int\"}]")
  assert_eq(
    read_refusal(file_of(schema, 0L, b"")),
    parse_error("a block of 0 records"),
  )
  let marker = sync_marker(schema)
  let whole = block_of(1L, b"\x08", marker)
  assert_eq(
    read_refusal(
      joined([
        header_of(schema, "null"),
        whole.exact_view(end=whole.length() - 8).to_owned(),
      ]),
    ),
    parse_error("a block of 1 bytes, past what the file holds"),
  )
  let other = Bytes::make(16, b'\x5A')
  assert_eq(
    read_refusal(
      joined([header_of(schema, "null"), block_of(1L, b"\x08", other)]),
    ),
    parse_error("a block whose sync marker differs from the file's"),
  )
  assert_eq(
    read_refusal(file_of(schema, 1L, b"\x08\x00")),
    parse_error("a block carrying bytes past its last record"),
  )
  let header = header_of(schema, "null")
  assert_eq(
    read_refusal(header.exact_view(end=header.length() - 5).to_owned()),
    parse_error("a file that ends inside its sync marker"),
  )
  assert_eq(
    read_refusal(b"Nope\x00\x00"),
    parse_error("bytes that do not open with the Avro magic"),
  )
  // Metadata: a third key is ignored, the codec is optional, a block
  // with a byte size is read, and too many entries refuse.
  let extra = cursor(out => {
      for b in b"Obj\x01" {
        out.push(b)
      }
      push_long(out, 3L)
      push_string(out, "avro.schema")
      push_string(out, schema)
      push_string(out, "x-custom")
      push_string(out, "ignored")
      push_string(out, "avro.codec")
      push_string(out, "null")
      push_long(out, 0L)
      for b in marker {
        out.push(b)
      }
    }).bytes
  assert_eq(read_avro_frame(joined([extra, whole]), None).1, 1)
  let defaulted = cursor(out => {
      for b in b"Obj\x01" {
        out.push(b)
      }
      push_long(out, -1L)
      let entries = cursor(inner => {
          push_string(inner, "avro.schema")
          push_string(inner, schema)
        }).bytes
      push_long(out, entries.length().to_int64())
      for b in entries {
        out.push(b)
      }
      push_long(out, 0L)
      for b in marker {
        out.push(b)
      }
    }).bytes
  assert_eq(read_avro_frame(joined([defaulted, whole]), None).1, 1)
  let many = cursor(out => {
      for b in b"Obj\x01" {
        out.push(b)
      }
      push_long(out, MAX_METADATA + 1L)
      for i in 0..<1025 {
        push_string(out, "key\{i}")
        push_string(out, "value")
      }
      push_long(out, 0L)
      for b in marker {
        out.push(b)
      }
    }).bytes
  assert_eq(
    read_refusal(many),
    parse_error("more than \{MAX_METADATA} metadata entries"),
  )
  // A schema that is not JSON.
  assert_eq(
    read_refusal(file_of("{", 0L, b"")),
    parse_error("a schema that is not valid JSON"),
  )
}

///|
test "a value outside what its logical type holds refuses" {
  // A time past midnight's day, in either unit.
  let times = record_of(
    "[{\"name\":\"a\",\"type\":[\"null\",{\"type\":\"int\",\"logicalType\":\"time-millis\"}]},{\"name\":\"b\",\"type\":[\"null\",{\"type\":\"long\",\"logicalType\":\"time-micros\"}]}]",
  )
  let millis = cursor(out => {
      push_long(out, 1L)
      push_long(out, 90000000L)
      push_long(out, 0L)
    }).bytes
  assert_eq(
    read_refusal(file_of(times, 1L, millis)),
    parse_error("a time-millis of 90000000 ms at \"a\", outside one day"),
  )
  let micros = cursor(out => {
      push_long(out, 0L)
      push_long(out, 1L)
      push_long(out, 90000000000L)
    }).bytes
  assert_eq(
    read_refusal(file_of(times, 1L, micros)),
    parse_error("a time-micros of 90000000000 µs at \"b\", outside one day"),
  )
  // A timestamp in milliseconds past what microseconds hold.
  let stamped = record_of(
    "[{\"name\":\"t\",\"type\":[\"null\",{\"type\":\"long\",\"logicalType\":\"timestamp-millis\"}]}]",
  )
  assert_eq(
    read_refusal(
      file_of(
        stamped,
        1L,
        cursor(out => {
          push_long(out, 1L)
          push_long(out, 9223372036855L)
        }).bytes,
      ),
    ),
    parse_error(
      "a timestamp-millis of 9223372036855 ms at \"t\", outside the timestamps the library holds",
    ),
  )
  // An int encoded outside 32 bits.
  assert_eq(
    read_refusal(
      file_of(
        record_of("[{\"name\":\"i\",\"type\":\"int\"}]"),
        1L,
        cursor(out => push_long(out, 1099511627776L)).bytes,
      ),
    ),
    parse_error("an int encoded outside 32 bits"),
  )
  // Decimals: wider than 128 bits, past 34 significant digits, and
  // read through the high half, under a negative sign with a zero low
  // half, and of no byte at all.
  let decimal = record_of(
    "[{\"name\":\"d\",\"type\":[\"null\",{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":38,\"scale\":0}]}]",
  )
  let wide = cursor(out => {
      push_long(out, 1L)
      push_long(out, 17L)
      for _ in 0..<17 {
        out.push(b'\x01')
      }
    }).bytes
  assert_eq(
    read_refusal(file_of(decimal, 1L, wide)),
    unsupported(
      "a decimal cell 17 bytes wide at \"d\", past the 16 a 128-bit integer holds",
    ),
  )
  let dense = cursor(out => {
      push_long(out, 1L)
      push_long(out, 16L)
      for _ in 0..<16 {
        out.push(b'\x7F')
      }
    }).bytes
  assert_eq(
    read_refusal(file_of(decimal, 1L, dense)),
    unsupported("a decimal cell at \"d\" with more than 34 significant digits"),
  )
  let cells = cursor(out => {
      push_long(out, 1L)
      push_long(out, 9L)
      out.push(b'\x01')
      for _ in 0..<8 {
        out.push(b'\x00')
      }
      push_long(out, 1L)
      push_long(out, 9L)
      out.push(b'\xFF')
      for _ in 0..<8 {
        out.push(b'\x00')
      }
      push_long(out, 1L)
      push_long(out, 0L)
    }).bytes
  let (decimals, _) = read_avro_frame(file_of(decimal, 3L, cells), None)
  assert_eq(decimals[0].1.to_scalars()[0].to_string(), "18446744073709551616")
  assert_eq(decimals[0].1.to_scalars()[1].to_string(), "-18446744073709551616")
  assert_eq(decimals[0].1.to_scalars()[2].to_string(), "0")
}

///|
test "a shape the mapping does not carry refuses by its path" {
  let fixed = record_of(
    "[{\"name\":\"f\",\"type\":[\"null\",{\"type\":\"fixed\",\"name\":\"F\",\"size\":2}]}]",
  )
  assert_eq(
    read_refusal(file_of(fixed, 0L, b"")),
    unsupported("a fixed field \"f\": the mapping has no binary column"),
  )
  let nested_bytes = record_of(
    "[{\"name\":\"l\",\"type\":[\"null\",{\"type\":\"array\",\"items\":\"bytes\"}]}]",
  )
  assert_eq(
    read_refusal(file_of(nested_bytes, 0L, b"")),
    unsupported("a bytes field \"l\": the mapping has no binary column"),
  )
  let maps = record_of(
    "[{\"name\":\"m\",\"type\":[\"null\",{\"type\":\"array\",\"items\":{\"type\":\"map\",\"values\":\"long\"}}]}]",
  )
  assert_eq(
    read_refusal(file_of(maps, 0L, b"")),
    unsupported("a map field \"m\": the mapping has no map column"),
  )
  let record_union = record_of(
    "[{\"name\":\"r\",\"type\":[\"null\",{\"type\":\"record\",\"name\":\"In\",\"fields\":[{\"name\":\"x\",\"type\":[\"null\",\"int\",\"string\"]}]}]}]",
  )
  assert_eq(
    read_refusal(file_of(record_union, 0L, b"")),
    unsupported(
      "a union field \"r.x\" of 3 branches: a column carries a null and one type",
    ),
  )
  let none = record_of(
    "[{\"name\":\"r\",\"type\":[\"null\",{\"type\":\"record\",\"name\":\"In\",\"fields\":[]}]}]",
  )
  assert_eq(
    read_refusal(file_of(none, 0L, b"")),
    unsupported("a record field \"r\" with no field"),
  )
  // A collection that claims more items than a file may hold.
  let arrays = record_of(
    "[{\"name\":\"a\",\"type\":[\"null\",{\"type\":\"array\",\"items\":\"null\"}]}]",
  )
  assert_eq(
    read_refusal(
      file_of(
        arrays,
        1L,
        cursor(out => {
          push_long(out, 1L)
          push_long(out, MAX_ITEMS + 1L)
        }).bytes,
      ),
    ),
    parse_error("more than \{MAX_ITEMS} collection items in one file"),
  )
  // A union index outside its branches is refused when the field is
  // stepped over too.
  let skipped = cursor(out => {
    push_long(out, 5L)
    push_long(out, 0L)
  })
  let skip : Result[Unit, @types.DataError] = Ok(
    skip_value(skipped, TUnion([TNull]), Budget::{ items: 0L, }),
  ) catch {
    e => Err(e)
  }
  assert_eq(skip, Err(parse_error("a union index outside its branches")))
  // Every other type is stepped over to its end — a null, and a record
  // of no field, by no byte at all.
  let walk = cursor(out => {
    out.push(b'\x01') // boolean
    push_long(out, 1L) // int
    push_long(out, 2L) // long
    for _ in 0..<4 {
      out.push(b'\x00') // float
    }
    for _ in 0..<8 {
      out.push(b'\x00') // double
    }
    push_long(out, 1L) // string
    out.push(b'x')
    push_long(out, 1L) // bytes
    out.push(b'y')
    push_long(out, 0L) // enum
    push_long(out, 1L) // array: one
    push_long(out, 0L) //   closed
    push_long(out, 1L) // map: one entry
    push_long(out, 1L) //   key
    out.push(b'k')
    push_long(out, 3L) //   value, an int
    push_long(out, 0L) //   closed
    out.push(b'\x07') // fixed, three bytes
    out.push(b'\x07')
    out.push(b'\x07')
  })
  let budget = Budget::{ items: 0L, }
  for
    ty in [
      TNull,
      TBoolean,
      TInt(Plain),
      TLong(Plain),
      TFloat,
      TDouble,
      TString,
      TBytes(None),
      TEnum(["a"]),
      TArray(TNull),
      TMap(TInt(Plain)),
      TFixed(3, Plain),
      TRecord([]),
    ] {
    skip_value(walk, ty, budget)
  }
  assert_eq(walk.remaining(), 0)
}

///|
test "the writer's encoder meets only cells its own types hold" {
  let buf : Array[Byte] = []
  encode_value(buf, @types.Scalar::Null, CNull, "x")
  assert_eq(buf.length(), 0)
  let shape = DecimalShape::{ precision: 3, scale: 1, }
  // A cell under a column whose type cannot hold it.
  let mismatches : ReadOnlyArray[(@types.Scalar, CellType, String)] = [
    (@types.Scalar::Int(1L), CNull, "null"),
    (@types.Scalar::Int(1L), CIntDate, "date"),
    (@types.Scalar::Int(1L), CLongTimestampMicros, "timestamp"),
    (@types.Scalar::Int(1L), CDecimalBytes(shape), "decimal"),
    (@types.Scalar::Int(1L), CRecord([]), "struct"),
    (@types.Scalar::Int(1L), CArray(CLongPlain), "list"),
  ]
  for (scalar, ty, column) in mismatches {
    let refused : Result[Unit, @types.DataError] = Ok(
      encode_value([], scalar, ty, "x"),
    ) catch {
      e => Err(e)
    }
    assert_eq(
      refused,
      Err(
        invalid(
          "the Avro writer met a Int cell under a \{column} column at \"x\"",
        ),
      ),
    )
  }
  // Types only the reader carries.
  for
    ty in [
      CIntPlain,
      CIntTimeMillis,
      CLongTimeMicros,
      CLongTimestampMillis,
      CFloat,
      CDecimalFixed(4, shape),
      CEnum(["a"]),
    ] {
    let refused : Result[Unit, @types.DataError] = Ok(
      encode_value([], @types.Scalar::Int(1L), ty, "x"),
    ) catch {
      e => Err(e)
    }
    assert_eq(
      refused,
      Err(invalid("the Avro writer does not emit the type of \"x\"")),
    )
  }
  // A decimal with more fraction digits than its column's scale.
  let quarter = @types.Scalar::Decimal(
    @types.Dec128::parse_opt("1.25").unwrap_or(@types.Dec128::nan()),
  )
  let fractional : Result[Unit, @types.DataError] = Ok(
    encode_value([], quarter, CDecimalBytes(shape), "x"),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    fractional,
    Err(
      invalid(
        "column \"x\" holds the decimal 1.25, which is not a whole number of the column's 1 fraction digits or is too wide for a 128-bit integer",
      ),
    ),
  )
  // A decimal past 128 bits under its column's scale.
  let huge = @types.Scalar::Decimal(
    @types.Dec128::of_int64_scale(1L, scale=-37),
  )
  let too_wide : Result[Unit, @types.DataError] = Ok(
    encode_value(
      [],
      huge,
      CDecimalBytes(DecimalShape::{ precision: 38, scale: 2, }),
      "x",
    ),
  ) catch {
    e => Err(e)
  }
  if too_wide is Ok(_) {
    fail("a 39-digit unscaled value was expected to refuse")
  }
  // The shortest two's complement: zero, one past the low half, 128
  // below zero, 127 below zero, and a positive byte with its top bit set.
  let zero : Array[Byte] = []
  push_twos_complement(zero, 0UL, 0UL, negative=true)
  assert_eq(spelling(zero), b"\x00")
  let carried : Array[Byte] = []
  push_twos_complement(carried, 1UL, 0UL, negative=true)
  assert_eq(spelling(carried), b"\xFF\x00\x00\x00\x00\x00\x00\x00\x00")
  let below : Array[Byte] = []
  push_twos_complement(below, 0UL, 1UL, negative=true)
  assert_eq(spelling(below), b"\xFF")
  let small : Array[Byte] = []
  push_twos_complement(small, 0UL, 127UL, negative=true)
  assert_eq(spelling(small), b"\x81")
  let kept : Array[Byte] = []
  push_twos_complement(kept, 0UL, 128UL, negative=false)
  assert_eq(spelling(kept), b"\x00\x80")
  // A decimal column of a NaN has no shape; a Null column no type.
  let nan = @types.Scalar::Decimal(@types.Dec128::nan())
  match (Ok(decimal_shape_of([nan], "m")) catch { e => Err(e) }) {
    Err(e) =>
      assert_eq(
        e,
        invalid(
          "column \"m\" holds the decimal NaN, which has no fixed-point spelling",
        ),
      )
    Ok(_) => fail("a NaN decimal was expected to refuse")
  }
  let infinity = @types.Scalar::Decimal(@types.Dec128::infinity())
  match (Ok(decimal_shape_of([infinity], "m")) catch { e => Err(e) }) {
    Err(_) => ()
    Ok(_) => fail("an infinite decimal was expected to refuse")
  }
  match (Ok(write_type(@types.DataType::Null, [], "n")) catch { e => Err(e) }) {
    Err(e) =>
      assert_eq(
        e,
        unsupported(
          "a column \"n\" of dtype Null: a field names the type of its values, and a null column names none",
        ),
      )
    Ok(_) => fail("a Null column was expected to refuse")
  }
  // The helpers the writer decides through: cells that are not lists or
  // structs contribute nothing.
  assert_eq(list_items([@types.Scalar::Null, @types.Scalar::Int(1L)]), [])
  assert_eq(struct_cells([@types.Scalar::Null, @types.Scalar::Int(1L)], "k"), [
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
}

///|
test "a struct inside a struct is a record inside a namespace" {
  let inner = @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field("k", @types.DataType::Int)]),
  )
  let outer = @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field("inner", inner)]),
  )
  let (_, json) = write_type(outer, [], "r")
  assert_true(json.stringify().contains("\"namespace\":\"moonframe.r\""))
  assert_true(json.stringify().contains("\"name\":\"inner\""))
  // Names: the ones the schema allows, and the one it does not.
  for good in ["_", "a1_b", "Z9"] {
    check_name(good, good)
  }
  let empty : Result[Unit, @types.DataError] = Ok(check_name("", "c")) catch {
    e => Err(e)
  }
  assert_eq(
    empty,
    Err(
      invalid(
        "column \"c\": the name \"\" is not one an Avro schema allows (letters, digits and _, starting with a letter or _)",
      ),
    ),
  )
  // The marker is the schema's own, and the hash of nothing is its basis.
  assert_eq(sync_marker("a").length(), 16)
  assert_eq(sync_marker("a"), sync_marker("a"))
  assert_false(sync_marker("a") == sync_marker("b"))
  assert_eq(fnv1a("", 0xcbf29ce484222325UL), 0xcbf29ce484222325UL)
}
