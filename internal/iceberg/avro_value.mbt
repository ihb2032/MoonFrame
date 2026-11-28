// Stepping over a datum and reading the ones the plan keeps: the whole
// numbers, strings, id lists and metric-map keys of a manifest entry, and
// the partition values. Every length, count and index comes from the bytes
// and is checked against what remains before it is used.

///|
/// The value of a 32-bit subnormal's least significant bit, 2^-149.
const FLOAT32_UNIT : Double = 1.401298464324817e-45

///|
/// The 32-bit float whose IEEE 754 bits are `bits`, widened to the
/// `Double` that holds every one of its values exactly.
fn float32(bits : UInt32) -> Double {
  let negative = bits >> 31 == 1U
  let exponent = ((bits >> 23) & 0xFFU).reinterpret_as_int()
  let fraction = bits & 0x7FFFFFU
  let magnitude : Double = if exponent == 255 {
    (0x7FF0000000000000UL | (fraction.to_uint64() << 29)).reinterpret_as_double()
  } else if exponent == 0 {
    // Zero, or a subnormal: an integer below 2^23 times the value of the
    // format's least significant bit.
    fraction.to_double() * FLOAT32_UNIT
  } else {
    // A normal: a 24-bit significand over 2^23, times a power of two.
    (0x800000U | fraction).to_double() /
    8388608.0 *
    ((exponent + 896).to_uint64() << 52).reinterpret_as_double()
  }
  if negative {
    -magnitude
  } else {
    magnitude
  }
}

///|
/// Whether the datum is there. A null-union carries an index, which must
/// name one of its two branches; every other type is always present.
fn present(cur : Cursor, ty : AvroType) -> Bool raise @types.DataError {
  match ty {
    AUnion(_) => {
      let start = cur.at
      let index = cur.long()
      if index == 1L {
        true
      } else if index == 0L {
        false
      } else {
        raise malformed(
          "byte \{start} of \{cur.origin}: the union index \{index}, outside its two branches",
        )
      }
    }
    _ => true
  }
}

///|
/// The one type a null-union wraps, or the type itself when it is no union.
fn inner(ty : AvroType) -> AvroType {
  match ty {
    AUnion(wrapped) => wrapped
    other => other
  }
}

///|
/// The refusal for a datum of a type other than the one expected.
fn wrong_type(
  cur : Cursor,
  at : Int32,
  ty : AvroType,
  what : String,
) -> @types.DataError {
  malformed(
    "byte \{at} of \{cur.origin}: \{describe(ty)} where \{what} is expected",
  )
}

///|
/// Advance over the items of an array or of a map's values: block by block
/// until a block of no items closes the collection.
fn skip_items(
  cur : Cursor,
  items : AvroType,
  keyed : Bool,
) -> Unit raise @types.DataError {
  while true {
    let count = cur.block_count()
    if count == 0L {
      break
    }
    for _ in 0L..<count {
      if keyed {
        ignore(cur.long())
      }
      skip(cur, items)
    }
  }
}

///|
/// Advance over one datum without keeping it — a field the reader does not
/// know. Every byte its encoding spans is stepped over, so the next field
/// starts where the file put it.
fn skip(cur : Cursor, ty : AvroType) -> Unit raise @types.DataError {
  match ty {
    ANull => ()
    ABoolean => ignore(cur.byte())
    AInt | ALong => ignore(cur.long())
    AFloat => ignore(cur.take(4))
    ADouble => ignore(cur.take(8))
    ABytes | AString => ignore(cur.take(cur.length()))
    ADecimal(0, _) => ignore(cur.take(cur.length()))
    ADecimal(width, _) => ignore(cur.take(width))
    AFixed(width) => ignore(cur.take(width))
    AEnum => ignore(cur.long())
    ARecord(fields) =>
      for field in fields {
        skip(cur, field.ty)
      }
    AArray(items) => skip_items(cur, items, false)
    AMap(_, value) => skip_items(cur, value, true)
    AUnion(wrapped) => if present(cur, ty) { skip(cur, wrapped) }
  }
}

///|
/// A whole number, `None` for a null. Raises `ParseError` when the datum is
/// of another type.
fn read_long(
  cur : Cursor,
  ty : AvroType,
  what : String,
) -> Int64? raise @types.DataError {
  let at = cur.at
  if !present(cur, ty) {
    return None
  }
  match inner(ty) {
    AInt | ALong => Some(cur.long())
    other => raise wrong_type(cur, at, other, what)
  }
}

///|
/// A string, `None` for a null. Raises `ParseError` when the datum is of
/// another type.
fn read_string(
  cur : Cursor,
  ty : AvroType,
  what : String,
) -> String? raise @types.DataError {
  let at = cur.at
  if !present(cur, ty) {
    return None
  }
  match inner(ty) {
    AString => Some(cur.string())
    other => raise wrong_type(cur, at, other, what)
  }
}

