///|
/// Apache Arrow compatible validity bitmap.
///
/// Bits are packed into bytes, **1 bit per row, 1 = valid, 0 = null**.
/// Slot `i` lives in `bits[i / 8]` at bit position `i % 8`, where bit `0`
/// is the least-significant bit of the byte. A bitmap of `len` slots
/// occupies exactly `⌈len / 8⌉` bytes — trailing bits past `len` in the
/// final byte are kept zero so that `null_count()` may safely popcount the
/// entire buffer.
///
/// The convention `1 = valid` matches the Apache Arrow specification (and
/// `arrow-rs`, `pyarrow`); note that some MoonBit ecosystem libraries (e.g.
/// `smallbearrr/pandas`) use the opposite convention.
pub struct Bitmap {
  bits : Bytes
  len : Int
} derive(Eq, Debug)

// ── Constructors ──────────────────────────────────────────────────────

///|
/// All `len` slots marked valid.
pub fn Bitmap::all_valid(len : Int) -> Bitmap {
  let n = bytes_needed(len)
  let buf = FixedArray::make(n, (0xff : Int).to_byte())
  mask_tail(buf, len)
  { bits: buffer_to_bytes(buf), len }
}

///|
/// All `len` slots marked null.
pub fn Bitmap::all_null(len : Int) -> Bitmap {
  {
    bits: buffer_to_bytes(FixedArray::make(bytes_needed(len), Byte::default())),
    len,
  }
}

///|
/// `true` ↦ valid, `false` ↦ null.
pub fn Bitmap::from_bools(values : Array[Bool]) -> Bitmap {
  pack(values.length(), i => values[i])
}

