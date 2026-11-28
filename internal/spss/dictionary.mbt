///|
/// One variable record as the dictionary spells it, with what the
/// extension records later say of it.
priv struct Slot {
  at : Int32
  raw_name : Bytes
  width : Int32
  octets : Int32
  format : Int32
  missing_raw : Array[Bytes]
  mut name : String
  ranges : Array[Double]
  missing : Array[String]
  mut length : Int64
  mut owner : Int32
}

///|
/// What the dictionary establishes before a cell is read: the variable
/// records in file order, the compression, the case count the header
/// declares (−1 when it declares none), the bits of the system-missing
/// value, the text encoding, and the floating-point byte order.
priv struct Dictionary {
  slots : Array[Slot]
  compression : Int32
  ncases : Int64
  sysmis : UInt64
  encoding : Encoding
  big_float : Bool
}

///|
/// The bits of the system-missing value: the largest negative IEEE 754
/// number. A file's floating-point info record may spell its own.
const SYSMIS : UInt64 = 0xFFEFFFFFFFFFFFFFUL

///|
/// The bits of HIGHEST, the open top of a missing range.
const HIGHEST : UInt64 = 0x7FEFFFFFFFFFFFFFUL

///|
/// The bits of LOWEST, the open bottom of a missing range before the
/// format took to spelling it as the system-missing value.
const LOWEST : UInt64 = 0xFFEFFFFFFFFFFFFEUL

///|
/// The bits of 100.0, the compression bias every file this reader
/// decodes carries.
const BIAS : UInt64 = 0x4059000000000000UL

///|
/// The bits of positive infinity.
const INFINITY : UInt64 = 0x7FF0000000000000UL

///|
/// The extension records this reader reads, as the offset and the bytes
/// of the first record of each subtype the dictionary holds — a
/// repeated subtype is passed over, as it carries nothing the first did
/// not.
priv struct Records {
  mut integer_info : Bytes?
  mut float_info : Bytes?
  mut long_names : Bytes?
  mut lengths : Bytes?
  mut encoding_name : Bytes?
  mut long_missing : Bytes?
  mut long_names_at : Int32
  mut lengths_at : Int32
  mut long_missing_at : Int32
  mut integer_info_at : Int32
}

///|
/// Whether `text` is spelled at byte `at` of `bytes`.
fn spells(bytes : Bytes, at : Int32, text : Bytes) -> Bool {
  if at + text.length() > bytes.length() {
    return false
  }
  for i in 0..<text.length() {
    if bytes[at + i] != text[i] {
      return false
    }
  }
  true
}

///|
/// The file header record: the signature, the integer byte order, the
/// compression, the case count, and — from the compression bias, which
/// every file this reader decodes sets to 100 — the floating-point byte
/// order. The product name, the nominal case size (which the format
/// itself calls unreliable), the weight variable, the creation date and
/// time and the file label are passed over. Answers the compression and
/// the declared case count.
fn read_header(c : Cursor) -> (Int32, Int64) raise @types.DataError {
  // A file shorter than a signature is not a system file.
  if c.bytes.length() < 4 {
    raise nope("byte 0: the file signature is not a system file's")
  }
  let signature = c.take(4)
  let zlib = signature == b"$FL3"
  if !(signature == b"$FL2") && !zlib {
    if spells(c.bytes, 8, b"ENCRYPTE") {
      raise nope(
        "byte 0: the file is a system file inside an encrypted wrapper, which this reader does not decrypt",
      )
    }
    if signature[0].to_int() == 0x5B &&
      signature[1].to_int() == 0xC6 &&
      signature[2].to_int() == 0xD3 &&
      signature[3].to_int() == 0xF2 {
      raise nope(
        "byte 0: the file signature is a system file's in EBCDIC, whose text this reader does not decode",
      )
    }
    raise nope("byte 0: the file signature is not a system file's")
  }
  c.skip(60)
  c.short(4)
  let b0 = c.bytes[c.pos].to_int()
  let b1 = c.bytes[c.pos + 1].to_int()
  let b2 = c.bytes[c.pos + 2].to_int()
  let b3 = c.bytes[c.pos + 3].to_int()
  if (b0 == 2 || b0 == 3) && b1 == 0 && b2 == 0 && b3 == 0 {
    c.big = false
  } else if b0 == 0 && b1 == 0 && b2 == 0 && (b3 == 2 || b3 == 3) {
    c.big = true
  } else {
    raise nope(
      "byte 64: the layout code is 2 or 3 in neither byte order, so the file is not a system file",
    )
  }
  c.pos = c.pos + 4
  c.skip(4)
  let compression_at = c.pos
  let compression = c.i32()
  if compression < 0L || compression > 2L {
    raise nope(
      "byte \{compression_at}: the header declares compression \{compression}, which this reader does not decode",
    )
  }
  if zlib != (compression == 2L) {
    raise bad(
      "byte \{compression_at}: the header declares compression \{compression} under the \{if zlib { "$FL3" } else { "$FL2" }} signature, and only $FL3 carries compression 2",
    )
  }
  c.skip(4)
  let count_at = c.pos
  let ncases = c.i32()
  if ncases < -1L {
    raise bad("byte \{count_at}: the header declares \{ncases} cases")
  }
  let bias_at = c.pos
  c.short(8)
  if bits_at(c.bytes, c.pos, false) == BIAS {
    c.big_float = false
  } else if bits_at(c.bytes, c.pos, true) == BIAS {
    c.big_float = true
  } else {
    raise nope(
      "byte \{bias_at}: the compression bias is not 100 or the floating-point format is not IEEE 754, and this reader decodes neither",
    )
  }
  c.pos = c.pos + 8
  c.skip(84)
  (compression.to_int(), ncases)
}

