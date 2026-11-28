// The wire format the metadata speaks — the Protocol Buffers encoding of
// the PostScript, the Footer, a StripeFooter and the types: base-128
// varints, each field a tag (its number and its wire type) and its value.
// A message is decoded into its fields once, whole, and the readers then
// pick the fields they know by number, in whatever order they arrived,
// and never look at the rest — the forward-compatibility rule every
// reader of the format applies.

///|
/// A byte that contradicts the layout. `at` is the offset the refusal
/// names, and `what` says what is wrong there.
fn bad(at : Int32, what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("orc: byte \{at}: \{what}"),
  )
}

///|
/// A shape the format allows and this reader does not read, named.
fn refuse(what : String) -> @types.DataError {
  @types.DataError::Unsupported("orc: \{what}")
}

///|
/// A count with its noun: the noun's plural when the count is not one —
/// its own when the plural is not a plain `s`, else the noun with one.
fn counted(count : Int64, noun : String, many~ : String = "") -> String {
  if count == 1L {
    "\{count} \{noun}"
  } else if many == "" {
    "\{count} \{noun}s"
  } else {
    "\{count} \{many}"
  }
}

///|
/// The indefinite article before a word: `an` before a vowel.
fn a(word : String) -> String {
  match word[0] {
    'a' | 'e' | 'i' | 'o' | 'u' | 'A' | 'E' | 'I' | 'O' | 'U' => "an"
    _ => "a"
  }
}

///|
/// A cursor over one run of bytes: the run, the offset of its first byte
/// in the file, and what the run is — the words its refusals name it by.
/// It never reads past the run: a value the run cannot hold in full
/// raises, naming the byte where it broke off. A cursor over the bytes a
/// compressed stream inflates to names the stream's own byte, and says so.
priv struct Cursor {
  bytes : Bytes
  base : Int32
  what : String
  inflated : Bool
  mut pos : Int32
}

///|
/// The cursor at the head of a run of `bytes` whose first byte is at `at`
/// of the file; a run a compressed stream inflates to has no byte of its
/// own in the file.
fn cursor(
  bytes : Bytes,
  at : Int32,
  what : String,
  inflated~ : Bool = false,
) -> Cursor {
  { bytes, base: at, what, inflated, pos: 0, }
}

///|
/// The offset of the next unread byte, in the file.
fn Cursor::offset(self : Cursor) -> Int32 {
  self.base + self.pos.to_int()
}

///|
/// The bytes still unread.
fn Cursor::left(self : Cursor) -> Int32 {
  self.bytes.length() - self.pos
}

///|
/// The refusal for a run that breaks off or holds what it should not:
/// `ParseError`, naming the next unread byte.
fn Cursor::bad(self : Cursor, detail : String) -> @types.DataError {
  self.bad_at(self.offset(), detail)
}

///|
/// As `bad`, naming a byte the cursor has already read — the header of a
/// run that says what the bytes cannot hold.
fn Cursor::bad_at(
  self : Cursor,
  at : Int32,
  detail : String,
) -> @types.DataError {
  if self.inflated {
    bad(at, "of the inflated \{self.what}: \{detail}")
  } else {
    bad(at, "\{self.what}: \{detail}")
  }
}

///|
/// One byte.
fn Cursor::byte(self : Cursor) -> Int32 raise @types.DataError {
  if self.pos < self.bytes.length() {
    let value = self.bytes[self.pos].to_int()
    self.pos = self.pos + 1
    value
  } else {
    raise self.bad("the bytes end inside a value")
  }
}

///|
/// An unsigned base-128 varint: seven payload bits a byte, least
/// significant first, the top bit of every byte but the last saying one
/// more follows. Ten bytes hold 64 bits and the tenth may carry only the
/// lowest of them.
fn Cursor::varint(self : Cursor) -> UInt64 raise @types.DataError {
  let mut result : UInt64 = 0UL
  let mut byte_at = 0
  let mut last = false
  while !last {
    let b = self.byte()
    if byte_at == 9 {
      if b > 1 {
        raise self.bad("the bytes hold a varint wider than 64 bits")
      }
      return result | (b.to_uint64() << 63)
    }
    result = result | ((b & 0x7F).to_uint64() << (7 * byte_at))
    last = b < 0x80
    byte_at = byte_at + 1
  }
  result
}

///|
/// The signed integer a zigzag varint names: the sign in the least
/// significant bit, the magnitude in the rest.
fn Cursor::zigzag(self : Cursor) -> Int64 raise @types.DataError {
  unzigzag(self.varint())
}

///|
/// The signed integer a zigzag-coded unsigned value names.
fn unzigzag(u : UInt64) -> Int64 {
  ((u >> 1) ^ (0UL - (u & 1UL))).reinterpret_as_int64()
}

///|
/// A little-endian unsigned integer of `width` bytes, at most eight.
fn Cursor::le(self : Cursor, width : Int32) -> UInt64 raise @types.DataError {
  if self.left() < width {
    raise self.bad("the bytes end inside a value")
  }
  let mut value : UInt64 = 0UL
  for i in 0..<width {
    value = value | (self.bytes[self.pos + i].to_uint64() << (8 * i))
  }
  self.pos = self.pos + width
  value
}

///|
/// A big-endian unsigned integer of `width` bytes, at most eight.
fn Cursor::be(self : Cursor, width : Int32) -> UInt64 raise @types.DataError {
  if self.left() < width {
    raise self.bad("the bytes end inside a value")
  }
  let mut value : UInt64 = 0UL
  for i in 0..<width {
    value = (value << 8) | self.bytes[self.pos + i].to_uint64()
  }
  self.pos = self.pos + width
  value
}

