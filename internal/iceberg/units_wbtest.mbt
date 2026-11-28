// Whitebox tests of the reader's parts in isolation: the lines the corpus
// cannot reach. A manifest the reference wrote never rides a snappy block,
// and its zstandard blocks are well formed; the cursor's own refusals, the
// two spellings a path's scheme cannot take, and a location spelled as a
// POSIX absolute path are met by no file. These
// pin them: a manifest container built here, block by block, under each
// codec, and the parts called on their own. The blackbox suite compares
// every table with what the reference answers and every refusal with its
// sidecar's text.

///|
/// The schema of a manifest whose records hold a status and a data file
/// of a path, a format and a record count, and no partition.
const ENTRY_SCHEMA : String = "{\"type\":\"record\",\"name\":\"manifest_entry\",\"fields\":[{\"name\":\"status\",\"type\":\"int\",\"field-id\":0},{\"name\":\"data_file\",\"type\":{\"type\":\"record\",\"name\":\"r2\",\"fields\":[{\"name\":\"file_path\",\"type\":\"string\",\"field-id\":100},{\"name\":\"file_format\",\"type\":\"string\",\"field-id\":101},{\"name\":\"record_count\",\"type\":\"long\",\"field-id\":103}]},\"field-id\":2}]}"

///|
/// The table schema that manifest's header carries: no column.
const TABLE : String = "{\"type\":\"struct\",\"fields\":[],\"schema-id\":0}"

///|
/// A whole number as a zigzag variable-length integer.
fn zz(out : Array[Byte], value : Int64) -> Unit {
  let mut rest = ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
  while rest >= 0x80UL {
    out.push((rest & 0x7FUL).to_byte() | b'\x80')
    rest = rest >> 7
  }
  out.push(rest.to_byte())
}

///|
/// A string by its byte length and its bytes.
fn zs(out : Array[Byte], text : String) -> Unit {
  let bytes = @utf8.encode(text)
  zz(out, bytes.length().to_int64())
  for b in bytes {
    out.push(b)
  }
}

///|
/// The bytes of one record: an added data file of one row.
fn one_record() -> Bytes {
  let out : Array[Byte] = []
  zz(out, 1L)
  zs(out, "a")
  zs(out, "PARQUET")
  zz(out, 3L)
  Bytes::from_array(out)
}

