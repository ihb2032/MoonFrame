// The columns: each type's values read from its streams and mapped to
// cells. A column is read for as many positions as its parent asks for —
// a row of the stripe, a present struct's field, a list's element — and
// its PRESENT stream says which of them hold a value: only those are read
// from the data streams, and the others are null.

///|
/// `count` values of the column of type `id`, one for each position its
/// parent asks for. `Scalar::Null` where the column's PRESENT stream has
/// no bit; otherwise what its data streams hold. `path` is the column's
/// way from its top-level field, the words a refusal names it by.
fn values(
  stripe : Stripe,
  id : Int32,
  count : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  if count == 0 {
    return []
  }
  let (cell, _) = plan(stripe.layout, id, path)
  let (kind, _, _) = stripe.encoding(id, path)
  if (kind == 1 || kind == 3) && !(cell is CString) {
    let error = refuse(
      "column \"\{path}\" is not a string and carries the DICTIONARY encoding",
    )
    raise error
  }
  // A struct has no data of its own to encode: the format spells its
  // encoding DIRECT, and every reader of the format asks for that one.
  if kind != 0 && cell is CStruct(_) {
    let error = refuse(
      "column \"\{path}\" is a STRUCT and carries encoding \{kind}, where the format spells DIRECT",
    )
    raise error
  }
  let present = present_bits(stripe, id, count)
  let mut present_count = 0
  for flag in present {
    if flag {
      present_count = present_count + 1
    }
  }
  let decoded = decode(stripe, id, cell, present_count, path)
  scatter(decoded, present)
}

///|
/// The values of a top-level column over one stripe, one a row. The root
/// struct is a column of its own: when the stripe lists a PRESENT stream
/// for it, its fields hold a value only for the rows it holds, and their
/// streams are consumed for those rows alone; a row the root does not
/// hold is null in every column. Most writers list none, and every row
/// holds one.
fn column_values(
  stripe : Stripe,
  id : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  match stripe.find(Present, 0) {
    None => values(stripe, id, stripe.rows, path)
    Some(stream) => {
      let present = boolean_rle(stripe.open(stream), stripe.rows)
      let mut count = 0
      for flag in present {
        if flag {
          count = count + 1
        }
      }
      scatter(values(stripe, id, count, path), present)
    }
  }
}

///|
/// The decoded values laid over the positions that hold one; the others
/// are null.
fn scatter(
  decoded : Array[@types.Scalar],
  present : Array[Bool],
) -> Array[@types.Scalar] {
  let out : Array[@types.Scalar] = []
  let mut next = 0
  for flag in present {
    if flag {
      out.push(decoded[next])
      next = next + 1
    } else {
      out.push(@types.Scalar::Null)
    }
  }
  out
}

///|
/// Which of a column's `count` positions hold a value: one bit each from
/// its PRESENT stream, or every one when the stripe lists no such stream.
fn present_bits(
  stripe : Stripe,
  id : Int32,
  count : Int32,
) -> Array[Bool] raise @types.DataError {
  match stripe.find(Present, id) {
    None => Array::make(count, true)
    Some(stream) => boolean_rle(stripe.open(stream), count)
  }
}

///|
/// The `n` present values of a column, each under its cell kind.
fn decode(
  stripe : Stripe,
  id : Int32,
  cell : Cell,
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  match cell {
    CBool =>
      boolean_rle(stripe.required(Data, id, n), n).map(flag => {
        @types.Scalar::Bool(flag)
      })
    CByte => {
      let bytes : Array[Byte] = []
      byte_rle(stripe.required(Data, id, n), n, bytes)
      bytes.map(b => @types.Scalar::Int(signed_byte(b)))
    }
    CInt =>
      integers(stripe, Data, id, n, path, true).map(v => @types.Scalar::Int(v))
    CDate =>
      integers(stripe, Data, id, n, path, true).map(v => @types.Scalar::Date(v))
    CFloat => floats(stripe, id, n, 4)
    CDouble => floats(stripe, id, n, 8)
    CString => strings(stripe, id, n, path)
    CTimestamp => timestamps(stripe, id, n, path)
    CDecimalLong => decimals_long(stripe, id, n, path)
    CDecimal => decimals(stripe, id, n, path)
    CList(sub) => lists(stripe, id, sub, n, path)
    CStruct(subs, names) => structs(stripe, subs, names, n, path)
  }
}

///|
/// The `n` values of an integer stream: read under the column's encoding,
/// zigzag coded when the stream is signed and plain when it is not.
fn integers(
  stripe : Stripe,
  kind : StreamKind,
  id : Int32,
  n : Int32,
  path : String,
  signed : Bool,
) -> Array[Int64] raise @types.DataError {
  let (_, rle, _) = stripe.encoding(id, path)
  rle.ints(stripe.required(kind, id, n), signed, n)
}