///|
/// The next `count` bytes, which must all be there.
fn Cursor::take(self : Cursor, count : Int32) -> Bytes raise @types.DataError {
  if count < 0 || count > self.left() {
    raise self.bad("the bytes end inside a value")
  }
  let out = self.bytes
    .exact_view(start=self.pos, end=self.pos + count)
    .to_owned()
  self.pos = self.pos + count
  out
}

///|
/// One decoded field of a message: its number and wire type, its value —
/// `int` for a varint or a fixed integer, `bytes` for a length-delimited
/// one — and the offset of its first value byte in the file, for the
/// refusals.
priv struct Field {
  num : Int32
  wire : Int32
  int : UInt64
  bytes : Bytes
  at : Int32
}

///|
/// The fields of the message in `bytes`, whose first byte is at `at` of
/// the file, in the order spelled. Raises `ParseError`, naming the byte,
/// for a tag or a value the bytes cut short, for a field number of zero
/// or past the format's range, and for the group wire types, which no
/// writer of this format emits.
fn message(
  bytes : Bytes,
  at : Int32,
  what : String,
) -> Array[Field] raise @types.DataError {
  let c = cursor(bytes, at, what)
  let out : Array[Field] = []
  while c.pos < bytes.length() {
    let tag_at = c.offset()
    let tag = c.varint()
    // The format's field numbers end below 2^29, so a tag past 32 bits
    // names none of them.
    if tag > 0xFFFF_FFFFUL {
      raise bad(tag_at, "\{what} holds a field tag past 32 bits")
    }
    let num = (tag >> 3).to_int()
    let wire = (tag & 7UL).to_int()
    if num == 0 {
      raise bad(tag_at, "\{what} holds a field of number zero")
    }
    let value_at = c.offset()
    match wire {
      0 => out.push({ num, wire, int: c.varint(), bytes: b"", at: value_at, })
      1 | 5 =>
        out.push({
          num,
          wire,
          int: c.le(if wire == 1 { 8 } else { 4 }),
          bytes: b"",
          at: value_at,
        })
      2 => {
        let len_at = c.offset()
        let len = c.varint()
        if len > c.left().to_uint64() {
          let error = bad(
            len_at,
            "\{what}: a field of \{len} bytes runs past the message's end",
          )
          raise error
        }
        out.push({
          num,
          wire,
          int: 0UL,
          bytes: c.take(len.to_int()),
          at: value_at,
        })
      }
      _ =>
        raise bad(tag_at, "\{what} holds a field of wire type \{wire}, a group")
    }
  }
  out
}

///|
/// The refusal for a field that arrives in a wire type its number never
/// carries: no writer spells one field two ways.
fn wrong_wire(field : Field, what : String) -> @types.DataError {
  bad(
    field.at,
    "\{what}: field \{field.num} arrives in wire type \{field.wire}",
  )
}

///|
/// The varint fields of number `num`, in the order spelled.
fn varints(
  fields : Array[Field],
  num : Int32,
  what : String,
) -> Array[UInt64] raise @types.DataError {
  let out : Array[UInt64] = []
  for field in fields {
    if field.num == num {
      if field.wire != 0 {
        raise wrong_wire(field, what)
      }
      out.push(field.int)
    }
  }
  out
}

///|
/// The length-delimited fields of number `num`, in the order spelled.
fn blobs(
  fields : Array[Field],
  num : Int32,
  what : String,
) -> Array[Field] raise @types.DataError {
  let out : Array[Field] = []
  for field in fields {
    if field.num == num {
      if field.wire != 2 {
        raise wrong_wire(field, what)
      }
      out.push(field)
    }
  }
  out
}

///|
/// A repeated integer field, packed into one run of varints or spelled as
/// a varint each: both spellings are the field's.
fn packed_ints(
  fields : Array[Field],
  num : Int32,
  what : String,
) -> Array[UInt64] raise @types.DataError {
  let out : Array[UInt64] = []
  for field in fields {
    if field.num == num {
      match field.wire {
        0 => out.push(field.int)
        2 => {
          let c = cursor(field.bytes, field.at, what)
          while c.pos < field.bytes.length() {
            out.push(c.varint())
          }
        }
        _ => raise wrong_wire(field, what)
      }
    }
  }
  out
}

///|
/// The last varint field of number `num`, or `None` when the message does
/// not carry it.
fn int_field(
  fields : Array[Field],
  num : Int32,
  what : String,
) -> UInt64? raise @types.DataError {
  let found = varints(fields, num, what)
  found.get(found.length() - 1)
}

///|
/// The last length-delimited field of number `num`, or `None`.
fn blob_field(
  fields : Array[Field],
  num : Int32,
  what : String,
) -> Field? raise @types.DataError {
  let found = blobs(fields, num, what)
  found.get(found.length() - 1)
}

///|
/// A 64-bit count, length or offset from a varint: one past what a
/// signed count holds refuses, naming the byte.
fn count64(
  u : UInt64,
  at : Int32,
  what : String,
  name : String,
) -> Int64 raise @types.DataError {
  if u > 0x7FFF_FFFF_FFFF_FFFFUL {
    let error = bad(
      at,
      "\{what}: \{a(name)} \{name} of \{u}, past what a 64-bit count holds",
    )
    raise error
  }
  u.reinterpret_as_int64()
}

///|
/// A 32-bit count from a varint: one past 32 bits refuses, naming the byte.
fn count32(
  u : UInt64,
  at : Int32,
  what : String,
  name : String,
) -> Int32 raise @types.DataError {
  if u > 0x7FFF_FFFFUL {
    let error = bad(at, "\{what}: \{a(name)} \{name} of \{u}, past 32 bits")
    raise error
  }
  u.to_int()
}
