// The binary encoding of a datum: variable-length zigzag counts, the
// little-endian fixed-width numbers, and the length-prefixed strings and
// byte arrays — read through a cursor that refuses to walk past its block
// instead of indexing outside it. A field the read does not keep is
// skipped by advancing over its bytes, never materialised.

///|
/// A cursor over one block's bytes: the block, and how far into it the
/// values read so far reach.
priv struct Cursor {
  bytes : Bytes
  mut at : Int32
}

///|
/// How many bytes of the block are still unread.
fn Cursor::remaining(self : Cursor) -> Int32 {
  self.bytes.length() - self.at
}

///|
/// One byte.
fn Cursor::byte(self : Cursor) -> Int32 raise @types.DataError {
  if self.at < self.bytes.length() {
    let b = self.bytes[self.at].to_int()
    self.at = self.at + 1
    b
  } else {
    raise malformed("a block ends inside a value")
  }
}

///|
/// The next `count` bytes, which must all be there.
fn Cursor::take(self : Cursor, count : Int32) -> Bytes raise @types.DataError {
  if count >= 0 && count <= self.remaining() {
    let out = self.bytes
      .exact_view(start=self.at, end=self.at + count)
      .to_owned()
    self.at = self.at + count
    out
  } else {
    raise malformed("a block ends inside a value")
  }
}

///|
/// A variable-length integer: seven payload bits a byte, least
/// significant first, the top bit of every byte but the last saying one
/// more follows. Ten bytes hold 64 bits, and the tenth may carry only the
/// lowest of them.
fn Cursor::varint(self : Cursor) -> UInt64 raise @types.DataError {
  let mut result : UInt64 = 0UL
  for i in 0..<9 {
    let b = self.byte()
    result = result | ((b & 0x7F).to_uint64() << (7 * i))
    if (b & 0x80) == 0 {
      return result
    }
  }
  // The tenth byte: the sixty-third bit alone, with nothing after it.
  let last = self.byte()
  if last > 1 {
    raise malformed("a variable-length integer wider than 64 bits")
  }
  result | (last.to_uint64() << 63)
}

///|
/// A signed 64-bit count, zigzag-encoded.
fn Cursor::long(self : Cursor) -> Int64 raise @types.DataError {
  let u = self.varint()
  let value = (u >> 1).reinterpret_as_int64()
  if (u & 1UL) == 0UL {
    value
  } else {
    value ^ -1L
  }
}

///|
/// A signed 32-bit value: a count that must sit inside 32 bits.
fn Cursor::int(self : Cursor) -> Int32 raise @types.DataError {
  let v = self.long()
  if v < -2147483648L || v > 2147483647L {
    raise malformed("an int encoded outside 32 bits")
  }
  v.to_int()
}

///|
/// A byte length: not negative, and no longer than the bytes still
/// unread — so a length can never ask for what the block does not hold.
fn Cursor::length(self : Cursor) -> Int32 raise @types.DataError {
  let v = self.long()
  if v < 0L || v > self.remaining().to_int64() {
    raise malformed("a length of \{v} bytes that the block cannot hold")
  }
  v.to_int()
}

///|
/// A little-endian unsigned integer of `width` bytes, at most eight.
fn Cursor::le(self : Cursor, width : Int32) -> UInt64 raise @types.DataError {
  let mut v : UInt64 = 0UL
  for i in 0..<width {
    v = v | (self.byte().to_uint64() << (8 * i))
  }
  v
}

///|
/// A 32-bit float, widened to the `Double` that holds it exactly.
fn Cursor::float32(self : Cursor) -> Double raise @types.DataError {
  @types.float32_bits_to_double(self.le(4).to_uint())
}

///|
/// A 64-bit float.
fn Cursor::double(self : Cursor) -> Double raise @types.DataError {
  self.le(8).reinterpret_as_double()
}

///|
/// A string: its byte length, then its UTF-8 bytes.
fn Cursor::string(self : Cursor) -> String raise @types.DataError {
  let bytes = self.take(self.length())
  @utf8.decode(bytes) catch {
    _ => raise malformed("a string that is not valid UTF-8")
  }
}