///|
/// A manifest container whose one block holds `block` as it is spelled
/// under `codec`.
fn manifest_under(codec : String, block : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for b in b"Obj\x01" {
    out.push(b)
  }
  zz(out, 6L)
  zs(out, "avro.schema")
  zs(out, ENTRY_SCHEMA)
  zs(out, "schema")
  zs(out, TABLE)
  zs(out, "partition-spec")
  zs(out, "[]")
  zs(out, "format-version")
  zs(out, "2")
  zs(out, "content")
  zs(out, "data")
  zs(out, "avro.codec")
  zs(out, codec)
  zz(out, 0L)
  for b in SYNC {
    out.push(b)
  }
  zz(out, 1L)
  zz(out, block.length().to_int64())
  for b in block {
    out.push(b)
  }
  for b in SYNC {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Sixteen bytes: the sync marker every container built here ends its
/// header and its block with.
const SYNC : Bytes = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"

///|
/// Where a container's first block begins.
fn block_at(bytes : Bytes) -> Int32 raise @types.DataError {
  open_container(bytes, "the manifest").blocks.at
}

///|
/// What reading a manifest's files raised, by the text the variant carries;
/// "" when it answered.
fn files_refusal(bytes : Bytes) -> String {
  let outcome : Result[Array[IcebergFile], @types.DataError] = Ok(
    iceberg_files(bytes),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => ""
    Err(Unsupported(text)) => text
    Err(ParseError(Message(text))) => text
    Err(_) => "a variant the codec does not raise"
  }
}

///|
/// How many files a manifest names.
fn files_of(bytes : Bytes) -> Int32 raise @types.DataError {
  iceberg_files(bytes).length()
}

///|
/// A snappy block: the raw stream, then the checksum of the bytes it
/// encodes, big-endian.
fn snappy_block(body : Bytes, checksum : UInt32) -> Bytes {
  let out : Array[Byte] = []
  for b in @snappy.compress_raw(body) {
    out.push(b)
  }
  out.push(((checksum >> 24) & 0xFFU).to_byte())
  out.push(((checksum >> 16) & 0xFFU).to_byte())
  out.push(((checksum >> 8) & 0xFFU).to_byte())
  out.push((checksum & 0xFFU).to_byte())
  Bytes::from_array(out)
}

///|
test "a snappy block inflates under its checksum, and answers its files" {
  let body = one_record()
  let bytes = manifest_under(
    "snappy",
    snappy_block(body, @checksum.crc32(body)),
  )
  @test.assert_eq(files_of(bytes), 1)
}

///|
test "a snappy block shorter than its checksum is refused" {
  let bytes = manifest_under("snappy", b"\x01\x02\x03")
  @test.assert_eq(
    files_refusal(bytes),
    "iceberg: byte \{block_at(bytes)}: a snappy block shorter than its checksum",
  )
}

///|
test "a snappy block that does not decompress is refused, naming its byte" {
  // A raw stream opens with the length of what it holds; this one claims
  // more than the bound allows.
  let bytes = manifest_under("snappy", b"\xff\xff\xff\xff\x7f\x00\x00\x00\x00")
  @test.assert_eq(
    files_refusal(bytes),
    "iceberg: byte \{block_at(bytes)}: a snappy block that does not decompress within 16777216 bytes",
  )
}

///|
test "a snappy block whose checksum does not match is refused" {
  let bytes = manifest_under("snappy", snappy_block(one_record(), 0U))
  @test.assert_eq(
    files_refusal(bytes),
    "iceberg: byte \{block_at(bytes)}: a snappy block whose checksum does not match its bytes",
  )
}

///|
test "a zstandard block inflates, and one that does not is refused" {
  let body = one_record()
  @test.assert_eq(files_of(manifest_under("zstd", @zstd.compress(body))), 1)
  let bytes = manifest_under("zstandard", b"\x00\x00\x00\x00\x00\x00\x00\x00")
  @test.assert_eq(
    files_refusal(bytes),
    "iceberg: byte \{block_at(bytes)}: a zstandard block that does not decompress within 16777216 bytes",
  )
}

///|
test "a block stored as it is, and one deflated by the deflate crate, answer their files" {
  let body = one_record()
  @test.assert_eq(files_of(manifest_under("null", body)), 1)
  @test.assert_eq(
    files_of(manifest_under("deflate", @flate.deflate_all(body))),
    1,
  )
}

///|
/// What reading one byte of a cursor raised, by its text; "answered" when
/// it did not.
fn byte_refusal(cur : Cursor) -> String {
  let outcome : Result[Int32, @types.DataError] = Ok(cur.byte()) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => "answered"
    Err(ParseError(Message(text))) => text
    Err(_) => "a variant the codec does not raise"
  }
}

///|
/// What taking one byte of a cursor raised, by its text; "answered" when
/// it did not.
fn take_refusal(cur : Cursor) -> String {
  let outcome : Result[Bytes, @types.DataError] = Ok(cur.take(1)) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => "answered"
    Err(ParseError(Message(text))) => text
    Err(_) => "a variant the codec does not raise"
  }
}

///|
/// What reading a whole number of a cursor raised, by its text; the number
/// when it answered one.
fn long_refusal(cur : Cursor) -> String {
  let outcome : Result[Int64, @types.DataError] = Ok(cur.long()) catch {
    error => Err(error)
  }
  match outcome {
    Ok(number) => "answered \{number}"
    Err(ParseError(Message(text))) => text
    Err(_) => "a variant the codec does not raise"
  }
}

///|
test "a cursor refuses to walk past its bytes, naming the byte" {
  let empty = Cursor::{ bytes: b"", at: 0, origin: "the run", }
  @test.assert_eq(
    byte_refusal(empty),
    "iceberg: byte 0 of the run: the bytes end inside a value",
  )
  @test.assert_eq(
    take_refusal(empty),
    "iceberg: byte 0 of the run: the bytes end inside a value",
  )
  let short = Cursor::{ bytes: b"\x01\x02", at: 2, origin: "the run", }
  @test.assert_eq(
    take_refusal(short),
    "iceberg: byte 2 of the run: the bytes end inside a value",
  )
  @test.assert_eq(
    byte_refusal(short),
    "iceberg: byte 2 of the run: the bytes end inside a value",
  )
  let two = Cursor::{ bytes: b"\x04", at: 0, origin: "the run", }
  @test.assert_eq(long_refusal(two), "answered 2")
}

///|
test "a cursor refuses a variable-length integer wider than 64 bits" {
  let wide = Cursor::{
    bytes: b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02",
    at: 0,
    origin: "the run",
  }
  @test.assert_eq(
    long_refusal(wide),
    "iceberg: byte 0 of the run: a variable-length integer wider than 64 bits",
  )
  // Ten bytes whose last carries the sixty-third bit alone are a number.
  let edge = Cursor::{
    bytes: b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
    at: 0,
    origin: "the run",
  }
  @test.assert_eq(long_refusal(edge), "answered -9223372036854775808")
}

