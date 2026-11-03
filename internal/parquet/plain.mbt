// The PLAIN encoding over the physical types the MoonFrame surface
// maps to — little-endian fixed-width integers and floats, and the
// four-byte-length-prefixed byte arrays of `BOOLEAN` (bit-packed LSB
// first) and `BYTE_ARRAY` (strings). The parquet spec's own byte
// order: PLAIN is little-endian throughout.

///|
/// Append one little-endian `Int32`.
fn push_le_i32(buf : Array[Byte], v : Int32) -> Unit {
  let mut rest = v
  for _ in 0..<4 {
    buf.push((rest & 0xFF).to_byte())
    rest = rest >> 8
  }
}

///|
/// Append one little-endian `Int64`.
fn push_le_i64(buf : Array[Byte], v : Int64) -> Unit {
  let mut rest = v
  for _ in 0..<8 {
    buf.push((rest & 0xFF).to_byte())
    rest = rest >> 8
  }
}

///|
/// Append one little-endian `Double`.
fn push_le_f64(buf : Array[Byte], v : Double) -> Unit {
  let bits = v.reinterpret_as_uint64()
  let mut rest = bits
  for _ in 0..<8 {
    buf.push((rest & 0xFFUL).to_byte())
    rest = rest >> 8
  }
}

///|
/// Append one little-endian `Float` (`Double`'s narrow parquet spelling).

///|
/// Read one little-endian `Int32` at `offset`.
fn le_i32(bytes : Bytes, offset : Int32) -> Int32 {
  let mut v = 0
  for i = 3; i >= 0; i = i - 1 {
    v = (v << 8) | bytes[offset + i].to_int()
  }
  v
}

///|
/// Read one little-endian `Int64` at `offset`.
fn le_i64(bytes : Bytes, offset : Int32) -> Int64 {
  let mut v = 0L
  for i = 7; i >= 0; i = i - 1 {
    v = (v << 8) | bytes[offset + i].to_int64()
  }
  v
}

///|
/// Read one little-endian `Double` at `offset`.
fn le_f64(bytes : Bytes, offset : Int32) -> Double {
  let mut v = 0UL
  for i = 7; i >= 0; i = i - 1 {
    v = (v << 8) | bytes[offset + i].to_uint64()
  }
  v.reinterpret_as_double()
}

///|
/// Read one length-prefixed byte array at `offset`, returning the
/// `(start, length)` of its payload — a view, not a copy, the caller
/// copies what it keeps.
fn le_bytes_prefix(bytes : Bytes, offset : Int32) -> (Int32, Int32)? {
  // Subtraction forms throughout: `offset` never passes the buffer's
  // length, so every difference below stays inside Int32, while the
  // additions could fold a hostile length back inside the bound.
  if offset < 0 || bytes.length() - offset < 4 {
    return None
  }
  let len = le_i32(bytes, offset)
  if len < 0 || len > bytes.length() - offset - 4 {
    return None
  }
  Some((offset + 4, len))
}

///|
/// Boolean PLAIN: bit `i` of the page's byte `i / 8`, LSB first.
fn bool_bit(bytes : Bytes, i : Int32) -> Bool {
  ((bytes[i / 8].to_int() >> (i % 8)) & 1) != 0
}