///|
/// The integer a BYTE column's byte names: a byte run length stream
/// carries it signed, its top bit the sign.
fn signed_byte(b : Byte) -> Int64 {
  if b.to_int() >= 128 {
    b.to_int64() - 256L
  } else {
    b.to_int64()
  }
}

///|
/// The `n` values of a float column: little-endian IEEE 754, `width` bytes
/// each; a 32-bit one widened to the double that holds it exactly.
fn floats(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  width : Int32,
) -> Array[@types.Scalar] raise @types.DataError {
  let c = stripe.required(Data, id, n)
  let out : Array[@types.Scalar] = []
  for _ in 0..<n {
    if width == 4 {
      out.push(
        @types.Scalar::Float(@types.float32_bits_to_double(c.le(4).to_uint())),
      )
    } else {
      out.push(@types.Scalar::Float(c.le(8).reinterpret_as_double()))
    }
  }
  out
}

///|
/// One string of a column: its bytes decoded strictly as UTF-8.
fn text(
  c : Cursor,
  bytes : Bytes,
  path : String,
) -> String raise @types.DataError {
  @utf8.decode(bytes) catch {
    _ =>
      raise bad(
        c.offset() - bytes.length(),
        "\{c.what}: a string of column \"\{path}\" not well-formed as UTF-8",
      )
  }
}

///|
/// The bytes a string stream's lengths name in all: a negative length
/// refuses, and a sum past what a signed count holds is held at the top,
/// for the check against the stream to refuse.
fn string_lengths(
  lengths : Array[Int64],
  c : Cursor,
  path : String,
) -> Int64 raise @types.DataError {
  let mut total = 0L
  for len in lengths {
    if len < 0L {
      raise c.bad("a string of column \"\{path}\" has a length of \{len} bytes")
    }
    if len > 0x7FFF_FFFF_FFFF_FFFFUL.reinterpret_as_int64() - total {
      total = 0x7FFF_FFFF_FFFF_FFFFUL.reinterpret_as_int64()
    } else {
      total = total + len
    }
  }
  total
}

///|
/// The `n` present values of a string, a varchar or a char column: direct
/// under DIRECT and DIRECT_V2, through a dictionary under DICTIONARY and
/// DICTIONARY_V2.
fn strings(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  let (kind, rle, size) = stripe.encoding(id, path)
  if kind == 1 || kind == 3 {
    dictionary_strings(stripe, id, n, path, rle, size)
  } else {
    direct_strings(stripe, id, n, path, rle)
  }
}

///|
/// Direct strings: a LENGTH stream with each value's byte length, then
/// the UTF-8 bytes of them all, one after the other, in the DATA stream —
/// listed even when every string is empty, as every writer lists it.
fn direct_strings(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  path : String,
  rle : Rle,
) -> Array[@types.Scalar] raise @types.DataError {
  let lengths_at = stripe.required(Length, id, n)
  let lengths = rle.ints(lengths_at, false, n)
  let total = string_lengths(lengths, lengths_at, path)
  let c = stripe.required(Data, id, n)
  if total > c.left().to_int64() {
    let error = c.bad(
      "the lengths of column \"\{path}\" name \{total} bytes and the stream holds \{c.left()}",
    )
    raise error
  }
  let out : Array[@types.Scalar] = []
  for len in lengths {
    out.push(@types.Scalar::String(text(c, c.take(len.to_int()), path)))
  }
  out
}

///|
/// Dictionary strings: the dictionary's entries, each a length in the
/// LENGTH stream and its bytes in the DICTIONARY_DATA stream; then an
/// index a present value, in the DATA stream.
fn dictionary_strings(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  path : String,
  rle : Rle,
  size : Int64,
) -> Array[@types.Scalar] raise @types.DataError {
  if size > 2147483647L {
    let error = bad(
      stripe.at,
      "the dictionary of column \"\{path}\" declares \{size} entries, past what a column holds",
    )
    raise error
  }
  let count = size.to_int()
  let entries : Array[String] = []
  if count > 0 {
    let lengths_at = stripe.required_for(
      Length,
      id,
      count,
      "dictionary entry",
      many="dictionary entries",
    )
    let lengths = rle.ints(lengths_at, false, count)
    let total = string_lengths(lengths, lengths_at, path)
    let c = stripe.required_for(
      Dictionary,
      id,
      count,
      "dictionary entry",
      many="dictionary entries",
    )
    if total > c.left().to_int64() {
      let error = c.bad(
        "the \{count} entries of the dictionary of column \"\{path}\" name \{total} bytes and the stream holds \{c.left()}",
      )
      raise error
    }
    for len in lengths {
      entries.push(text(c, c.take(len.to_int()), path))
    }
  }
  let data = stripe.required(Data, id, n)
  let indices = rle.ints(data, false, n)
  let out : Array[@types.Scalar] = []
  for index in indices {
    if index < 0L || index >= size {
      let error = data.bad(
        "\{a("index")} index of \{index} into the \{count} entries of the dictionary of column \"\{path}\"",
      )
      raise error
    }
    out.push(@types.Scalar::String(entries[index.to_int()]))
  }
  out
}

