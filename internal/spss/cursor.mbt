///|
/// One located parse refusal — the reader's error vocabulary for bytes
/// that contradict the layout.
fn bad(what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("spss: \{what}"),
  )
}

///|
/// One refusal by name — the reader's error vocabulary for something
/// this reader does not read.
fn nope(what : String) -> @types.DataError {
  @types.DataError::Unsupported("spss: \{what}")
}

///|
/// The file's bytes under a reading position, read in the file's integer
/// byte order. Every read is checked against what remains before it
/// indexes: one that would leave the file refuses, naming the offset it
/// was at, so no count the file carries reaches an index, a slice, or an
/// allocation unchecked. The position never passes the byte length,
/// which is what keeps the subtraction form of those checks exact.
priv struct Cursor {
  bytes : Bytes
  mut pos : Int32
  mut big : Bool
  mut big_float : Bool
}

///|
/// Refuse unless `need` bytes remain at the position. Every count the
/// reader checks this way is read as unsigned, so none is negative.
fn Cursor::need(self : Cursor, need : Int64) -> Unit raise @types.DataError {
  if (self.bytes.length() - self.pos).to_int64() < need {
    raise bad(
      "the file ends at byte \{self.bytes.length()} before the \{need} bytes needed at byte \{self.pos}",
    )
  }
}

///|
/// Refuse unless `need` bytes remain at the position.
fn Cursor::short(self : Cursor, need : Int32) -> Unit raise @types.DataError {
  self.need(need.to_int64())
}

///|
/// Step over `count` bytes.
fn Cursor::skip(self : Cursor, count : Int32) -> Unit raise @types.DataError {
  self.short(count)
  self.pos = self.pos + count
}

///|
/// Step over a `count` too wide for the machine word's arithmetic. The
/// check that precedes the narrowing proves it fits the file, and so the
/// word.
fn Cursor::skip64(self : Cursor, count : Int64) -> Unit raise @types.DataError {
  self.need(count)
  self.pos = self.pos + count.to_int()
}

///|
/// `count` bytes at the position, copied out; the position moves past
/// them.
fn Cursor::take(self : Cursor, count : Int32) -> Bytes raise @types.DataError {
  self.short(count)
  let start = self.pos
  let out = Bytes::makei(count, i => self.bytes[start + i])
  self.pos = start + count
  out
}

///|
/// A one-byte unsigned integer.
fn Cursor::u8(self : Cursor) -> Int32 raise @types.DataError {
  self.short(1)
  let value = self.bytes[self.pos].to_int()
  self.pos = self.pos + 1
  value
}

///|
/// A four-byte integer, in the file's byte order.
fn Cursor::u32(self : Cursor) -> Int64 raise @types.DataError {
  self.short(4)
  let mut value = 0L
  if self.big {
    for i in 0..<4 {
      value = (value << 8) | self.bytes[self.pos + i].to_int64()
    }
  } else {
    for i = 3; i >= 0; i = i - 1 {
      value = (value << 8) | self.bytes[self.pos + i].to_int64()
    }
  }
  self.pos = self.pos + 4
  value
}

///|
/// A four-byte signed integer.
fn Cursor::i32(self : Cursor) -> Int64 raise @types.DataError {
  let value = self.u32()
  if value >= 2147483648L {
    value - 4294967296L
  } else {
    value
  }
}

///|
/// An eight-byte integer.
fn Cursor::u64(self : Cursor) -> UInt64 raise @types.DataError {
  self.short(8)
  let mut value = 0UL
  if self.big {
    for i in 0..<8 {
      value = (value << 8) | self.bytes[self.pos + i].to_uint64()
    }
  } else {
    for i = 7; i >= 0; i = i - 1 {
      value = (value << 8) | self.bytes[self.pos + i].to_uint64()
    }
  }
  self.pos = self.pos + 8
  value
}

///|
/// An eight-byte integer, as a count the machine word holds.
fn Cursor::i64(self : Cursor) -> Int64 raise @types.DataError {
  self.u64().reinterpret_as_int64()
}

///|
/// The bits of the eight-byte floating-point number at the position,
/// in the file's floating-point byte order.
fn Cursor::f64_bits(self : Cursor) -> UInt64 raise @types.DataError {
  self.short(8)
  let value = bits_at(self.bytes, self.pos, self.big_float)
  self.pos = self.pos + 8
  value
}

///|
/// The bits of the floating-point number stored in the eight bytes that
/// begin at `at`, in the floating-point byte order `big`.
fn bits_at(bytes : Bytes, at : Int32, big : Bool) -> UInt64 {
  let mut value = 0UL
  if big {
    for i in 0..<8 {
      value = (value << 8) | bytes[at + i].to_uint64()
    }
  } else {
    for i = 7; i >= 0; i = i - 1 {
      value = (value << 8) | bytes[at + i].to_uint64()
    }
  }
  value
}

///|
/// The eight bytes `bits` spells in the floating-point byte order
/// `big`, appended to `out`.
fn push_bits(out : Array[Byte], bits : UInt64, big : Bool) -> Unit {
  for i in 0..<8 {
    let shift = if big { (7 - i) * 8 } else { i * 8 }
    out.push(((bits >> shift) & 0xFFUL).to_byte())
  }
}

///|
/// The number rounded up to a multiple of eight, in the wide arithmetic
/// a width from the file needs.
fn up8(n : Int64) -> Int64 {
  (n + 7L) / 8L * 8L
}

///|
/// The number rounded up to a multiple of four, in the wide arithmetic
/// a length from the file needs.
fn up4(n : Int64) -> Int64 {
  (n + 3L) / 4L * 4L
}

///|
/// Where `needle` begins in `haystack`, or −1.
fn locate(haystack : BytesView, needle : Int32) -> Int32 {
  for i in 0..<haystack.length() {
    if haystack[i].to_int() == needle {
      return i
    }
  }
  -1
}

///|
/// Whether two names spell the same variable: byte for byte, with the
/// ASCII letters ignoring case. The long-name records key their entries
/// by a variable's name as its record spells it, and writers differ in
/// case.
fn same_name(a : BytesView, b : BytesView) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    let x = a[i].to_int()
    let y = b[i].to_int()
    let lx = if x >= 97 && x <= 122 { x - 32 } else { x }
    let ly = if y >= 97 && y <= 122 { y - 32 } else { y }
    if lx != ly {
      return false
    }
  }
  true
}