///|
/// How many collection items — a list's elements, a map's entries — one
/// file may hold, so a small file cannot ask for an unbounded walk of
/// nested collections.
const MAX_ITEMS : Int64 = 50_000_000L

///|
/// The collection items read so far, against `MAX_ITEMS`.
priv struct Budget {
  mut items : Int64
}

///|
/// Count `count` more collection items, refusing a file past the bound.
fn Budget::charge(self : Budget, count : Int64) -> Unit raise @types.DataError {
  if count > MAX_ITEMS - self.items {
    raise malformed("more than \{MAX_ITEMS} collection items in one file")
  }
  self.items = self.items + count
}

///|
/// A collection block's item count as the encoding spells it: a positive
/// count, or a negative count naming a block whose byte size follows and
/// is stepped over on the way past.
fn Cursor::block_count(self : Cursor) -> Int64 raise @types.DataError {
  let declared = self.long()
  if declared == -9223372036854775808L {
    raise malformed("a collection block of \{declared} items")
  }
  if declared < 0L {
    ignore(self.long())
    -declared
  } else {
    declared
  }
}

///|
/// The value one datum encodes to under a type the mapping carries,
/// read at `path` — the field's way from the record, for the refusals.
fn decode_value(
  cur : Cursor,
  ty : CellType,
  budget : Budget,
  path : String,
) -> @types.Scalar raise @types.DataError {
  match ty {
    CNull => @types.Scalar::Null
    CBoolean => @types.Scalar::Bool(cur.byte() != 0)
    CIntPlain => @types.Scalar::Int(cur.int().to_int64())
    CIntDate => @types.Scalar::Date(cur.int().to_int64())
    CIntTimeMillis => millis_past_midnight(cur.int(), path)
    CLongPlain => @types.Scalar::Int(cur.long())
    CLongTimeMicros => micros_past_midnight(cur.long(), path)
    CLongTimestampMillis => millis_since_epoch(cur.long(), path)
    CLongTimestampMicros => @types.Scalar::Timestamp(cur.long())
    CFloat => @types.Scalar::Float(cur.float32())
    CDouble => @types.Scalar::Float(cur.double())
    CDecimalBytes(shape) => decimal_value(cur.take(cur.length()), shape, path)
    CDecimalFixed(size, shape) => decimal_value(cur.take(size), shape, path)
    CString => @types.Scalar::String(cur.string())
    CEnum(symbols) =>
      match symbols.get(cur.int()) {
        Some(symbol) => @types.Scalar::String(symbol)
        None =>
          raise malformed("an enum index outside its symbols at \"\{path}\"")
      }
    CRecord(fields) => {
      let cells : Array[@types.FieldValue] = []
      for field in fields {
        cells.push(
          @types.FieldValue::FieldValue(
            field.name,
            decode_value(cur, field.ty, budget, "\{path}.\{field.name}"),
          ),
        )
      }
      @types.Scalar::Struct(@types.StructValue::StructValue(cells))
    }
    CArray(items) => {
      let cells : Array[@types.Scalar] = []
      while true {
        let count = cur.block_count()
        if count == 0L {
          break
        }
        budget.charge(count)
        for _ in 0L..<count {
          cells.push(decode_value(cur, items, budget, path))
        }
      }
      @types.Scalar::List(@types.ListValue::ListValue(cells))
    }
    COptional(null_at, inner) => {
      let index = cur.int()
      if index != 0 && index != 1 {
        raise malformed(
          "a union index \{index} outside its branches at \"\{path}\"",
        )
      }
      if index == null_at {
        @types.Scalar::Null
      } else {
        decode_value(cur, inner, budget, path)
      }
    }
  }
}

///|
/// A time of day as milliseconds past midnight, read as the instant on
/// the epoch day — the library has no time-of-day type, and the cell
/// still prints as a clock reading. A count outside one day is not a
/// time of day.
fn millis_past_midnight(
  v : Int32,
  path : String,
) -> @types.Scalar raise @types.DataError {
  if v < 0 || v >= 86_400_000 {
    raise malformed("a time-millis of \{v} ms at \"\{path}\", outside one day")
  }
  @types.Scalar::Timestamp(v.to_int64() * 1000L)
}

