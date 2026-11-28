// The two refusings every reading raises: bytes that do not hold together
// as the format lays them out, and a shape the format allows but this
// reader does not carry. Both are the library's own error, and every text
// names what was refused.

///|
/// Bytes that contradict the layout: a file that is not what it claims, a
/// field of the wrong shape, a count or length past what the bytes hold.
fn malformed(what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("iceberg: \{what}"),
  )
}

///|
/// A shape the format defines and this reader does not carry.
fn refuse(what : String) -> @types.DataError {
  @types.DataError::Unsupported("iceberg: \{what}")
}