///|
/// The whole numbers a list names, each of its elements optionally null;
/// nothing for a null list. Raises `ParseError` when the datum is not a
/// list of whole numbers.
fn read_ids(
  cur : Cursor,
  ty : AvroType,
  what : String,
) -> Array[Int64] raise @types.DataError {
  let at = cur.at
  if !present(cur, ty) {
    return []
  }
  match inner(ty) {
    AArray(items) => {
      let out : Array[Int64] = []
      while true {
        let count = cur.block_count()
        if count == 0L {
          break
        }
        for _ in 0L..<count {
          match read_long(cur, items, what) {
            Some(id) => out.push(id)
            None => ()
          }
        }
      }
      out
    }
    other => raise wrong_type(cur, at, other, what)
  }
}

///|
/// The keys of a map of column metrics, collected into `ids` — each the
/// field id of a column of the file — with its values stepped over.
/// Nothing is collected for a null map. Raises `ParseError` when the datum
/// is not a map keyed by whole numbers.
fn read_map_ids(
  cur : Cursor,
  ty : AvroType,
  what : String,
  ids : Array[Int64],
) -> Unit raise @types.DataError {
  let at = cur.at
  if !present(cur, ty) {
    return
  }
  match inner(ty) {
    AMap(AInt, value) | AMap(ALong, value) =>
      while true {
        let count = cur.block_count()
        if count == 0L {
          break
        }
        for _ in 0L..<count {
          push_id(ids, cur.long())
          skip(cur, value)
        }
      }
    other => raise wrong_type(cur, at, other, what)
  }
}

///|
/// A primitive datum as a block encodes it, read for a partition value.
/// `VBytes` stands for a datum this reader keeps no value of.
priv enum AvroValue {
  VBool(Bool)
  VLong(Int64)
  VDouble(Double)
  VString(String)
  VDecimal(@types.Dec128, Int64)
  VBytes
}

///|
/// A primitive datum, `None` for a null. Raises `ParseError` when the
/// partition field holds a record, a list or a map, and `Unsupported` for
/// a decimal wider than sixteen bytes or past 34 significant digits.
fn read_scalar(
  cur : Cursor,
  ty : AvroType,
  name : String,
) -> AvroValue? raise @types.DataError {
  let at = cur.at
  if !present(cur, ty) {
    return None
  }
  let what = "the partition field \"\{name}\""
  match inner(ty) {
    ABoolean => Some(VBool(cur.byte() != 0))
    AInt | ALong => Some(VLong(cur.long()))
    AFloat => Some(VDouble(float32(cur.le(4).to_uint())))
    ADouble => Some(VDouble(cur.le(8).reinterpret_as_double()))
    AString => Some(VString(cur.string()))
    ABytes => {
      ignore(cur.take(cur.length()))
      Some(VBytes)
    }
    AFixed(width) => {
      ignore(cur.take(width))
      Some(VBytes)
    }
    ADecimal(0, scale) =>
      Some(VDecimal(decimal_run(cur.take(cur.length()), scale, what), scale))
    ADecimal(width, scale) =>
      Some(VDecimal(decimal_run(cur.take(width), scale, what), scale))
    other => raise wrong_type(cur, at, other, "\{what} holding a primitive")
  }
}

///|
/// The base-10^9 limbs of a magnitude, little-endian, each raised by the
/// next byte of a big-endian integer.
fn limbs_pushed(
  limbs : Array[Int64],
  factor : Int64,
  add : Int64,
) -> Array[Int64] {
  let out : Array[Int64] = []
  let mut carry = add
  for limb in limbs {
    let value = limb * factor + carry
    out.push(value % 1000000000L)
    carry = value / 1000000000L
  }
  if carry > 0L {
    out.push(carry)
  }
  out
}

///|
/// The significant digits of a magnitude held in base-10^9 limbs, without
/// the zeros it ends in, and how many those were.
fn significant_digits(limbs : Array[Int64]) -> (String, Int64) {
  let top = limbs[limbs.length() - 1].to_string()
  let text = StringBuilder()
  text.write_string(top)
  for i = limbs.length() - 2; i >= 0; i = i - 1 {
    let group = limbs[i].to_string()
    let mut pad = 9 - group.length()
    while pad > 0 {
      text.write_char('0')
      pad -= 1
    }
    text.write_string(group)
  }
  let digits = text.to_string()
  let mut end = digits.length()
  while end > 1 && digits[end - 1].to_int() == 48 {
    end -= 1
  }
  (digits[:end].to_owned(), (digits.length() - end).to_int64())
}