///|
/// A time of day as microseconds past midnight, read as the instant on
/// the epoch day.
fn micros_past_midnight(
  v : Int64,
  path : String,
) -> @types.Scalar raise @types.DataError {
  if v < 0L || v >= 86_400_000_000L {
    raise malformed("a time-micros of \{v} µs at \"\{path}\", outside one day")
  }
  @types.Scalar::Timestamp(v)
}

///|
/// An instant as milliseconds since the epoch, widened to the library's
/// microseconds. 2^63 microseconds is 9,223,372,036,854 milliseconds and
/// a fraction; a count past it could not be widened without wrapping.
fn millis_since_epoch(
  v : Int64,
  path : String,
) -> @types.Scalar raise @types.DataError {
  if v < -9223372036854L || v > 9223372036854L {
    raise malformed(
      "a timestamp-millis of \{v} ms at \"\{path}\", outside the timestamps the library holds",
    )
  }
  @types.Scalar::Timestamp(v * 1000L)
}

///|
/// The decimal a big-endian two's-complement integer of `bytes` carries
/// under a decimal's shape — up to sixteen bytes, the width of a 128-bit
/// integer, which the 38 digits of a precision allow. A cell needing more
/// than 34 significant digits has no exact decimal and is refused.
fn decimal_value(
  bytes : Bytes,
  shape : DecimalShape,
  path : String,
) -> @types.Scalar raise @types.DataError {
  let width = bytes.length()
  if width == 0 {
    return @types.Scalar::Decimal(@types.Dec128::zero())
  }
  if width > 16 {
    raise cannot_carry(
      "a decimal cell \{width} bytes wide at \"\{path}\", past the 16 a 128-bit integer holds",
    )
  }
  let negative = (bytes[0].to_int() & 0x80) != 0
  // The integer sign-extended to 128 bits: each byte lands in the low and
  // then the high half over a fill of the sign bit.
  let fill : UInt64 = if negative { 0xFFFF_FFFF_FFFF_FFFFUL } else { 0UL }
  let mut hi = fill
  let mut lo = fill
  for i in 0..<width {
    let b = bytes[width - 1 - i].to_int().to_uint64()
    let shift = i % 8 * 8
    let mask = 0xFFFF_FFFF_FFFF_FFFFUL ^ (0xFFUL << shift)
    if i < 8 {
      lo = (lo & mask) | (b << shift)
    } else {
      hi = (hi & mask) | (b << shift)
    }
  }
  // A negative integer's magnitude is its two's complement: the halves
  // inverted and raised by one, which carries into the high half when
  // the low half is zero.
  let (mag_lo, mag_hi) = if negative {
    let flipped = lo ^ 0xFFFF_FFFF_FFFF_FFFFUL
    if lo == 0UL {
      (0UL, (hi ^ 0xFFFF_FFFF_FFFF_FFFFUL) + 1UL)
    } else {
      (flipped + 1UL, hi ^ 0xFFFF_FFFF_FFFF_FFFFUL)
    }
  } else {
    (lo, hi)
  }
  match
    @types.Dec128::of_unscaled(mag_lo, mag_hi, negative~, scale=shape.scale) {
    Some(value) => @types.Scalar::Decimal(value)
    None =>
      raise cannot_carry(
        "a decimal cell at \"\{path}\" with more than 34 significant digits",
      )
  }
}