///|
/// `Some(_)` ↦ valid, `None` ↦ null. Works for any element type because
/// only the `Some/None` shape is inspected.
pub fn[T] Bitmap::from_options(values : Array[T?]) -> Bitmap {
  pack(values.length(), i => values[i] is Some(_))
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// Number of logical slots (not bytes).
pub fn Bitmap::len(self : Bitmap) -> Int {
  self.len
}

///|
/// `true` when slot `index` is valid (bit is 1). Out-of-bounds
/// `raise IndexOutOfBounds`.
pub fn Bitmap::is_valid(
  self : Bitmap,
  index : Int,
) -> Bool raise @types.DataError {
  if index < 0 || index >= self.len {
    raise @types.DataError::IndexOutOfBounds(index)
  }
  bit_at(self.bits, index)
}

///|
/// `true` when slot `index` is null (bit is 0). Out-of-bounds
/// `raise IndexOutOfBounds`.
pub fn Bitmap::is_null(
  self : Bitmap,
  index : Int,
) -> Bool raise @types.DataError {
  !self.is_valid(index)
}

///|
/// Number of null (0) bits in the logical range `[0, len)`. Trailing bits
/// past `len` in the final byte are kept zero by all constructors, so this
/// can safely popcount the entire byte buffer; we still walk bit-by-bit
/// rather than rely on that invariant because the cost is negligible for
/// v0.1 sizes and the implementation stays trivially correct.
pub fn Bitmap::null_count(self : Bitmap) -> Int {
  let n = self.len
  let mut nulls = 0
  for i in 0..<n {
    if !bit_at(self.bits, i) {
      nulls = nulls + 1
    }
  }
  nulls
}

///|
/// Materialise the validity mask as a dense `Array[Bool]` (`true = valid`),
/// one entry per logical slot in `[0, len)`.
///
/// This is the total counterpart to `is_valid` for the common case of
/// scanning every slot in order. A loop that has already bounded its index
/// to `[0, len)` reads the returned array directly (`mask[i]`, the same
/// trust level as the parallel `data[i]` access) instead of threading a
/// per-element `Result` through every iteration — which would otherwise
/// force either an `unwrap` (a panic path) or an unreachable `Err` arm.
pub fn Bitmap::to_bools(self : Bitmap) -> Array[Bool] {
  Array::makei(self.len, i => bit_at(self.bits, i))
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// Half-open `[start, start + length)` slice, rebuilt by repacking — no
/// zero-copy view (v0.2 may optimise). Errors:
/// - `IndexOutOfBounds(start)` if `start < 0` or `start > len`.
/// - `IndexOutOfBounds(start + length)` if `start + length > len`.
/// - `InvalidOperation` if `length < 0`.
pub fn Bitmap::slice(
  self : Bitmap,
  start : Int,
  length : Int,
) -> Bitmap raise @types.DataError {
  if start < 0 || start > self.len {
    raise @types.DataError::IndexOutOfBounds(start)
  }
  if length < 0 {
    raise @types.DataError::InvalidOperation(
      "slice length < 0: " + length.to_string(),
    )
  }
  if start + length > self.len {
    raise @types.DataError::IndexOutOfBounds(start + length)
  }
  pack(length, i => bit_at(self.bits, start + i))
}

///|
/// Gather: produce a new bitmap whose i-th bit is `self[indices[i]]`. Any
/// out-of-bounds index returns `Err(IndexOutOfBounds(idx))`.
pub fn Bitmap::take(
  self : Bitmap,
  indices : Array[Int],
) -> Bitmap raise @types.DataError {
  for i in indices {
    if i < 0 || i >= self.len {
      raise @types.DataError::IndexOutOfBounds(i)
    }
  }
  pack(indices.length(), i => bit_at(self.bits, indices[i]))
}

///|
/// Bitwise AND across two bitmaps of the same logical length. Used by
/// multi-column filter pipelines to merge per-column null masks. Named
/// `bit_and` because `and` is a reserved keyword in MoonBit.
/// `LengthMismatch` if the lengths differ.
pub fn Bitmap::bit_and(
  self : Bitmap,
  other : Bitmap,
) -> Bitmap raise @types.DataError {
  if self.len != other.len {
    raise @types.DataError::LengthMismatch
  }
  pack(self.len, i => bit_at(self.bits, i) && bit_at(other.bits, i))
}

// ── Internal helpers ──────────────────────────────────────────────────

///|
/// Build a bitmap of `len` slots whose `i`-th bit is `1` (valid) exactly
/// when `valid(i)` is true. This is the closure-parameterised core shared by
/// every constructor and transform that packs per-slot validity into the
/// byte buffer (`from_bools`, `from_options`, `slice`, `take`, `bit_and`);
/// each caller supplies only its own `valid` predicate. `valid` runs once per
/// slot in `[0, len)`, so the caller must keep every index it reads
/// (e.g. `start + i`, `indices[i]`) within bounds.
fn pack(len : Int, valid : (Int) -> Bool) -> Bitmap {
  let buf = FixedArray::make(bytes_needed(len), Byte::default())
  for i in 0..<len {
    if valid(i) {
      set_bit_unchecked(buf, i)
    }
  }
  { bits: buffer_to_bytes(buf), len }
}

///|
/// `⌈len / 8⌉`, clamped to 0 for non-positive `len`.
fn bytes_needed(len : Int) -> Int {
  if len <= 0 {
    0
  } else {
    (len + 7) / 8
  }
}

///|
fn buffer_to_bytes(buf : FixedArray[Byte]) -> Bytes {
  Bytes::from_array(Array::from_fixed_array(buf))
}

///|
/// Set bit `i` to 1 in `buf`. Assumes `0 <= i < buf.length() * 8`.
fn set_bit_unchecked(buf : FixedArray[Byte], i : Int) -> Unit {
  let byte_idx = i / 8
  let bit_idx = i % 8
  buf[byte_idx] = (buf[byte_idx].to_int() | (1 << bit_idx)).to_byte()
}

///|
/// Read bit `i` from `bytes`. Assumes `0 <= i < bytes.length() * 8`.
fn bit_at(bytes : Bytes, i : Int) -> Bool {
  let byte_idx = i / 8
  let bit_idx = i % 8
  ((bytes[byte_idx].to_int() >> bit_idx) & 1) == 1
}

///|
/// Clear trailing bits past `len` in the final byte. No-op when `len` is
/// a multiple of 8 or zero. Used by `all_valid` so the popcount/null_count
/// remains correct over the full byte buffer.
fn mask_tail(buf : FixedArray[Byte], len : Int) -> Unit {
  if len <= 0 {
    return
  }
  let tail = len % 8
  if tail == 0 {
    return
  }
  let last = (len + 7) / 8 - 1
  let mask = (1 << tail) - 1
  buf[last] = (buf[last].to_int() & mask).to_byte()
}
