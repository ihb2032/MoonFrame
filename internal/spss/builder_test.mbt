// Builders of system files by hand, for the refusal and edge tests: the
// header record, variable records, extension records, the terminator,
// the data record under each compression, and the zlib header, block
// and trailer. A file built here has the offsets its builder names, so a
// test can patch one field and know the byte it lies at.

///|
/// A system file under construction, little-endian.
struct File {
  bytes : Array[Byte]
}

///|
/// A zlib-compressed file and where its data record's parts lie.
struct Zsav {
  bytes : Bytes
  header_at : Int32
  block_at : Int32
  trailer_at : Int32
}

///|
/// A format code: a type, a width and a number of decimal places.
fn fmt(type_ : Int32, width : Int32, decimals : Int32) -> Int32 {
  (type_ << 16) | (width << 8) | decimals
}

///|
/// An empty file.
fn File::new() -> File {
  { bytes: [], }
}

///|
/// A one-byte integer.
fn File::byte(self : File, value : Int32) -> File {
  self.bytes.push((value & 0xFF).to_byte())
  self
}

///|
/// A four-byte integer.
fn File::int(self : File, value : Int32) -> File {
  for i in 0..<4 {
    self.bytes.push(((value >> (i * 8)) & 0xFF).to_byte())
  }
  self
}

///|
/// An eight-byte integer.
fn File::wide(self : File, value : Int64) -> File {
  let bits = value.reinterpret_as_uint64()
  for i in 0..<8 {
    self.bytes.push(((bits >> (i * 8)) & 0xFFUL).to_byte())
  }
  self
}

///|
/// The eight bytes of a double.
fn File::double(self : File, value : Double) -> File {
  self.wide(value.reinterpret_as_uint64().reinterpret_as_int64())
}

///|
/// Raw bytes.
fn File::raw(self : File, bytes : Bytes) -> File {
  for b in bytes {
    self.bytes.push(b)
  }
  self
}

///|
/// `count` blanks.
fn File::blanks(self : File, count : Int32) -> File {
  for _ in 0..<count {
    self.bytes.push(b' ')
  }
  self
}

///|
/// A text padded with blanks to `width`.
fn File::text(self : File, text : Bytes, width : Int32) -> File {
  self.raw(text).blanks(width - text.length())
}

///|
/// The file as bytes.
fn File::finish(self : File) -> Bytes {
  Bytes::from_array(self.bytes)
}

///|
/// The file header record: the signature for a zlib-compressed file or
/// the other one, the compression and the case count; the layout code 2,
/// the bias 100 and the rest constants.
fn header(zlib : Bool, compression : Int32, ncases : Int32) -> File {
  let f = File::new()
  let magic : Bytes = if zlib { b"$FL3" } else { b"$FL2" }
  ignore(
    f
    .raw(magic)
    .text(b"@(#) SPSS DATA FILE - built by hand", 60)
    .int(2)
    .int(0)
    .int(compression)
    .int(0)
    .int(ncases)
    .double(100.0)
    .text(b"01 Jan 70", 9)
    .text(b"00:00:00", 8)
    .blanks(64)
    .blanks(3),
  )
  f
}

///|
/// A variable record of `width` — 0 a numeric variable, above it a
/// string's width in bytes — named as `name` spells it, its print and
/// write format one code, no label and no missing values.
fn variable(f : File, width : Int32, name : Bytes, format : Int32) -> Unit {
  record(f, width, 0, 0, format, name, b"")
}

///|
/// A variable record with a label flag, a missing value count and
/// `extra` bytes after the name: a label, missing values, or both.
fn record(
  f : File,
  width : Int32,
  label_flag : Int32,
  n_missing : Int32,
  format : Int32,
  name : Bytes,
  extra : Bytes,
) -> Unit {
  ignore(
    f
    .int(2)
    .int(width)
    .int(label_flag)
    .int(n_missing)
    .int(format)
    .int(format)
    .text(name, 8)
    .raw(extra),
  )
}

///|
/// A continuation record: type -1, no name.
fn continuation(f : File) -> Unit {
  record(f, -1, 0, 0, fmt(1, 255, 0), b"", b"")
}

///|
/// The dictionary terminator.
fn terminator(f : File) -> Unit {
  ignore(f.int(999).int(0))
}

///|
/// An extension record of `subtype` whose data is `count` elements of
/// `size` bytes.
fn extension(
  f : File,
  subtype : Int32,
  size : Int32,
  count : Int32,
  data : Bytes,
) -> Unit {
  ignore(f.int(7).int(subtype).int(size).int(count).raw(data))
}

///|
/// The machine integer info record: a floating-point representation and
/// a character code of the test's choosing, the rest as every
/// reference-written file spells it.
fn integer_info(representation : Int32, code : Int32) -> File {
  let f = File::new()
  ignore(
    f
    .int(7)
    .int(3)
    .int(4)
    .int(8)
    .int(20)
    .int(0)
    .int(0)
    .int(-1)
    .int(representation)
    .int(1)
    .int(2)
    .int(code),
  )
  f
}