///|
/// Refuse when a string variable still awaits continuation records and
/// the record at `at` is none.
fn continuations_due(
  pending : Int32,
  slots : Array[Slot],
  at : Int32,
) -> Unit raise @types.DataError {
  if pending > 0 {
    raise bad(
      "byte \{at}: \{pending} continuation record\{if pending == 1 { "" } else { "s" }} of the string variable at byte \{slots[slots.length() - 1].at} \{if pending == 1 { "is" } else { "are" }} missing",
    )
  }
}

///|
/// A variable record. A numeric variable takes one eight-byte unit; a
/// string of `width` bytes takes `width` rounded up to eight, and the
/// records that follow it must be its continuations, a record of type
/// −1 for each unit beyond the first — their count is checked against
/// the bytes that remain before any is expected. `pending` is how many
/// of them the string variable before still awaits. The variable label
/// and the write format are passed over. Answers how many continuation
/// records this variable awaits.
fn variable_record(
  c : Cursor,
  slots : Array[Slot],
  pending : Int32,
) -> Int32 raise @types.DataError {
  let at = c.pos - 4
  let width = c.i32().to_int()
  let has_label = c.i32()
  let n_missing = c.i32()
  let print = c.u32()
  c.skip(4)
  let field = c.take(8)
  if has_label != 0L && has_label != 1L {
    raise bad(
      "byte \{at + 8}: the variable label indicator is \{has_label}, not 0 or 1",
    )
  }
  if has_label == 1L {
    // The label's length, padded to a multiple of four bytes.
    c.skip64(up4(c.u32()))
  }
  let (missing, missing_raw) = if n_missing == 0L {
    ([], [])
  } else {
    missing_values(c, at, width, n_missing)
  }
  if width < 0 {
    if pending > 0 && width == -1 {
      return pending - 1
    }
    raise nope(
      "byte \{at + 4}: the variable type \{width} is neither numeric (0) nor string (greater than 0)",
    )
  }
  continuations_due(pending, slots, at)
  let end = locate_blank(field)
  let octets = if width == 0 { 1L } else { up8(width.to_int64()) / 8L }
  let more = octets - 1L
  let have = (c.bytes.length() - c.pos).to_int64()
  if more * 32L > have {
    raise bad(
      "byte \{at}: the string variable is \{width} bytes wide and needs \{more} continuation record\{if more == 1L { "" } else { "s" }} of 32 bytes, and only \{have} bytes remain",
    )
  }
  slots.push({
    at,
    raw_name: field[:end].to_owned(),
    width,
    octets: octets.to_int(),
    format: ((print >> 16) & 0xFFL).to_int(),
    missing_raw,
    name: "",
    ranges: missing,
    missing: [],
    length: 0L,
    owner: -1,
  })
  more.to_int()
}

///|
/// Where a padded name field ends: its first blank or NUL, or its end.
fn locate_blank(field : BytesView) -> Int32 {
  let mut end = 0
  while end < field.length() && field[end] != b' ' && field[end] != 0 {
    end += 1
  }
  end
}

///|
/// The missing values a variable record declares, each as the bits of
/// its bounds or the bytes of its text. A numeric variable names one to
/// three values, a range, or a range and a value; a string variable
/// names one to three values of eight bytes. Any other count contradicts
/// the record.
fn missing_values(
  c : Cursor,
  at : Int32,
  width : Int32,
  n_missing : Int64,
) -> (Array[Double], Array[Bytes]) raise @types.DataError {
  if width != 0 {
    if n_missing < 1L || n_missing > 3L {
      raise bad(
        "byte \{at + 12}: the missing value indicator \{n_missing} of a string variable is not 1, 2 or 3",
      )
    }
    let texts : Array[Bytes] = []
    for _ in 0..<n_missing.to_int() {
      texts.push(c.take(8))
    }
    return ([], texts)
  }
  if n_missing == -1L || n_missing < -3L || n_missing > 3L {
    raise bad(
      "byte \{at + 12}: the missing value indicator \{n_missing} of a numeric variable is not -3, -2, 1, 2 or 3",
    )
  }
  let values : Array[UInt64] = []
  for _ in 0..<n_missing.abs().to_int() {
    values.push(c.f64_bits())
  }
  let bounds : Array[Double] = []
  if n_missing < 0L {
    bounds.push(low_bound(values[0]))
    bounds.push(high_bound(values[1]))
    if n_missing == -3L {
      bounds.push(values[2].reinterpret_as_double())
      bounds.push(values[2].reinterpret_as_double())
    }
  } else {
    for value in values {
      bounds.push(value.reinterpret_as_double())
      bounds.push(value.reinterpret_as_double())
    }
  }
  (bounds, [])
}