///|
/// The day ORC timestamps count their seconds from: 2015-01-01.
const ORC_EPOCH : Int64 = 1420070400L

///|
/// The ends of a signed 64-bit count.
const I64_MAX : Int64 = 0x7FFF_FFFF_FFFF_FFFFL

///|
const I64_MIN : Int64 = -0x8000_0000_0000_0000L

///|
/// Ten to the `power`, for the powers of ten up to 10^8 a nanosecond
/// count's stripped zeros name.
fn ten_to(power : Int32) -> Int64 {
  let mut value = 1L
  for _ in 0..<power {
    value = value * 10L
  }
  value
}

///|
/// The `n` present values of a timestamp column: the DATA stream its
/// seconds after 2015-01-01 as a signed run length stream, the SECONDARY
/// stream its nanoseconds as an unsigned one, with the trailing zeros
/// stripped and their count kept in the low three bits. A writer may
/// leave an instant before its second as seconds toward zero and a
/// negative remainder, so the instant is the sum of the two. Raises
/// `Unsupported` for a nanosecond remainder, which a microsecond timestamp
/// cannot carry, and for an instant past the ends of a 64-bit microsecond
/// count; `ParseError` for a nanosecond count past 64 bits.
fn timestamps(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  let seconds = integers(stripe, Data, id, n, path, true)
  let packed = integers(stripe, Secondary, id, n, path, false)
  let out : Array[@types.Scalar] = []
  for i in 0..<n {
    let zeros = packed[i] & 7L
    let mantissa = packed[i] >> 3
    let factor = if zeros == 0L { 1L } else { ten_to(zeros.to_int() + 1) }
    if mantissa > I64_MAX / factor || mantissa < I64_MIN / factor {
      let error = bad(
        stripe.at,
        "stripe \{stripe.index}: the SECONDARY stream of column \{id} holds a nanosecond count past 64 bits",
      )
      raise error
    }
    let nanos = mantissa * factor
    if nanos % 1000L != 0L {
      let error = refuse(
        "column \"\{path}\" holds a timestamp with a nanosecond remainder, \{nanos} ns in its second, which a microsecond timestamp cannot carry",
      )
      raise error
    }
    out.push(@types.Scalar::Timestamp(micros(seconds[i], nanos, path)))
  }
  out
}

///|
/// The microseconds since 1970-01-01 of a timestamp: its seconds after
/// 2015-01-01 and its (possibly negative) nanoseconds. Raises
/// `Unsupported` for an instant past the ends of a 64-bit microsecond
/// count. The magnitude is taken in the unsigned domain, so the ends of
/// the count are reached without a wrap.
fn micros(
  orc_seconds : Int64,
  nanos : Int64,
  path : String,
) -> Int64 raise @types.DataError {
  let past = refuse(
    "column \"\{path}\" holds a timestamp past the microseconds a 64-bit count holds",
  )
  if orc_seconds > I64_MAX - ORC_EPOCH || orc_seconds < I64_MIN + ORC_EPOCH {
    raise past
  }
  let seconds = orc_seconds + ORC_EPOCH
  // Beyond this many seconds no remainder brings the instant back into
  // the count, and the product below would leave the unsigned domain.
  if seconds > 9223372036855L || seconds < -9223372036855L {
    raise past
  }
  let part = nanos / 1000L
  let negative = seconds < 0L || (seconds == 0L && part < 0L)
  let base = (if seconds < 0L {
      0UL - seconds.reinterpret_as_uint64()
    } else {
      seconds.reinterpret_as_uint64()
    }) *
    1000000UL
  let part_magnitude = if part < 0L {
    0UL - part.reinterpret_as_uint64()
  } else {
    part.reinterpret_as_uint64()
  }
  let total = if seconds == 0L {
    part_magnitude
  } else if (seconds < 0L) == (part < 0L) || part == 0L {
    base + part_magnitude
  } else {
    base - part_magnitude
  }
  let ceiling = if negative {
    9223372036854775808UL
  } else {
    9223372036854775807UL
  }
  if total > ceiling {
    raise past
  }
  if negative {
    (0UL - total).reinterpret_as_int64()
  } else {
    total.reinterpret_as_int64()
  }
}

