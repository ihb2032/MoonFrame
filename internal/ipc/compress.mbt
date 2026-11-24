// The compression seam: the one place the LZ4 and Zstandard codecs are
// reached. A compressed record batch compresses each of its buffers on its
// own, as one whole frame, and the reader inflates it into memory the
// node's own need bounds; the writer compresses a buffer when the frame is
// the shorter of the two spellings and stores it as it is otherwise.

///|
/// Inflate one compressed buffer, which declares `declared` bytes — a
/// length its node's need has already bounded. The inflating stops at that
/// length, a stream that would run past it is refused, and so is one that
/// stops short of it.
fn inflate_buffer(
  codec : BodyCodec,
  payload : BytesView,
  declared : Int32,
) -> Buf raise @types.DataError {
  let bytes = match codec {
    Lz4Frame =>
      @lz4.decompress(payload, max_output=declared) catch {
        _ => raise malformed("a compressed buffer does not decode")
      }
    Zstd =>
      @zstd.decompress(payload, max_output=declared) catch {
        _ => raise malformed("a compressed buffer does not decode")
      }
  }
  if bytes.length() != declared {
    raise malformed("a compressed buffer inflates to less than it declares")
  }
  { bytes, base: 0, len: declared, }
}

///|
/// One buffer compressed as a whole frame, or `None` when the frame would
/// not be shorter than the bytes.
fn deflate_buffer(codec : BodyCodec, bytes : BytesView) -> Bytes? {
  let frame = match codec {
    Lz4Frame => @lz4.compress(bytes)
    Zstd => @zstd.compress(bytes)
  }
  // The stored spelling opens with a four-byte length; the compressed one
  // does too, so the frame has to be shorter than the bytes alone.
  if frame.length() < bytes.length() {
    Some(frame)
  } else {
    None
  }
}