///|
/// The decimal a big-endian two's-complement integer of `bytes` carries
/// under a `scale`: up to sixteen bytes, the width of a 128-bit integer,
/// and no more than 34 significant digits once its trailing zeros are gone.
fn decimal_run(
  bytes : Bytes,
  scale : Int64,
  what : String,
) -> @types.Dec128 raise @types.DataError {
  let width = bytes.length()
  if width == 0 {
    return @types.Dec128::zero()
  }
  if width > 16 {
    raise refuse(
      "\{what}: a decimal \{width} bytes wide, past the 16 a 128-bit integer holds",
    )
  }
  let negative = (bytes[0].to_int() & 0x80) != 0
  let mut limbs : Array[Int64] = [0L]
  // A negative integer's magnitude is its two's complement: the bytes
  // inverted, then raised by one.
  for i in 0..<width {
    let byte = if negative {
      bytes[i].to_int() ^ 0xFF
    } else {
      bytes[i].to_int()
    }
    limbs = limbs_pushed(limbs, 256, byte.to_int64())
  }
  if negative {
    limbs = limbs_pushed(limbs, 1, 1)
  }
  let (digits, zeros) = significant_digits(limbs)
  if digits.length() > 34 {
    raise refuse("\{what}: a decimal with more than 34 significant digits")
  }
  let ten = @types.Dec128::of_int64(10L)
  let mut value = @types.Dec128::zero()
  for i in 0..<digits.length() {
    value = value
      .mul(ten)
      .add(@types.Dec128::of_int64((digits[i].to_int() - 48).to_int64()))
  }
  // The zeros the magnitude ends in are a power of ten of their own, so the
  // scale still to apply is the column's less those.
  let scaled = value.mul(
    @types.Dec128::of_int64_scale(1L, scale=(scale - zeros).to_int()),
  )
  if negative {
    scaled.neg()
  } else {
    scaled
  }
}

///|
/// What a partition datum spells, for the refusals.
fn spelled(value : AvroValue) -> String {
  match value {
    VBool(_) => "a boolean"
    VLong(_) => "a whole number"
    VDouble(_) => "a float"
    VString(_) => "a string"
    VDecimal(_, scale) => "a decimal of scale \{scale}"
    VBytes => "bytes"
  }
}

///|
/// The scalar a partition datum spells when no type is expected of it —
/// the datum of a void or of a transform this reader does not know. Raises
/// `Unsupported` for bytes, which have no scalar here.
fn any_scalar(
  value : AvroValue,
  name : String,
) -> @types.Scalar raise @types.DataError {
  match value {
    VBool(b) => @types.Scalar::Bool(b)
    VLong(n) => @types.Scalar::Int(n)
    VDouble(d) => @types.Scalar::Float(d)
    VString(s) => @types.Scalar::String(s)
    VDecimal(d, _) => @types.Scalar::Decimal(d)
    VBytes =>
      raise refuse(
        "the partition field \"\{name}\": bytes, which this reader does not carry as a value",
      )
  }
}

///|
/// The scalar a partition datum spells under the shape its transform and
/// its source column give it. Raises `ParseError` when the datum is of
/// another shape — a decimal of another scale among them.
fn typed_scalar(
  expected : Expected,
  value : AvroValue,
  name : String,
) -> @types.Scalar raise @types.DataError {
  let what = "the partition field \"\{name}\""
  match (expected, value) {
    (EBool, VBool(b)) => @types.Scalar::Bool(b)
    (EInt, VLong(n)) => @types.Scalar::Int(n)
    (EFloat, VDouble(d)) => @types.Scalar::Float(d)
    (EString, VString(s)) => @types.Scalar::String(s)
    (EDate, VLong(days)) => @types.Scalar::Date(days)
    (ETimestamp, VLong(micros)) => @types.Scalar::Timestamp(micros)
    (EDecimal(wanted), VDecimal(d, found)) =>
      if wanted == found {
        @types.Scalar::Decimal(d)
      } else {
        raise malformed(
          "\{what} holds a decimal of scale \{found}, where the column's scale is \{wanted}",
        )
      }
    (_, value) =>
      raise malformed(
        "\{what} holds \{spelled(value)}, not the shape its transform and column give it",
      )
  }
}

///|
/// The value a partition datum spells: null for a null, otherwise the
/// shape its field's transform and source column give it.
fn scalar_of(
  expected : Expected,
  value : AvroValue?,
  name : String,
) -> @types.Scalar raise @types.DataError {
  match value {
    None => @types.Scalar::Null
    Some(datum) =>
      match expected {
        EAny => any_scalar(datum, name)
        _ => typed_scalar(expected, datum, name)
      }
  }
}