///|
/// The unscaled integer of one decimal as an unbounded zigzag varint: its
/// magnitude as a low and a high 64-bit half, and its sign. A varint
/// past 128 bits — the width of the format's widest precision, 38 —
/// raises `Unsupported` naming the column.
fn Cursor::decimal(
  self : Cursor,
  path : String,
) -> (UInt64, UInt64, Bool) raise @types.DataError {
  let mut low = 0UL
  let mut high = 0UL
  for i in 0..<19 {
    let b = self.byte()
    let payload = b & 0x7F
    if i == 18 {
      if payload > 3 {
        raise refuse("column \"\{path}\" holds a decimal wider than 128 bits")
      }
      high = high | (payload.to_uint64() << 62)
    } else if i < 9 {
      low = low | (payload.to_uint64() << (7 * i))
    } else if i == 9 {
      low = low | (payload.to_uint64() << 63)
      high = high | (payload.to_uint64() >> 1)
    } else {
      high = high | (payload.to_uint64() << (7 * i - 64))
    }
    if b < 0x80 {
      let negative = (low & 1UL) == 1UL
      let shifted_low = (low >> 1) | (high << 63)
      let shifted_high = high >> 1
      if negative {
        // A negative value's magnitude is one more than its shifted
        // code: two's complement, the carry named by the low half's wrap.
        let sum = shifted_low + 1UL
        let carry = if sum == 0UL { 1UL } else { 0UL }
        return (sum, shifted_high + carry, negative)
      }
      return (shifted_low, shifted_high, negative)
    }
  }
  raise refuse("column \"\{path}\" holds a decimal wider than 128 bits")
}

///|
/// A 128-bit magnitude, as its low and high 64-bit halves, over ten: the
/// quotient's two halves and the remainder.
fn over_ten(low : UInt64, high : UInt64) -> (UInt64, UInt64, UInt64) {
  let limbs : Array[UInt64] = [
    high >> 32,
    high & 0xFFFF_FFFFUL,
    low >> 32,
    low & 0xFFFF_FFFFUL,
  ]
  let mut remainder : UInt64 = 0UL
  for i in 0..<4 {
    let current = (remainder << 32) | limbs[i]
    limbs[i] = current / 10UL
    remainder = current % 10UL
  }
  ((limbs[2] << 32) | limbs[3], (limbs[0] << 32) | limbs[1], remainder)
}

///|
/// How many decimal digits a 128-bit magnitude has; none for zero.
fn digits128(low : UInt64, high : UInt64) -> Int32 {
  let mut count = 0
  let mut rest_low = low
  let mut rest_high = high
  while rest_low != 0UL || rest_high != 0UL {
    let (q_low, q_high, _) = over_ten(rest_low, rest_high)
    rest_low = q_low
    rest_high = q_high
    count = count + 1
  }
  count
}

///|
/// How many zeros a 128-bit magnitude ends in; none for zero.
fn zeros128(low : UInt64, high : UInt64) -> Int32 {
  let mut count = 0
  let mut rest_low = low
  let mut rest_high = high
  let mut go = rest_low != 0UL || rest_high != 0UL
  while go {
    let (q_low, q_high, remainder) = over_ten(rest_low, rest_high)
    if remainder == 0UL {
      rest_low = q_low
      rest_high = q_high
      count = count + 1
    } else {
      go = false
    }
  }
  count
}

///|
/// One decimal cell: its unscaled magnitude under its scale. The library's
/// decimal holds 34 significant digits and a quantum exponent from -6176
/// to 6144; a value that rounds on the way into them, or that does not
/// fit at all, raises `Unsupported` naming the column rather than being
/// approximated.
fn decimal_cell(
  low : UInt64,
  high : UInt64,
  negative : Bool,
  scale : Int64,
  path : String,
) -> @types.Scalar raise @types.DataError {
  if scale < -6144L || scale > 6209L {
    let error = refuse(
      "column \"\{path}\" holds a decimal of scale \{scale}, outside what the library's decimal holds",
    )
    raise error
  }
  if low != 0UL || high != 0UL {
    let digits = digits128(low, high)
    // The magnitude's trailing zeros are a power of ten of their own, so
    // the scale left to apply is the column's less those.
    let zeros = zeros128(low, high).to_int64()
    let significant = digits.to_int64() - zeros
    // A negative scale scales the value up past its own digits; a
    // positive one more than the format's floor scales it under them.
    if (scale < 0L && significant + zeros - scale > 34L) ||
      zeros - scale < -6176L {
      let error = refuse(
        "column \"\{path}\" holds a decimal of \{counted(significant, "digit")} at scale \{scale}, which the library's decimal cannot hold exactly",
      )
      raise error
    }
  }
  // The scale is within the bounds checked above, so it is an `Int`.
  match @types.Dec128::of_unscaled(low, high, negative~, scale=scale.to_int()) {
    Some(value) => @types.Scalar::Decimal(value)
    None =>
      raise refuse(
        "column \"\{path}\" holds a decimal of more than 34 significant digits, which the library's decimal cannot carry",
      )
  }
}