///|
/// Advance over one datum without keeping it — a field of a record the
/// read does not carry. Every byte its encoding spans is stepped over, so
/// the next field starts where the file put it.
fn skip_value(
  cur : Cursor,
  ty : AvroType,
  budget : Budget,
) -> Unit raise @types.DataError {
  match ty {
    // A null datum is encoded as no byte at all.
    TNull => ()
    TBoolean => ignore(cur.byte())
    TInt(_) | TLong(_) => ignore(cur.long())
    TFloat => ignore(cur.take(4))
    TDouble => ignore(cur.take(8))
    TBytes(_) | TString => ignore(cur.take(cur.length()))
    TRecord(fields) =>
      for field in fields {
        skip_value(cur, field.ty, budget)
      }
    TEnum(_) => ignore(cur.int())
    TArray(items) =>
      while true {
        let count = cur.block_count()
        if count == 0L {
          break
        }
        budget.charge(count)
        for _ in 0L..<count {
          skip_value(cur, items, budget)
        }
      }
    TMap(values) =>
      while true {
        let count = cur.block_count()
        if count == 0L {
          break
        }
        budget.charge(count)
        for _ in 0L..<count {
          ignore(cur.take(cur.length()))
          skip_value(cur, values, budget)
        }
      }
    TUnion(branches) =>
      match branches.get(cur.int()) {
        Some(branch) => skip_value(cur, branch, budget)
        None => raise malformed("a union index outside its branches")
      }
    TFixed(size, _) => ignore(cur.take(size))
  }
}

///|
/// Append a variable-length integer.
fn push_varint(buf : Array[Byte], v : UInt64) -> Unit {
  let mut rest = v
  while rest >= 0x80UL {
    buf.push((rest & 0x7FUL).to_byte() | b'\x80')
    rest = rest >> 7
  }
  buf.push(rest.to_byte())
}

///|
/// Append a signed count, zigzag-encoded.
fn push_long(buf : Array[Byte], v : Int64) -> Unit {
  push_varint(buf, ((v << 1) ^ (v >> 63)).reinterpret_as_uint64())
}

///|
/// Append a string: its byte length, then its UTF-8 bytes.
fn push_string(buf : Array[Byte], s : String) -> Unit {
  let bytes = @utf8.encode(s)
  push_long(buf, bytes.length().to_int64())
  for b in bytes {
    buf.push(b)
  }
}

///|
/// Append a 64-bit float, little-endian.
fn push_double(buf : Array[Byte], v : Double) -> Unit {
  let mut bits = v.reinterpret_as_uint64()
  for _ in 0..<8 {
    buf.push((bits & 0xFFUL).to_byte())
    bits = bits >> 8
  }
}

///|
/// Append a big-endian unsigned integer of `width` bytes, one to eight.
fn push_be(buf : Array[Byte], v : UInt64, width : Int32) -> Unit {
  for i = width - 1; i >= 0; i = i - 1 {
    buf.push(((v >> (8 * i)) & 0xFFUL).to_byte())
  }
}

///|
/// Append the magnitude of a 128-bit integer, given as its high and low
/// 64-bit halves, as a big-endian two's-complement integer — negated
/// when `negative` — cut to the encoding's shortest spelling: a leading
/// byte goes while the byte after it says the same sign.
fn push_twos_complement(
  buf : Array[Byte],
  magnitude_hi : UInt64,
  magnitude_lo : UInt64,
  negative~ : Bool,
) -> Unit {
  let mut hi = magnitude_hi
  let mut lo = magnitude_lo
  if negative {
    hi = 0xFFFF_FFFF_FFFF_FFFFUL - hi
    lo = 0xFFFF_FFFF_FFFF_FFFFUL - lo
    lo = lo + 1UL
    if lo == 0UL {
      hi = hi + 1UL
    }
  }
  let all : Array[Byte] = []
  push_be(all, hi, 8)
  push_be(all, lo, 8)
  let sign = all[0].to_int() & 0x80
  let mut start = 0
  while start < 15 &&
        all[start].to_int() == all[0].to_int() &&
        (all[start + 1].to_int() & 0x80) == sign {
    start = start + 1
  }
  for i in start..<16 {
    buf.push(all[i])
  }
}