///|
/// The machine records every reference-written file carries after its
/// value labels: the integer info — IEEE 754, little-endian, code page
/// 65001 — and the floating-point info.
fn machine(f : File) -> Unit {
  ignore(f.raw(integer_info(1, 65001).finish()))
  let floating = File::new()
  ignore(floating.int(7).int(4).int(8).int(3))
  for bits in [0xFFEFFFFFFFFFFFFFUL, 0x7FEFFFFFFFFFFFFFUL, 0xFFEFFFFFFFFFFFFEUL] {
    ignore(floating.wide(bits.reinterpret_as_int64()))
  }
  ignore(f.raw(floating.finish()))
}

///|
/// A numeric variable N under F8.2 with `values` for cases,
/// uncompressed. The header is bytes 0 to 175, the variable record is at
/// 176, the terminator at 208 and the data at 216.
fn numeric(values : ReadOnlyArray[Double]) -> File {
  let f = header(false, 0, values.length())
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  for value in values {
    ignore(f.double(value))
  }
  f
}

///|
/// A file with one case: N is 1.
fn one_case() -> Bytes {
  numeric([1.0]).finish()
}

///|
/// The zlib data record of a correct file: the 24-byte header, one zlib
/// stream spelling `codes`, and a trailer naming that one block.
fn zlib_data(f : File, codes : Bytes) -> Zsav {
  let header_at = f.bytes.length()
  let compressed = @zlib.compress(codes)
  let block_at = header_at + 24
  let trailer_at = block_at + compressed.length()
  ignore(
    f
    .wide(header_at.to_int64())
    .wide(trailer_at.to_int64())
    .wide(48L)
    .raw(compressed)
    .wide(-100L)
    .wide(0L)
    .int(0x3FF000)
    .int(1)
    .wide(header_at.to_int64())
    .wide(block_at.to_int64())
    .int(codes.length())
    .int(compressed.length()),
  )
  { bytes: f.finish(), header_at, block_at, trailer_at, }
}

///|
/// A zlib-compressed file of N with `codes` for its data and `ncases`
/// declared: one case of value 1 when the codes end it.
fn zsav(ncases : Int32, codes : Bytes) -> Zsav {
  let f = header(true, 2, ncases)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  zlib_data(f, codes)
}

///|
/// The codes of one case holding 1, ended: the code 101, the end code
/// 252, and six fillers.
fn one_unit_codes() -> Bytes {
  b"\x65\xfc\x00\x00\x00\x00\x00\x00"
}

///|
/// `whole` with the four-byte integer `value` written at `at`.
fn patched(whole : Bytes, at : Int32, value : Int32) -> Bytes {
  Bytes::makei(whole.length(), i => {
    let offset = i - at
    if offset >= 0 && offset < 4 {
      ((value >> (offset * 8)) & 0xFF).to_byte()
    } else {
      whole[i]
    }
  })
}

///|
/// `whole` with the eight-byte integer `value` written at `at`.
fn patched_wide(whole : Bytes, at : Int32, value : Int64) -> Bytes {
  let bits = value.reinterpret_as_uint64()
  Bytes::makei(whole.length(), i => {
    let offset = i - at
    if offset >= 0 && offset < 8 {
      ((bits >> (offset * 8)) & 0xFFUL).to_byte()
    } else {
      whole[i]
    }
  })
}

///|
/// `whole` with `bytes` written over it from `at`.
fn patched_bytes(whole : Bytes, at : Int32, bytes : Bytes) -> Bytes {
  Bytes::makei(whole.length(), i => {
    let offset = i - at
    if offset >= 0 && offset < bytes.length() {
      bytes[offset]
    } else {
      whole[i]
    }
  })
}

///|
/// The first `count` bytes of `whole`.
fn cut(whole : Bytes, count : Int32) -> Bytes {
  Bytes::makei(count, i => whole[i])
}

///|
/// An `Unsupported` refusal with its text.
fn unsupported(text : String) -> @types.DataError {
  @types.DataError::Unsupported("spss: \{text}")
}

///|
/// A located `ParseError` with its text.
fn parse(text : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("spss: \{text}"),
  )
}

///|
/// Read `bytes` and fail unless the codec refuses it with exactly `want`.
fn refuses(bytes : Bytes, want : @types.DataError) -> Unit raise {
  assert_eq(read_error(bytes), want)
}

///|
/// The cells of each column of a table read back, spelled.
fn spelled_columns(columns : Array[(String, @series.Series)]) -> Array[String] {
  columns.map(pair => {
    let cells = pair.1.to_scalars().map(spelled)
    "\{pair.0}(\{pair.1.dtype()}): \{cells.join(", ")}"
  })
}
