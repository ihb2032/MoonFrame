// The UTF-8 string buffer: Arrow's string-array layout — one concatenated
// `Bytes` of UTF-8 value bytes plus `len + 1` cell-boundary offsets. This is
// the shape FFI and columnar interchange need, and the reason a string column
// cannot stay an array of boxed UTF-16 `String`s: a buffer must flatten to
// `bytes + offsets` without re-encoding every cell.
//
// Decoding to MoonBit's `String` happens at the read edge (`get` /
// `to_strings`), one `String` per cell — that is a language boundary (the
// regex engine, hashing, and `Map` keys all speak `String`), not a design
// choice the buffer makes. Writers encode once at construction.

///|
/// An immutable UTF-8 string buffer: `len` cells over concatenated value
/// bytes, `offsets[i] ..< offsets[i + 1]` the byte range of cell `i`. Null
/// slots are the caller's convention — MoonFrame writes the empty byte
/// range there, paired with the column's validity bitmap. Immutable, so
/// `slice_view` can share the byte buffer across views.
pub struct Utf8Array {
  priv bytes : Bytes
  // Byte offset of cell 0 within `bytes` — non-zero only for a zero-copy
  // `slice_view`, whose offsets are re-based to 0 while the shared buffer
  // keeps its parent's cell 0 at the front.
  priv base : Int
  priv offsets : FixedArray[Int]
  priv len : Int
} derive(Debug)

///|
pub extend Utf8Array with Debug::{to_repr}

// ── Constructors ──────────────────────────────────────────────────────

///|
/// Encode `values` (already placeholder-filled: a null slot arrives as `""`)
/// into one UTF-8 buffer. `values` is copied, so the buffer is unaffected by
/// later mutation of the array.
pub fn Utf8Array::from_strings(values : Array[String]) -> Utf8Array {
  let bytes = FixedArray::make(total_encoded_len(values), (0 : Byte))
  let offsets : FixedArray[Int] = FixedArray::make(values.length() + 1, 0)
  let mut at = 0
  for i, v in values {
    at = at + encode_into(v, bytes, at)
    offsets[i + 1] = at
  }
  {
    bytes: Bytes::from_array(Array::from_fixed_array(bytes)),
    base: 0,
    offsets,
    len: values.length(),
  }
}

///|
/// Encode optional strings, `None` slots as the empty byte range (the null
/// placeholder paired with the column's validity bitmap).
pub fn Utf8Array::from_string_options(values : Array[String?]) -> Utf8Array {
  Utf8Array::from_strings(values.map(v => v.unwrap_or("")))
}

///|
/// Sum of the UTF-8 encodings' byte lengths — the exact value-buffer size,
/// allocated once instead of grown per cell. Same walk as `encode_into`, so
/// the two always agree.
fn total_encoded_len(values : Array[String]) -> Int {
  let mut total = 0
  for v in values {
    total = total + encoded_len(v)
  }
  total
}

///|
/// UTF-8 byte length of one string's encoding. Walks UTF-16 code units with
/// `encode_into`'s exact rules, so the two never disagree on a length.
fn encoded_len(s : String) -> Int {
  let n = s.length()
  let mut len = 0
  let mut i = 0
  while i < n {
    let u = s[i].to_int()
    if u < 0x80 {
      len = len + 1
      i = i + 1
    } else if u < 0x800 {
      len = len + 2
      i = i + 1
    } else if u >= 0xD800 && u <= 0xDBFF && i + 1 < n {
      let v = s[i + 1].to_int()
      if v >= 0xDC00 && v <= 0xDFFF {
        len = len + 4
        i = i + 2
      } else {
        // High surrogate whose pair is missing or not a low surrogate: the
        // WTF-8 3-byte spelling, so the cell round-trips (see `encode_into`).
        len = len + 3
        i = i + 1
      }
    } else {
      len = len + 3
      i = i + 1
    }
  }
  len
}

///|
/// Encode one string's UTF-16 code units into `buf` starting at `at`,
/// returning the byte count written. Total — MoonBit strings can legally
/// hold an unpaired surrogate half, and core's encoder *aborts* on one, so
/// this encoder writes the WTF-8 3-byte spelling for it instead: the cell
/// round-trips through `decode_cell` byte-exact, and the write paths keep
/// their own refuse-rather-than-corrupt surrogate check.
fn encode_into(s : String, buf : FixedArray[Byte], at : Int) -> Int {
  let n = s.length()
  let mut p = at
  let mut i = 0
  while i < n {
    let u = s[i].to_int()
    if u < 0x80 {
      buf[p] = u.to_byte()
      p = p + 1
      i = i + 1
    } else if u < 0x800 {
      buf[p] = (0xC0 | (u >> 6)).to_byte()
      buf[p + 1] = (0x80 | (u & 0x3F)).to_byte()
      p = p + 2
      i = i + 1
    } else if u >= 0xD800 && u <= 0xDBFF && i + 1 < n {
      let v = s[i + 1].to_int()
      if v >= 0xDC00 && v <= 0xDFFF {
        let cp = 0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00)
        buf[p] = (0xF0 | (cp >> 18)).to_byte()
        buf[p + 1] = (0x80 | ((cp >> 12) & 0x3F)).to_byte()
        buf[p + 2] = (0x80 | ((cp >> 6) & 0x3F)).to_byte()
        buf[p + 3] = (0x80 | (cp & 0x3F)).to_byte()
        p = p + 4
        i = i + 2
      } else {
        p = p + encode_wtf8_unit(u, buf, p)
        i = i + 1
      }
    } else {
      // A lone surrogate half (or any other 3-byte unit) — the surrogate
      // spelling keeps it recoverable.
      p = p + encode_wtf8_unit(u, buf, p)
      i = i + 1
    }
  }
  p - at
}

