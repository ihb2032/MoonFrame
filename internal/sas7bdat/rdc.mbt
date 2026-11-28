// The Ross Data Compression of a row stored compressed with the BINARY
// method — the file's `SASYZCR2`: a stream opened by a 16-bit control
// word whose bits are spent most significant first. A zero bit spells a
// literal: the next byte is copied. A one bit spells a command, whose
// first byte holds a four-bit command and four bits of a count: a run of
// one byte (short, or long with eight more bits of count), or a copy of
// bytes already written, from `offset` bytes back (short, or long with
// eight more bits of offset and a count byte of its own). A copy may
// reach back into the bytes it is itself writing, so it goes forward one
// byte at a time.

///|
/// Decompress the `length` bytes at `at` into `out`, which holds one
/// row, and return how many bytes were written — the caller checks that
/// against the row length. A stream that ends between two commands, or
/// on a literal's bit with no byte left to copy, ends there; anything
/// else that is missing is a refusal.
///
/// Raises `ParseError` when the stream ends inside a command, when a
/// copy command reaches further back than the row has bytes, and when the
/// row expands past `out`.
fn rdc_decompress(
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
  let mut control : UInt64 = 0UL
  let mut mask : UInt64 = 0UL
  while ipos < end {
    mask = mask >> 1
    if mask == 0UL {
      if end - ipos < 2L {
        // A lone byte is no control word: the stream ends here.
        break
      }
      control = (byte_at(bytes, ipos).to_uint64() << 8) |
        byte_at(bytes, ipos + 1L).to_uint64()
      ipos += 2L
      mask = 0x8000UL
    }
    if (control & mask) == 0UL {
      if ipos >= end {
        break
      }
      if written >= out_length {
        raise bad(
          ipos,
          "a compressed row expands past the \{out_length} bytes of a row",
        )
      }
      out[written.to_int()] = bytes[ipos.to_int()]
      ipos += 1L
      written += 1L
      continue
    }
    if ipos >= end {
      raise bad(
        ipos, "a compressed row ends before the byte a command is spelled in",
      )
    }
    let command_at = ipos
    let marker = byte_at(bytes, ipos)
    ipos += 1L
    let command = marker >> 4
    let low = (marker & 0x0F).to_int64()
    let mut copy_length = 0L
    let mut back = 0L
    let mut fill_length = 0L
    let mut filler = 0
    if command == 0 {
      if ipos >= end {
        raise bad(command_at, "a compressed row ends inside a run command")
      }
      fill_length = low + 3L
      filler = byte_at(bytes, ipos)
      ipos += 1L
    } else if command == 1 {
      if end - ipos < 2L {
        raise bad(command_at, "a compressed row ends inside a long run command")
      }
      fill_length = low + byte_at(bytes, ipos).to_int64() * 16L + 19L
      filler = byte_at(bytes, ipos + 1L)
      ipos += 2L
    } else if command == 2 {
      if end - ipos < 2L {
        raise bad(
          command_at, "a compressed row ends inside a long copy command",
        )
      }
      back = low + 3L + byte_at(bytes, ipos).to_int64() * 16L
      copy_length = byte_at(bytes, ipos + 1L).to_int64() + 16L
      ipos += 2L
    } else {
      if ipos >= end {
        raise bad(command_at, "a compressed row ends inside a copy command")
      }
      back = low + 3L + byte_at(bytes, ipos).to_int64() * 16L
      copy_length = command.to_int64()
      ipos += 1L
    }
    if fill_length > 0L {
      if fill_length > out_length - written {
        raise bad(
          command_at,
          "a compressed row expands past the \{out_length} bytes of a row",
        )
      }
      let to = written.to_int()
      let value = filler.to_byte()
      for i in 0..<fill_length.to_int() {
        out[to + i] = value
      }
      written += fill_length
    } else {
      if back > written {
        raise bad(
          command_at,
          "a copy command reaches \{back} bytes back into a row of \{written} bytes so far",
        )
      }
      if copy_length > out_length - written {
        raise bad(
          command_at,
          "a compressed row expands past the \{out_length} bytes of a row",
        )
      }
      let to = written.to_int()
      let from = (written - back).to_int()
      for i in 0..<copy_length.to_int() {
        out[to + i] = out[from + i]
      }
      written += copy_length
    }
  }
  written
}