///|
/// The `n` present values of a decimal: its unscaled integer as an
/// unbounded varint in the DATA stream and its scale a value each in the
/// SECONDARY stream, the first format's spelling.
fn decimals(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  let data = stripe.required(Data, id, n)
  let (_, rle, _) = stripe.encoding(id, path)
  let scales = rle.ints(stripe.required(Secondary, id, n), true, n)
  let out : Array[@types.Scalar] = []
  for i in 0..<n {
    let (low, high, negative) = data.decimal(path)
    out.push(decimal_cell(low, high, negative, scales[i], path))
  }
  out
}

///|
/// The `n` present values of a decimal of precision up to 18 in the
/// UNSTABLE-PRE-2.0 spelling: its unscaled integers as a version 2 signed
/// run length stream, at the type's own scale.
fn decimals_long(
  stripe : Stripe,
  id : Int32,
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  ignore(stripe.encoding(id, path))
  let unscaled = V2.ints(stripe.required(Data, id, n), true, n)
  let scale = stripe.layout.types[id].scale
  let out : Array[@types.Scalar] = []
  for value in unscaled {
    let negative = value < 0L
    let bits = value.reinterpret_as_uint64()
    let magnitude = if negative { 0UL - bits } else { bits }
    out.push(decimal_cell(magnitude, 0UL, negative, scale, path))
  }
  out
}

///|
/// The `n` present values of a list column: each list's length in the
/// LENGTH stream, then the elements of them all in the child column's own
/// streams, one after the other. The elements are charged against the
/// cells the stripe's streams can spell, before one is built.
fn lists(
  stripe : Stripe,
  id : Int32,
  sub : Int32,
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  let (_, rle, _) = stripe.encoding(id, path)
  let lengths_at = stripe.required(Length, id, n)
  let lengths = rle.ints(lengths_at, false, n)
  let mut total = 0L
  for len in lengths {
    if len < 0L {
      raise lengths_at.bad(
        "\{a("list")} list of column \"\{path}\" has a length of \{len}",
      )
    }
    if len > 2147483647L - total {
      total = 2147483648L
    } else {
      total = total + len
    }
  }
  if total > 2147483647L {
    let error = bad(
      stripe.at,
      "the lists of column \"\{path}\" name \{total} items in stripe \{stripe.index}, past what a column holds",
    )
    raise error
  }
  if total > stripe.budget {
    let error = bad(
      stripe.layout.footer_at,
      "the lists of column \"\{path}\" name \{total} items in stripe \{stripe.index}, more than the densest encoding spells over its streams",
    )
    raise error
  }
  stripe.budget = stripe.budget - total
  let children = values(stripe, sub, total.to_int(), "\{path}[]")
  let out : Array[@types.Scalar] = []
  let mut at = 0
  for len in lengths {
    let cells : Array[@types.Scalar] = []
    let end = at + len.to_int()
    for i in at..<end {
      cells.push(children[i])
    }
    out.push(@types.Scalar::List(@types.ListValue::ListValue(cells)))
    at = end
  }
  out
}

///|
/// The `n` present values of a struct column: one value a field, each
/// read for `n` positions under the field's own PRESENT stream, then
/// assembled field by field in the struct's order.
fn structs(
  stripe : Stripe,
  subs : Array[Int32],
  names : Array[String],
  n : Int32,
  path : String,
) -> Array[@types.Scalar] raise @types.DataError {
  let fields : Array[Array[@types.Scalar]] = []
  for i, _ in subs {
    fields.push(values(stripe, subs[i], n, "\{path}.\{names[i]}"))
  }
  let out : Array[@types.Scalar] = []
  for row in 0..<n {
    let cells : Array[@types.FieldValue] = []
    for i, _ in subs {
      cells.push(@types.FieldValue::FieldValue(names[i], fields[i][row]))
    }
    out.push(@types.Scalar::Struct(@types.StructValue::StructValue(cells)))
  }
  out
}