///|
/// What a collection block's item count is, as a cursor spells it.
fn block_count_of(cur : Cursor) -> String {
  let outcome : Result[Int64, @types.DataError] = Ok(cur.block_count()) catch {
    error => Err(error)
  }
  match outcome {
    Ok(number) => "answered \{number}"
    Err(ParseError(Message(text))) => text
    Err(_) => "a variant the codec does not raise"
  }
}

///|
test "a collection block of the least count is refused, and one of a negative count gives its size" {
  // Ten bytes, all ones and a last one: the least 64-bit whole number.
  let least = Cursor::{
    bytes: b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
    at: 0,
    origin: "the run",
  }
  @test.assert_eq(
    block_count_of(least),
    "iceberg: byte 0 of the run: a collection block of -9223372036854775808 items",
  )
  // Three spells -2: two items follow the byte size the encoding names.
  let negative = Cursor::{ bytes: b"\x03\x04", at: 0, origin: "the run", }
  @test.assert_eq(block_count_of(negative), "answered 2")
  @test.assert_eq(negative.at, 2)
}

///|
test "a whole number is read from a sign and digits, and from nothing else" {
  @test.assert_eq(int64_of_text("-"), None)
  @test.assert_eq(int64_of_text(""), None)
  @test.assert_eq(
    int64_of_text("-9223372036854775808"),
    Some(-9223372036854775808L),
  )
  @test.assert_eq(int64_of_text("9223372036854775808"), None)
  @test.assert_eq(
    int64_of_text("9223372036854775807"),
    Some(9223372036854775807L),
  )
  @test.assert_eq(int64_of_text("-9223372036854775809"), None)
}

///|
test "a path's scheme is two or more allowed characters before a colon" {
  @test.assert_eq(scheme_of("D:/wh/ns/t"), None)
  @test.assert_eq(scheme_of("1a:bc"), None)
  @test.assert_eq(scheme_of("ab/c:d"), None)
  @test.assert_eq(scheme_of("wh/ns/t"), None)
  @test.assert_eq(scheme_of(""), None)
  @test.assert_eq(scheme_of("s3://bucket/t"), Some("s3"))
  @test.assert_eq(scheme_of("a+b.c:d"), Some("a+b.c"))
}

///|
test "a path under a POSIX location is answered relative to it, and one elsewhere is refused" {
  // A POSIX absolute path names no scheme, as a drive path names none; the
  // corpus, written on this platform, holds no such location.
  @test.assert_eq(
    relative_to("/wh/ns/t/data/f.parquet", "/wh/ns/t", "the file"),
    "data/f.parquet",
  )
  // A separator left at the end of the location changes nothing.
  @test.assert_eq(
    relative_to("/wh/ns/t/data/f.parquet", "/wh/ns/t/", "the file"),
    "data/f.parquet",
  )
  let outside : Result[String, @types.DataError] = Ok(
    relative_to("/wh/other/f.parquet", "/wh/ns/t", "the file"),
  ) catch {
    error => Err(error)
  }
  match outside {
    Ok(_) => fail("a path outside the location read back")
    Err(Unsupported(text)) =>
      @test.assert_eq(
        text, "iceberg: the file /wh/other/f.parquet lies outside the table location /wh/ns/t",
      )
    Err(_) => fail("a variant the codec does not raise")
  }
  // A path under a scheme the location does not lie under names the scheme.
  let elsewhere : Result[String, @types.DataError] = Ok(
    relative_to("s3://bucket/f.parquet", "/wh/ns/t", "the file"),
  ) catch {
    error => Err(error)
  }
  match elsewhere {
    Ok(_) => fail("a path of another scheme read back")
    Err(Unsupported(text)) =>
      @test.assert_eq(
        text, "iceberg: the file s3://bucket/f.parquet lies under the scheme s3, not under the table location /wh/ns/t, which lies under no scheme",
      )
    Err(_) => fail("a variant the codec does not raise")
  }
}

///|
test "a column's type that is neither a name nor a definition is refused" {
  let number : Json = Json::number(5.0)
  let outcome : Result[@types.DataType, @types.DataError] = Ok(
    dtype_of(number, "c"),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("a number read as a type")
    Err(ParseError(Message(text))) =>
      @test.assert_eq(
        text, "iceberg: the type of column \"c\" is neither a name nor a definition",
      )
    Err(_) => fail("a variant the codec does not raise")
  }
  let members : Map[String, Json] = { "type": number }
  let outcome : Result[@types.DataType, @types.DataError] = Ok(
    dtype_of(Json::object(members), "c"),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("a definition whose type is a number read as a type")
    Err(ParseError(Message(text))) =>
      @test.assert_eq(
        text, "iceberg: the type of column \"c\" is neither a name nor a definition",
      )
    Err(_) => fail("a variant the codec does not raise")
  }
}
