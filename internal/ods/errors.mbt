// The refusal shapes every error of this reader takes: a malformed file,
// something this reader does not read, and a sheet that is not there. The
// two constructors are the only places a `DataError` of the first two
// kinds is built, and every message of this reader begins with its name.

///|
/// A file that contradicts the format: `ParseError`, its message naming
/// the byte, the sheet or the attribute where the file is wrong.
fn bad(message : String) -> @types.DataError {
  @types.DataError::ParseError(@types.ParseErrorDetail::Message(message))
}

///|
/// Something the format defines and this reader does not read — a
/// mimetype, an encoding, a value type — named in the message:
/// `Unsupported`.
fn nope(message : String) -> @types.DataError {
  @types.DataError::Unsupported(message)
}