///|
/// The 3-byte encoding of one UTF-16 unit outside the ASCII / 2-byte ranges.
/// For a surrogate unit this is the WTF-8 spelling of the half itself.
fn encode_wtf8_unit(u : Int, buf : FixedArray[Byte], at : Int) -> Int {
  buf[at] = (0xE0 | (u >> 12)).to_byte()
  buf[at + 1] = (0x80 | ((u >> 6) & 0x3F)).to_byte()
  buf[at + 2] = (0x80 | (u & 0x3F)).to_byte()
  3
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// Number of cells.
pub fn Utf8Array::len(self : Utf8Array) -> Int {
  self.len
}

///|
/// Decode cell `i` into a `String` (UTF-8 → UTF-16). `i` must be in
/// `[0, len)`. The decode is the inverse of `encode_into`: well-formed UTF-8
/// decodes normally and a WTF-8-encoded surrogate half comes back as the
/// half itself, so a cell round-trips byte-exact.
pub fn Utf8Array::get(self : Utf8Array, i : Int) -> String {
  let start = self.base + self.offsets[i]
  let end = self.base + self.offsets[i + 1]
  let buf = StringBuilder()
  let mut p = start
  while p < end {
    let b0 = self.bytes[p].to_int()
    let cp = if b0 < 0x80 {
      p = p + 1
      b0
    } else if b0 < 0xE0 {
      let cp = ((b0 & 0x1F) << 6) | (self.bytes[p + 1].to_int() & 0x3F)
      p = p + 2
      cp
    } else if b0 < 0xF0 {
      let cp = ((b0 & 0x0F) << 12) |
        ((self.bytes[p + 1].to_int() & 0x3F) << 6) |
        (self.bytes[p + 2].to_int() & 0x3F)
      p = p + 3
      cp
    } else {
      let cp = ((b0 & 0x07) << 18) |
        ((self.bytes[p + 1].to_int() & 0x3F) << 12) |
        ((self.bytes[p + 2].to_int() & 0x3F) << 6) |
        (self.bytes[p + 3].to_int() & 0x3F)
      p = p + 4
      cp
    }
    // A supplementary code point writes as its surrogate pair; a WTF-8
    // surrogate half writes as the single unit it is.
    buf.write_char(cp.unsafe_to_char())
  }
  buf.to_string()
}

///|
/// Decode every cell, in order — the bulk read for consumers that keep
/// materialised `String`s (sort keys, kernel string ops).
pub fn Utf8Array::to_strings(self : Utf8Array) -> Array[String] {
  Array::makei(self.len, i => self.get(i))
}

///|
/// Byte-wise equality of two cells — UTF-8 byte order is code-point order,
/// so this is exactly `String` equality without decoding either cell.
pub fn Utf8Array::cell_eq(
  self : Utf8Array,
  i : Int,
  other : Utf8Array,
  j : Int,
) -> Bool {
  let a0 = self.base + self.offsets[i]
  let a1 = self.base + self.offsets[i + 1]
  let b0 = other.base + other.offsets[j]
  let b1 = other.base + other.offsets[j + 1]
  if a1 - a0 != b1 - b0 {
    return false
  }
  let span = a1 - a0
  for k in 0..<span {
    if self.bytes[a0 + k] != other.bytes[b0 + k] {
      return false
    }
  }
  true
}

// ── Transforms ────────────────────────────────────────────────────────

///|
/// Zero-copy view of `[start, start + length)` — the value half of
/// `BuiltinColumn::slice_unchecked`. The byte buffer is shared; only the
/// offsets window is re-based (an `O(length)` offsets copy, the same class
/// as the paired validity view's bit pack). The caller must keep
/// `0 <= start` and `start + length <= len`, as `slice` guarantees.
pub fn Utf8Array::slice_view(
  self : Utf8Array,
  start : Int,
  length : Int,
) -> Utf8Array {
  let start_off = self.offsets[start]
  let offsets : FixedArray[Int] = FixedArray::make(length + 1, 0)
  for i in 0..<=length {
    offsets[i] = self.offsets[start + i] - start_off
  }
  { bytes: self.bytes, base: self.base + start_off, offsets, len: length, }
}

///|
/// Gather core: a new buffer whose i-th cell is `self[indices[i]]`, copying
/// each selected cell's byte range into a fresh value buffer (the caller's
/// indices are already bounds-checked; a gather re-orders, so the bytes
/// cannot simply be shared). Cell bytes are copied verbatim — no decode /
/// re-encode round-trip.
pub fn Utf8Array::take_view(
  self : Utf8Array,
  indices : Array[Int],
) -> Utf8Array {
  let n = indices.length()
  let lens : FixedArray[Int] = FixedArray::make(n, 0)
  let mut total = 0
  for k in 0..<n {
    let i = indices[k]
    let l = self.offsets[i + 1] - self.offsets[i]
    lens[k] = l
    total = total + l
  }
  let bytes = FixedArray::make(total, (0 : Byte))
  let offsets : FixedArray[Int] = FixedArray::make(n + 1, 0)
  let mut at = 0
  for k in 0..<n {
    let src = self.offsets[indices[k]]
    for b in 0..<lens[k] {
      bytes[at + b] = self.bytes[src + b]
    }
    at = at + lens[k]
    offsets[k + 1] = at
  }
  {
    bytes: Bytes::from_array(Array::from_fixed_array(bytes)),
    base: 0,
    offsets,
    len: n,
  }
}
