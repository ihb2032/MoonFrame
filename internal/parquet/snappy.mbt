// The snappy raw-format codec the parquet SNAPPY compression codec
// rides. The decompressor is the real thing — literals and back
// references, the format every writer emits. The compressor emits a
// literal-only stream: every legal input compresses to "copy the bytes",
// which round-trips exactly and costs no ratio — correctness first, the
// matcher can tighten later without touching the format.

///|
/// Decompress a snappy raw stream: a varint uncompressed length, then
/// tag-driven elements — literals (`00`), and copies with 1-, 2-, or
/// 4-byte offsets (`01` / `10` / `11`). A malformed stream (a length
/// past its bytes, an offset behind the output's start or ahead of its
/// end) refuses; the caller surfaces it as a located error. The output
/// grows with what the stream actually produces — the declared length
/// is checked against, never pre-allocated, so a five-byte stream
/// claiming a gigabyte costs five bytes, not a gigabyte.
fn snappy_decompress(input : Bytes) -> Bytes? {
  let r = thrift_reader(input)
  let declared = match r.varint() {
    Some(v) => v
    None => return None
  }
  if declared > 0x4000_0000UL {
    return None
  }
  let declared = declared.reinterpret_as_int64()
  let out : Array[Byte] = []
  let mut written : Int64 = 0
  // The declared length is authoritative: elements are consumed until
  // it is reached, a stream that ends before then fails the final
  // length check below.
  while written < declared {
    let tag = match r.byte() {
      Some(t) => t
      None => break
    }
    match tag & 0x03 {
      0 => {
        // A literal: the low six bits name its length minus one, with
        // the 60..63 spellings carrying extra bytes.
        let mut len = (tag >> 2) + 1
        if len >= 61 {
          let extra = len - 60
          len = 0
          for i in 0..<extra {
            match r.byte() {
              Some(b) => len = len | (b.to_int64() << (i * 8)).to_int()
              None => return None
            }
          }
          len = len + 1
        }
        if written + len.to_int64() > declared {
          return None
        }
        for _ in 0..<len {
          match r.byte() {
            Some(b) => {
              out.push(b.to_byte())
              written = written + 1
            }
            None => return None
          }
        }
      }
      1 => {
        // Copy with an 11-bit offset and a 4..11 length.
        let next = match r.byte() {
          Some(b) => b
          None => return None
        }
        let len = ((tag >> 2) & 0x07) + 4
        let offset = ((tag & 0xE0) << 3) | next
        if !snappy_copy(out, written, offset, len, declared) {
          return None
        }
        written = written + len.to_int64()
      }
      2 => {
        // Copy with a 16-bit offset.
        let lo = match r.byte() {
          Some(b) => b
          None => return None
        }
        let hi = match r.byte() {
          Some(b) => b
          None => return None
        }
        let len = (tag >> 2) + 1
        let offset = lo | (hi << 8)
        if !snappy_copy(out, written, offset, len, declared) {
          return None
        }
        written = written + len.to_int64()
      }
      _ => {
        // Copy with a 32-bit offset — MoonFrame columns fit memory, but
        // the spelling decodes all the same.
        let mut offset = 0
        for i in 0..<4 {
          match r.byte() {
            Some(b) => offset = offset | (b.to_int64() << (i * 8)).to_int()
            None => return None
          }
        }
        let len = (tag >> 2) + 1
        if !snappy_copy(out, written, offset, len, declared) {
          return None
        }
        written = written + len.to_int64()
      }
    }
  }
  if written != declared || out.length().to_int64() != declared {
    return None
  }
  Some(Bytes::from_array(out))
}

///|
/// One back reference: `len` bytes from `offset` behind `written`,
/// byte-at-a-time so an overlapping reference (a run the matcher
/// stretched past its source) replicates forward, exactly what the
/// format's repeat idiom means. The source always sits inside what the
/// stream has already produced (`written` is the output's own length
/// here), so each byte pushes — a push at a time keeps an overlapping
/// reference reading bytes it itself just wrote. `written` and the
/// declared bound ride Int64 so the comparisons cannot wrap.
fn snappy_copy(
  out : Array[Byte],
  written : Int64,
  offset : Int32,
  len : Int32,
  declared : Int64,
) -> Bool {
  if offset <= 0 ||
    written - offset.to_int64() < 0 ||
    written + len.to_int64() > declared {
    return false
  }
  let src = (written - offset.to_int64()).to_int()
  for i in 0..<len {
    out.push(out[src + i])
  }
  true
}

///|
/// The literal-only compressor: the varint length and the whole input
/// as maximal literals (60..63's extra-byte spellings above 6 bytes ×
/// the chunking the format's own writers use). Round-trips through
/// every snappy decompressor; compresses nothing.
fn snappy_compress_literal(input : Bytes) -> Bytes {
  let buf : Array[Byte] = []
  push_varint_bytes(buf, input.length().to_uint64())
  let n = input.length()
  let mut at = 0
  while at < n {
    // One literal element of up to 6 bytes keeps the tag single-byte —
    // the simple, obviously-legal spelling.
    let take = if n - at < 6 { n - at } else { 6 }
    buf.push(((take - 1) << 2).to_byte())
    for i in 0..<take {
      buf.push(input[at + i])
    }
    at = at + take
  }
  Bytes::from_array(buf)
}
