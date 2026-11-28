// The compression blocks a stream is cut into, and the four codecs they
// inflate with. Every part of a file but its PostScript is a stream of
// blocks under the compression the PostScript names: each block three
// header bytes and a payload. A stream is inflated whole, on demand, from
// the bytes the stripe footer locates for it.

///|
/// How much one block may inflate to, whatever block size the PostScript
/// declares. The format promises that no block expands past its
/// compression block size, and the writers choose 64 KiB, 256 KiB or the
/// like; a file that declares more than this inflates its blocks under
/// this ceiling, so a small file cannot ask for an unbounded allocation.
const MAX_BLOCK_OUTPUT : Int64 = 16777216L

///|
/// The compression kind the PostScript names: none, or one of the four
/// codecs this reader inflates.
priv enum Compression {
  None
  Zlib
  Snappy
  Lz4
  Zstd
}

///|
/// The kind's name as the format spells it.
fn Compression::name(self : Compression) -> String {
  match self {
    None => "NONE"
    Zlib => "ZLIB"
    Snappy => "SNAPPY"
    Lz4 => "LZ4"
    Zstd => "ZSTD"
  }
}

///|
/// The file as every stream reads it: its bytes, the compression its
/// PostScript names, and the bytes one of its blocks may inflate to.
priv struct Source {
  bytes : Bytes
  compression : Compression
  limit : Int64
}

///|
/// The bytes of a file under one compression: a block may inflate to the
/// lesser of the PostScript's block size and the ceiling above.
fn source(
  bytes : Bytes,
  compression : Compression,
  block_size : Int64,
) -> Source {
  let ceiling = if block_size < MAX_BLOCK_OUTPUT {
    block_size
  } else {
    MAX_BLOCK_OUTPUT
  }
  { bytes, compression, limit: ceiling, }
}

///|
/// The logical bytes of the `length` bytes at `at`: as they are without
/// compression, else every block inflated in turn. `what` names the
/// stream for the refusals: a header or a payload the range cuts short,
/// a block that declares no bytes or more than the block size, and a
/// block that does not decompress within it, each naming the block's
/// header byte. The range has been checked against the file by the
/// caller.
fn Source::range(
  self : Source,
  at : Int32,
  length : Int32,
  what : String,
) -> Bytes raise @types.DataError {
  if length == 0 {
    Bytes::from_array([])
  } else {
    match self.compression {
      None => self.bytes.exact_view(start=at, end=at + length).to_owned()
      _ => {
        let end = at + length
        let out : Array[Byte] = []
        let mut pos = at
        while pos < end {
          if end - pos < 3 {
            raise bad(pos, "\{what}: a block header cut short")
          }
          let header_at = pos
          let low = self.bytes[pos].to_int()
          let middle = self.bytes[pos + 1].to_int()
          let high = self.bytes[pos + 2].to_int()
          let header = low | (middle << 8) | (high << 16)
          pos = pos + 3
          // The low bit says the payload is stored as it is; the bits above
          // are its length.
          let size = header >> 1
          let original = (header & 1) == 1
          if size == 0 {
            raise bad(header_at, "\{what}: a block that declares no bytes")
          }
          if size > end - pos {
            let error = bad(
              header_at,
              "\{what}: a block of \{size} bytes runs past the end at byte \{end}",
            )
            raise error
          }
          if original {
            for i in 0..<size {
              out.push(self.bytes[pos + i])
            }
          } else {
            if size.to_int64() > self.limit {
              let error = bad(
                header_at,
                "\{what}: a compressed block of \{size} bytes, past the block size of \{self.limit}",
              )
              raise error
            }
            let payload = self.bytes.clamped_view(start=pos, end=pos + size)
            let part = inflate(self.compression, payload, self.limit.to_int()) catch {
              _ =>
                raise bad(
                  header_at,
                  "\{what}: a \{self.compression.name()} block that does not decompress within \{self.limit} bytes",
                )
            }
            for b in part {
              out.push(b)
            }
          }
          pos = pos + size
        }
        Bytes::from_array(out)
      }
    }
  }
}

///|
/// One compressed block's payload inflated, under the byte ceiling: raw
/// DEFLATE for ZLIB, snappy's raw block, LZ4's block format and a zstd
/// frame — the spellings the format's writers emit. A block that does not
/// decompress raises the codec's own error; the caller names the byte.
fn inflate(
  compression : Compression,
  payload : BytesView,
  limit : Int32,
) -> Bytes raise {
  match compression {
    None => payload.to_owned()
    Zlib => @flate.inflate_all(payload, max_output=limit)
    Snappy => @snappy.decompress_raw(payload, max_output=limit)
    Lz4 => @lz4.decompress_block(payload, max_output=limit)
    Zstd => @zstd.decompress(payload, max_output=limit)
  }
}
