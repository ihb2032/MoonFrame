///|
/// One located parse refusal — the reader's error vocabulary for bytes
/// that contradict the layout. `what` names the byte and the fault.
fn bad(what : String) -> @types.DataError {
  @types.DataError::ParseError(@types.ParseErrorDetail::Message("xls: \{what}"))
}

///|
/// One refusal by name — the reader's error vocabulary for something
/// this reader does not read.
fn nope(what : String) -> @types.DataError {
  @types.DataError::Unsupported("xls: \{what}")
}

///|
/// One refusal of a request the workbook cannot serve.
fn no(what : String) -> @types.DataError {
  @types.DataError::InvalidOperation("xls: \{what}")
}

///|
/// Four hexadecimal digits, upper case, of a number the file carries —
/// how a refusal spells a record's id or a version.
fn hex4(value : Int32) -> String {
  let digits = "0123456789ABCDEF".code_units()
  let out = StringBuilder()
  for shift in [12, 8, 4, 0] {
    let digit = digits[(value >> shift).to_int() & 15].to_int()
    out.write_char(digit.to_byte().to_char())
  }
  out.to_string()
}

///|
/// A sector number as the file carries it: unsigned, so that a refusal
/// spells an end-of-chain marker as the 4294967294 it is.
fn unsigned(value : Int32) -> Int64 {
  value.reinterpret_as_uint().to_int64()
}

///|
/// A position in a count, as an ordinal a refusal names a thing by:
/// `1st`, `2nd`, `3rd`, `4th`, `11th`, `21st`.
fn ordinal(value : Int32) -> String {
  let last = value % 10
  let tens = value % 100
  let ending = if tens >= 11 && tens <= 13 {
    "th"
  } else if last == 1 {
    "st"
  } else if last == 2 {
    "nd"
  } else if last == 3 {
    "rd"
  } else {
    "th"
  }
  "\{value}\{ending}"
}
