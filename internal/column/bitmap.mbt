///|
/// Apache Arrow compatible validity bitmap.
///
/// Bits are packed into bytes, **1 bit per row, 1 = valid, 0 = null**.
/// Logical slot `i` lives at physical bit `offset + i`: byte
/// `bits[(offset + i) / 8]`, bit position `(offset + i) % 8`, where bit `0`
/// is the least-significant bit of the byte. `offset` is `0` for every
/// bitmap a constructor builds (each packs a tight buffer of exactly
/// `⌈len / 8⌉` bytes, with the trailing bits past `len` kept zero); a
/// zero-copy `slice` instead shares its parent's buffer and advances
/// `offset`, so a view's buffer may be longer than `⌈len / 8⌉` bytes and
/// hold sibling bits outside `[offset, offset + len)`. `Bytes` is
/// immutable, so sharing one buffer across views is safe. Equality is
/// logical — over the `[offset, offset + len)` window — and `null_count`
/// counts only that window.
///
/// The convention `1 = valid` matches the Apache Arrow specification (and
/// `arrow-rs`, `pyarrow`); note that some MoonBit ecosystem libraries (e.g.
/// `smallbearrr/pandas`) use the opposite convention.
pub struct Bitmap {
  bits : Bytes
  offset : Int
  len : Int
} derive(Debug)

///|
/// Logical equality: two bitmaps are equal iff they have the same length
/// and the same validity bit at every logical slot. The comparison walks
/// the `[offset, offset + len)` windows rather than the raw buffers, so a
/// zero-copy `slice` view equals a freshly packed bitmap with the same bits
/// (a derived structural `Eq` would compare `offset` / buffer identity and
/// wrongly call them unequal). For two tight, offset-0 bitmaps — every
/// bitmap before `slice` views existed — this agrees bit-for-bit with the
/// old structural equality.
pub impl Eq for Bitmap with fn equal(self, other) {
  if self.len != other.len {
    false
  } else {
    let mut equal = true
    for i in 0..<self.len {
      if bit_at(self.bits, self.offset + i) !=
        bit_at(other.bits, other.offset + i) {
        equal = false
        break
      }
    }
    equal
  }
}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// All `len` slots marked valid. A negative `len` clamps to 0 (an empty
/// bitmap): these two constructors are the only place a caller-supplied
/// length becomes a bitmap's `len`, and a negative `len` stored verbatim
/// would desynchronise `len` from the (empty) buffer — `null_count`'s
/// tail-byte read would then index past it and abort, the one failure mode
/// the never-abort rule forbids.
pub fn Bitmap::all_valid(len : Int) -> Bitmap {
  let len = if len < 0 { 0 } else { len }
  let n = bytes_needed(len)
  let buf = FixedArray::make(n, (0xff : Int).to_byte())
  mask_tail(buf, len)
  { bits: buffer_to_bytes(buf), offset: 0, len }
}

