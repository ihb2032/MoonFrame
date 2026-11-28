// The workbook stream as a run of records — a two-byte id, a two-byte
// length, then the body — and the checked reads a record's fields go
// through: a field is read only once the record has been shown to hold
// it, and a record shorter than its kind needs refuses, naming its byte.

///|
/// One record of the workbook stream: its id, the byte its header begins
/// at, and how many bytes its body holds.
priv struct Record {
  id : Int32
  /// The byte of the workbook stream where the record's header begins.
  at : Int32
  /// The body's length.
  len : Int32
}

///|
/// The byte of the workbook stream where the record's body begins.
fn Record::body(self : Record) -> Int32 {
  self.at + 4
}

///|
/// The byte past the record.
fn Record::after(self : Record) -> Int32 {
  self.at + 4 + self.len
}

///|
/// Refuse unless the record's body holds at least `need` bytes.
fn Record::need(self : Record, need : Int32) -> Unit raise @types.DataError {
  if self.len < need {
    raise bad(
      "byte \{self.at} of the workbook stream: the \{record_name(self.id)} record is \{self.len} bytes long, and its kind needs \{need}",
    )
  }
}

///|
/// A one-byte field at `off` of the body.
fn Record::byte(
  self : Record,
  stream : Bytes,
  off : Int32,
) -> Int32 raise @types.DataError {
  self.need(off + 1)
  stream[self.body() + off].to_int()
}

///|
/// An unsigned two-byte field at `off` of the body.
fn Record::u16(
  self : Record,
  stream : Bytes,
  off : Int32,
) -> Int32 raise @types.DataError {
  self.need(off + 2)
  u16_at(stream, self.body() + off)
}

///|
/// The bits of a four-byte field at `off` of the body, in the file's
/// little-endian order.
fn Record::i32(
  self : Record,
  stream : Bytes,
  off : Int32,
) -> Int32 raise @types.DataError {
  self.need(off + 4)
  i32_at(stream, self.body() + off)
}

///|
/// The floating-point number of the eight-byte field at `off` of the
/// body.
fn Record::f64(
  self : Record,
  stream : Bytes,
  off : Int32,
) -> Double raise @types.DataError {
  self.need(off + 8)
  bits_at(stream, self.body() + off).reinterpret_as_double()
}

///|
/// How a refusal names a record: by the format's own name for the kinds a
/// refusal names — a cell's, a run of cells', a style's, a sheet's BOF —
/// and by its id for any other. The records whose refusals carry a
/// wording of their own, the shared string table and the strings among
/// them, are not named here.
fn record_name(id : Int32) -> String {
  match id {
    0x0809 => "BOF"
    0x000A => "EOF"
    0x0006 => "FORMULA"
    0x00BD => "MULRK"
    0x00BE => "MULBLANK"
    0x00E0 => "XF"
    0x00FD => "LABELSST"
    0x0201 => "BLANK"
    0x0203 => "NUMBER"
    0x0205 => "BOOLERR"
    0x027E => "RK"
    _ => "0x\{hex4(id)}"
  }
}

///|
/// The record whose header lies at `at` of the workbook stream. Raises
/// `ParseError`, naming the byte, when the stream ends inside the header
/// or inside the body the header declares.
fn record_at(stream : Bytes, at : Int32) -> Record raise @types.DataError {
  if stream.length() - at < 4 {
    raise bad(
      "byte \{at} of the workbook stream: the stream ends inside a record header, which needs 4 bytes",
    )
  }
  let len = u16_at(stream, at + 2)
  if stream.length() - at - 4 < len {
    raise bad(
      "byte \{at} of the workbook stream: the record claims \{len} bytes and the stream holds \{stream.length() - at - 4} after its header",
    )
  }
  Record::{ id: u16_at(stream, at), at, len, }
}

///|
/// Whether the record's id is a BOF's: the id every BIFF version spells
/// for the record that opens a substream, the version in its high byte.
fn is_bof(id : Int32) -> Bool {
  id == 0x0809 || id == 0x0409 || id == 0x0209 || id == 0x0009
}
