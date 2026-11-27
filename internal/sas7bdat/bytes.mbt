// Checked reads over the file's bytes, and the two errors the reader
// raises. Every offset, length and count the file spells passes through
// one of these before it indexes anything, so a field that points past
// the bytes the file holds refuses instead of reading them.

///|
/// The error for bytes that contradict the layout, naming the byte.
fn bad(offset : Int64, what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("sas7bdat: byte \{offset}: \{what}"),
  )
}

///|
/// The error for a file this reader does not read, naming the byte.
fn refused(offset : Int64, what : String) -> @types.DataError {
  @types.DataError::Unsupported("sas7bdat: byte \{offset}: \{what}")
}

///|
/// That the file holds `count` bytes from byte `at`, both zero or more:
/// `what` occupies them. A file that ends earlier raises `ParseError`.
/// The test is written in subtraction form, so an `at` near the ceiling
/// cannot wrap `at + count` back inside the bound.
fn need(
  bytes : Bytes,
  at : Int64,
  count : Int64,
  what : String,
) -> Unit raise @types.DataError {
  let length = bytes.length().to_int64()
  if at < 0L || at > length || count < 0L || count > length - at {
    raise bad(
      at,
      "the file ends at byte \{length} inside \{what} (bytes \{at} to \{at + count - 1L})",
    )
  }
}

///|
/// The byte at `at`, as a value from 0 to 255.
fn byte_at(bytes : Bytes, at : Int64) -> Int32 raise @types.DataError {
  need(bytes, at, 1L, "a byte")
  bytes[at.to_int()].to_int()
}

///|
/// The unsigned integer of `width` bytes (2, 4 or 8) at `at`, read in
/// the file's byte order: least significant byte first when `little`.
fn uint_at(
  bytes : Bytes,
  at : Int64,
  width : Int64,
  little : Bool,
) -> UInt64 raise @types.DataError {
  need(bytes, at, width, "an unsigned integer")
  let base = at.to_int()
  let mut value : UInt64 = 0UL
  if little {
    for i in 0..<width.to_int() {
      value = value | (bytes[base + i].to_uint64() << (8 * i))
    }
  } else {
    for i in 0..<width.to_int() {
      value = (value << 8) | bytes[base + i].to_uint64()
    }
  }
  value
}