///|
/// All `len` slots marked null. A negative `len` clamps to 0, exactly as
/// in `all_valid` (and for the same reason).
pub fn Bitmap::all_null(len : Int) -> Bitmap {
  let len = if len < 0 { 0 } else { len }
  {
    bits: buffer_to_bytes(FixedArray::make(bytes_needed(len), Byte::default())),
    offset: 0,
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
  bit_at(self.bits, self.offset + index)
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
/// `true` when slot `index` is valid (bit 1), **total**: an out-of-range
/// `index` yields `false` instead of raising. The single-slot counterpart of
/// `is_valid`, for the in-bounds-guaranteed row gathers that read one slot at a
/// time off the source mask rather than materialising the whole `Array[Bool]`
/// — so a per-group gather costs `O(gathered)`, not `O(source)`.
pub fn Bitmap::is_valid_total(self : Bitmap, index : Int) -> Bool {
  if index < 0 || index >= self.len {
    false
  } else {
    bit_at(self.bits, self.offset + index)
  }
}

///|
/// Number of null (0) bits in the logical range `[offset, offset + len)`.
///
/// When `offset == 0` the window is byte-aligned at the front, so the full
/// bytes `[0, len / 8)` are popcounted whole (one `popcount_byte` per 8
/// slots) and only the final partial byte is masked down to its in-window
/// bits `[0, len % 8)`. That mask is essential: a zero-copy `slice` view
/// shares its parent's buffer, so the bits past `len` in that last byte may
/// be live sibling bits — popcounting them unmasked would over-count valids
/// (and a constructor-built bitmap keeps those bits zero, so the mask is a
/// no-op there). An `offset != 0` view has no byte-aligned start, so it
/// counts its window bit by bit.
pub fn Bitmap::null_count(self : Bitmap) -> Int {
  if self.offset == 0 {
    let full = self.len / 8
    let mut valid = 0
    for i in 0..<full {
      valid = valid + popcount_byte(self.bits[i])
    }
    let tail = self.len % 8
    if tail != 0 {
      let mask = (1 << tail) - 1
      valid = valid + popcount_byte((self.bits[full].to_int() & mask).to_byte())
    }
    self.len - valid
  } else {
    let mut valid = 0
    for i in 0..<self.len {
      if bit_at(self.bits, self.offset + i) {
        valid = valid + 1
      }
    }
    self.len - valid
  }
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
  Array::makei(self.len, i => bit_at(self.bits, self.offset + i))
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// Half-open `[start, start + length)` slice as a **zero-copy view**: the
/// result shares this bitmap's underlying buffer and only advances `offset`
/// by `start`, so a slice is `O(1)` with no repacking. Safe because `Bytes`
/// is immutable. Errors:
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
    raise @types.DataError::InvalidOperation("slice length < 0: \{length}")
  }
  // Compare against the remaining room, not `start + length`: `start` is already
  // in `[0, len]`, so `len - start` cannot overflow, whereas a near-`Int::MAX`
  // `length` would wrap `start + length` negative and slip past this guard —
  // producing an over-long view over a tiny buffer that a later read aborts on.
  // (`bytes_needed` dodges the same `len + 7` overflow.) The error payload
  // computes the offending end overflow-safely too — saturating instead of
  // wrapping into a nonsense negative "index" that would misdirect debugging.
  if length > self.len - start {
    let end = if length > 0x7fffffff - start {
      0x7fffffff
    } else {
      start + length
    }
    raise @types.DataError::IndexOutOfBounds(end)
  }
  self.slice_view(start, length)
}

///|
/// Total zero-copy view of `[start, start + length)` — the shared core
/// behind `slice` (which validates the bounds then calls this) and the total
/// `BuiltinColumn::slice_unchecked`. It just shares the buffer and advances
/// `offset`, so the caller must keep `0 <= start` and
/// `start + length <= len`; both delegators guarantee that.
fn Bitmap::slice_view(self : Bitmap, start : Int, length : Int) -> Bitmap {
  { bits: self.bits, offset: self.offset + start, len: length }
}

///|
/// Gather: produce a new bitmap whose i-th bit is `self[indices[i]]`. Any
/// out-of-bounds index `raise IndexOutOfBounds(idx)`. Unlike
/// `slice`, an arbitrary gather can't be expressed as a contiguous view, so
/// `take` repacks into a fresh tight buffer (reading each source bit through
/// this bitmap's `offset`).
pub fn Bitmap::take(
  self : Bitmap,
  indices : Array[Int],
) -> Bitmap raise @types.DataError {
  for i in indices {
    if i < 0 || i >= self.len {
      raise @types.DataError::IndexOutOfBounds(i)
    }
  }
  self.take_view(indices)
}

///|
/// Total gather core behind `take`: a new bitmap whose i-th bit is
/// `self[indices[i]]`, **without** bounds-checking the indices — the gather
/// counterpart of `slice_view`. Shared by `take` (which validates first) and
/// `BuiltinColumn::take` (whose `validate_gather_indices` has already checked
/// the same indices against the same length), so a gather is bounds-checked
/// exactly once. An out-of-range index reads as `false` via `is_valid_total`
/// rather than aborting, so a caller that breaks the in-bounds contract still
/// cannot panic.
fn Bitmap::take_view(self : Bitmap, indices : Array[Int]) -> Bitmap {
  pack(indices.length(), i => self.is_valid_total(indices[i]))
}

///|
/// Bitwise AND across two bitmaps of the same logical length — a public
/// utility for combining two validity masks into one. Named `bit_and`
/// because `and` is a reserved keyword in MoonBit. Raises `LengthMismatch`
/// if the lengths differ.
pub fn Bitmap::bit_and(
  self : Bitmap,
  other : Bitmap,
) -> Bitmap raise @types.DataError {
  if self.len != other.len {
    raise @types.DataError::LengthMismatch
  }
  pack(self.len, i => {
    bit_at(self.bits, self.offset + i) && bit_at(other.bits, other.offset + i)
  })
}

// ── Internal helpers ──────────────────────────────────────────────────

///|
/// Build a bitmap of `len` slots whose `i`-th bit is `1` (valid) exactly
/// when `valid(i)` is true. This is the closure-parameterised core shared by
/// every constructor and transform that packs per-slot validity into a fresh
/// byte buffer (`from_bools`, `from_options`, `take`, `bit_and`); each caller
/// supplies only its own `valid` predicate. The result is tight (`offset =
/// 0`, buffer exactly `⌈len / 8⌉` bytes). `valid` runs once per slot in
/// `[0, len)`, so the caller must keep every index it reads (e.g.
/// `offset + indices[i]`, `offset + i`) within bounds.
fn pack(len : Int, valid : (Int) -> Bool) -> Bitmap {
  let buf = FixedArray::make(bytes_needed(len), Byte::default())
  for i in 0..<len {
    if valid(i) {
      set_bit_unchecked(buf, i)
    }
  }
  { bits: buffer_to_bytes(buf), offset: 0, len }
}

///|
/// `⌈len / 8⌉`, clamped to 0 for non-positive `len`. Computed without a
/// `len + 7` term so it never overflows `Int`, even for a `len` near
/// `Int::MAX` (the result stays total — `all_valid` / `all_null` / `pack`
/// pass it to `FixedArray::make`, which aborts on a negative size).
fn bytes_needed(len : Int) -> Int {
  if len <= 0 {
    0
  } else {
    len / 8 + (if len % 8 == 0 { 0 } else { 1 })
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
/// Population count of one byte (number of 1 bits) via the classic SWAR
/// bit-folding — no lookup table and no backend-specific intrinsic, so it is
/// identical across wasm / wasm-gc / js / native. Backs `null_count`'s
/// byte-at-a-time valid-bit count.
fn popcount_byte(b : Byte) -> Int {
  // `b` is a Byte, so `to_int()` is already in 0..=255 — masking is a no-op.
  let mut x = b.to_int()
  x = x - ((x >> 1) & 0x55)
  x = (x & 0x33) + ((x >> 2) & 0x33)
  (x + (x >> 4)) & 0x0f
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
  // The final byte holds bits in `[8 * (len / 8), len)`; with `tail != 0` here
  // that byte sits at index `len / 8`, equal to the old `(len + 7) / 8 - 1` but
  // without its `len + 7` Int overflow on a near-`Int::MAX` `len` (the same
  // overflow `bytes_needed` is documented to avoid).
  let last = len / 8
  let mask = (1 << tail) - 1
  buf[last] = (buf[last].to_int() & mask).to_byte()
}