///|
/// The bottom of a missing range: the format's open bottom is spelled
/// LOWEST, or — since one release of the writer — as the system-missing
/// value itself, which no range otherwise holds.
fn low_bound(bits : UInt64) -> Double {
  if bits == LOWEST || bits == SYSMIS {
    INFINITY.reinterpret_as_double() * -1.0
  } else {
    bits.reinterpret_as_double()
  }
}

///|
/// The top of a missing range: the format's open top is spelled
/// HIGHEST.
fn high_bound(bits : UInt64) -> Double {
  if bits == HIGHEST {
    INFINITY.reinterpret_as_double()
  } else {
    bits.reinterpret_as_double()
  }
}

///|
/// A value-label record and the record of variables it labels, which
/// must follow it. Value labels are not applied — there is no
/// categorical dtype — so both are passed over, every length checked
/// against what remains.
fn value_labels(c : Cursor, at : Int32) -> Unit raise @types.DataError {
  let count = c.u32()
  let mut left = count
  while left > 0L {
    c.skip(8)
    let len = c.u8()
    c.skip((len + 8) / 8 * 8 - 1)
    left -= 1L
  }
  let next_at = c.pos
  if c.i32() != 4L {
    raise bad(
      "byte \{next_at}: a type 4 record must follow the type 3 record at byte \{at}",
    )
  }
  let vars = c.u32()
  c.skip64(vars * 4L)
}

///|
/// A document record: its lines are passed over, their count checked
/// against what remains.
fn document(c : Cursor) -> Unit raise @types.DataError {
  let lines = c.u32()
  c.skip64(lines * 80L)
}

///|
/// An extension record's subtype and data. The data is `size × count`
/// bytes, a product too wide to form before `count` is checked against
/// what remains per element.
fn extension(c : Cursor, at : Int32) -> (Int64, Bytes) raise @types.DataError {
  let subtype = c.u32()
  let size = c.u32()
  let count = c.u32()
  let have = (c.bytes.length() - c.pos).to_int64()
  if size != 0L && count > have / size {
    raise bad(
      "byte \{at}: the extension record of subtype \{subtype} declares \{count} elements of \{size} bytes, and only \{have} bytes remain",
    )
  }
  (subtype, c.take((size * count).to_int()))
}

///|
/// The dictionary's records after the header, up to and including the
/// terminator: the variable records in file order, and the first record
/// of each extension subtype this reader reads. A record of a type the
/// format does not define, or a type 4 record that follows no type 3
/// record, contradicts the layout and is refused.
fn read_records(
  c : Cursor,
  slots : Array[Slot],
) -> Records raise @types.DataError {
  let records = Records::{
    integer_info: None,
    float_info: None,
    long_names: None,
    lengths: None,
    encoding_name: None,
    long_missing: None,
    long_names_at: 0,
    lengths_at: 0,
    long_missing_at: 0,
    integer_info_at: 0,
  }
  let mut pending = 0
  let mut done = false
  while !done {
    let at = c.pos
    let kind = c.i32()
    if kind == 999L {
      continuations_due(pending, slots, at)
      c.skip(4)
      done = true
    } else if kind == 2L {
      pending = variable_record(c, slots, pending)
    } else {
      continuations_due(pending, slots, at)
      // A subtype this reader does not read — variable display
      // parameters, attributes, multiple response sets, value labels for
      // long strings, and the ones known only by number — says nothing
      // about the cells and is stepped over by its length.
      match kind {
        3L => value_labels(c, at)
        6L => document(c)
        7L => records.keep(at, extension(c, at))
        _ =>
          raise bad(
            "byte \{at}: record type \{kind} names no record of the format",
          )
      }
    }
  }
  records
}

///|
/// Keep the data of the first record of the subtype, once read, with
/// the offset its record starts at.
fn Records::keep(self : Records, at : Int32, record : (Int64, Bytes)) -> Unit {
  let (subtype, data) = record
  match subtype {
    3L =>
      if self.integer_info is None {
        self.integer_info = Some(data)
        self.integer_info_at = at
      }
    4L => if self.float_info is None { self.float_info = Some(data) }
    13L =>
      if self.long_names is None {
        self.long_names = Some(data)
        self.long_names_at = at
      }
    14L =>
      if self.lengths is None {
        self.lengths = Some(data)
        self.lengths_at = at
      }
    20L => if self.encoding_name is None { self.encoding_name = Some(data) }
    22L =>
      if self.long_missing is None {
        self.long_missing = Some(data)
        self.long_missing_at = at
      }
    _ => ()
  }
}
