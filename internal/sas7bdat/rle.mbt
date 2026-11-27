// The run-length coding of a row stored compressed with the CHAR method
// — the file's `SASYZCRL`: a stream of commands, each a control byte
// whose high nibble names the command and whose low nibble carries four
// bits of the length, followed by the command's operands. A command
// copies bytes out of the stream, or fills the row with one byte: one
// named in the command, or a blank, an at-sign or a NUL.

///|
/// The operand bytes that follow each command's control byte, by
/// command: the length byte or bytes, and the byte a fill repeats.
let rle_operands : ReadOnlyArray[Int32] = [
  1, 1, 0, 0, 2, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0,
]

///|
/// Decompress the `length` bytes at `at` into `out`, which holds one
/// row, and return how many bytes were written — the caller checks that
/// against the row length. Every count is checked before it copies or
/// fills.
///
/// Raises `ParseError` when a control byte names no command, when the
/// stream ends inside a command's operands, when a copy command reaches
/// past the end of the stream, and when the row expands past `out`.
fn rle_decompress(
  bytes : Bytes,
  at : Int64,
  length : Int64,
  out : Array[Byte],
) -> Int64 raise @types.DataError {
  // The stream is checked against the bytes once, here: every read below
  // then lies inside it.
  need(bytes, at, length, "a compressed row")
  let end = at + length
  let out_length = out.length().to_int64()
  let mut ipos = at
  let mut written = 0L
  while ipos < end {
    let control_at = ipos
    let control = byte_at(bytes, ipos)
    ipos += 1
    let command = control >> 4
    let low = (control & 0x0F).to_int64()
    let operands = rle_operands[command].to_int64()
    if end - ipos < operands {
      raise bad(control_at, "a compressed row ends inside a command's operands")
    }
    let mut copy_length = 0L
    let mut fill_length = 0L
    let mut filler = 0
    match command {
      0 => copy_length = byte_at(bytes, ipos).to_int64() + 64L + low * 256L
      1 =>
        copy_length = byte_at(bytes, ipos).to_int64() + 64L + low * 256L + 4096L
      2 => copy_length = low + 96L
      4 => {
        fill_length = byte_at(bytes, ipos).to_int64() + 18L + low * 256L
        filler = byte_at(bytes, ipos + 1L)
      }
      5 => {
        fill_length = byte_at(bytes, ipos).to_int64() + 17L + low * 256L
        filler = 0x40
      }
      6 => {
        fill_length = byte_at(bytes, ipos).to_int64() + 17L + low * 256L
        filler = 0x20
      }
      7 => {
        fill_length = byte_at(bytes, ipos).to_int64() + 17L + low * 256L
        filler = 0x00
      }
      8 => copy_length = low + 1L
      9 => copy_length = low + 17L
      10 => copy_length = low + 33L
      11 => copy_length = low + 49L
      12 => {
        fill_length = low + 3L
        filler = byte_at(bytes, ipos)
      }
      13 => {
        fill_length = low + 2L
        filler = 0x40
      }
      14 => {
        fill_length = low + 2L
        filler = 0x20
      }
      15 => {
        fill_length = low + 2L
        filler = 0x00
      }
      // Command 3, the one the coding gives no name.
      _ =>
        raise bad(
          control_at,
          "a compressed row carries the control byte \{control}, which names no command",
        )
    }
    ipos += operands
    if copy_length > 0L {
      if copy_length > end - ipos {
        raise bad(control_at, "a compressed row ends inside a copy command")
      }
      if copy_length > out_length - written {
        raise bad(
          control_at,
          "a compressed row expands past the \{out_length} bytes of a row",
        )
      }
      let from = ipos.to_int()
      let to = written.to_int()
      for i in 0..<copy_length.to_int() {
        out[to + i] = bytes[from + i]
      }
      ipos += copy_length
      written += copy_length
    }
    if fill_length > 0L {
      if fill_length > out_length - written {
        raise bad(
          control_at,
          "a compressed row expands past the \{out_length} bytes of a row",
        )
      }
      let to = written.to_int()
      let value = filler.to_byte()
      for i in 0..<fill_length.to_int() {
        out[to + i] = value
      }
      written += fill_length
    }
  }
  written
}