///|
/// Append one datum: `scalar` under `ty`. A cell whose shape the column's
/// type does not hold is the library's own type mismatch; a type only the
/// reader carries — the writer emits none of them — is refused.
fn encode_value(
  buf : Array[Byte],
  scalar : @types.Scalar,
  ty : CellType,
  path : String,
) -> Unit raise @types.DataError {
  match ty {
    COptional(null_at, inner) =>
      if scalar is @types.Scalar::Null {
        push_long(buf, null_at.to_int64())
      } else {
        push_long(buf, (1 - null_at).to_int64())
        encode_value(buf, scalar, inner, path)
      }
    CNull =>
      if scalar is @types.Scalar::Null {
        ()
      } else {
        mismatch(scalar, "null", path)
      }
    CBoolean => buf.push(if scalar.as_bool() { b'\x01' } else { b'\x00' })
    CIntDate =>
      if scalar is @types.Scalar::Date(days) {
        if days < -2147483648L || days > 2147483647L {
          raise @types.DataError::InvalidOperation(
            "column \"\{path}\" holds a day count \{days}, outside the int a date rides",
          )
        }
        push_long(buf, days)
      } else {
        mismatch(scalar, "date", path)
      }
    CLongPlain => push_long(buf, scalar.as_int())
    CLongTimestampMicros =>
      if scalar is @types.Scalar::Timestamp(micros) {
        push_long(buf, micros)
      } else {
        mismatch(scalar, "timestamp", path)
      }
    CDouble => push_double(buf, scalar.as_float())
    CDecimalBytes(shape) =>
      if scalar is @types.Scalar::Decimal(value) {
        match value.to_unscaled(scale=shape.scale) {
          Some((hi, lo, negative)) => {
            // A bytes value is length-prefixed, its length following the
            // integer's shortest spelling.
            let payload : Array[Byte] = []
            push_twos_complement(payload, hi, lo, negative~)
            push_long(buf, payload.length().to_int64())
            for b in payload {
              buf.push(b)
            }
          }
          None =>
            raise @types.DataError::InvalidOperation(
              "column \"\{path}\" holds the decimal \{value}, which is not a whole number of the column's \{shape.scale} fraction digits or is too wide for a 128-bit integer",
            )
        }
      } else {
        mismatch(scalar, "decimal", path)
      }
    CString => push_string(buf, guarded_text(scalar.as_string()))
    CRecord(fields) =>
      if scalar is @types.Scalar::Struct(value) {
        for field in fields {
          encode_value(
            buf,
            value.get_named(field.name).unwrap_or(@types.Scalar::Null),
            COptional(0, field.ty),
            "\{path}.\{field.name}",
          )
        }
      } else {
        mismatch(scalar, "struct", path)
      }
    CArray(items) =>
      if scalar is @types.Scalar::List(list) {
        // One block of the list's cells, closed by the empty block every
        // non-empty block sequence ends with. The count is the cells'
        // own, read once, so it can never disagree with what follows it —
        // and an empty list is the closing block alone.
        let cells = list.cells()
        if cells.is_empty() {
          push_long(buf, 0L)
        } else {
          push_long(buf, cells.length().to_int64())
          for cell in cells {
            encode_value(buf, cell, COptional(0, items), path)
          }
          push_long(buf, 0L)
        }
      } else {
        mismatch(scalar, "list", path)
      }
    CIntPlain
    | CIntTimeMillis
    | CLongTimeMicros
    | CLongTimestampMillis
    | CFloat
    | CDecimalFixed(_, _)
    | CEnum(_) =>
      raise @types.DataError::InvalidOperation(
        "the Avro writer does not emit the type of \"\{path}\"",
      )
  }
}

///|
/// The refusal for a cell under a column whose type cannot hold it.
fn mismatch(
  scalar : @types.Scalar,
  column : String,
  path : String,
) -> Unit raise @types.DataError {
  raise @types.DataError::InvalidOperation(
    "the Avro writer met a \{scalar.dtype()} cell under a \{column} column at \"\{path}\"",
  )
}

///|
/// The string a cell writes as, or the file writers' own refusal for a
/// lone surrogate: the UTF-8 encoding would not round-trip.
fn guarded_text(s : String) -> String raise @types.DataError {
  match @text.find_unpaired_surrogate(s) {
    Some(_) =>
      raise @types.DataError::InvalidOperation(
        "cannot write an Avro string cell containing an unpaired UTF-16 surrogate: the UTF-8 encoding would not round-trip",
      )
    None => s
  }
}
