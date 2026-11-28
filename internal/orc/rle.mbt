// The run length encodings the streams are spelled in: the byte run
// length encoding of the present streams and of the boolean and byte
// columns; the integer run length encoding of the 0.11 format, with its
// runs and its literals; and the 0.12 format's four spellings — short
// repeat, direct, patched base and delta. A decoder reads one stream
// whole, from its first run to the run that answers its column's last
// value, and a stream that breaks off before then raises.

///|
/// The integer run length encoding a column's encoding kind names: DIRECT
/// and DICTIONARY spell the 0.11 format's, DIRECT_V2 and DICTIONARY_V2
/// the 0.12 format's.
priv enum Rle {
  V1
  V2
}

///|
/// `count` bytes of a byte run length stream into `out`: a header below
/// 128 names a run of header + 3 equal bytes, whose byte follows; a
/// header of 128 or more names 256 - header literal bytes. The last run
/// may hold more than `count`: the stream ends where its column does.
fn byte_rle(
  c : Cursor,
  count : Int32,
  out : Array[Byte],
) -> Unit raise @types.DataError {
  let mut left = count
  while left > 0 {
    let header = c.byte()
    if header < 128 {
      let value = c.byte().to_byte()
      let run = if header + 3 < left { header + 3 } else { left }
      for _ in 0..<run {
        out.push(value)
      }
      left = left - run
    } else {
      let run = if 256 - header < left { 256 - header } else { left }
      for _ in 0..<run {
        out.push(c.byte().to_byte())
      }
      left = left - run
    }
  }
}

///|
/// `count` bits of a boolean run length stream, most significant bit
/// first: the bits are packed eight to a byte, and the bytes are byte run
/// length encoded.
fn boolean_rle(c : Cursor, count : Int32) -> Array[Bool] raise @types.DataError {
  let packed : Array[Byte] = []
  byte_rle(c, (count + 7) / 8, packed)
  let out : Array[Bool] = []
  for i in 0..<count {
    out.push(((packed[i / 8].to_int() >> (7 - i % 8)) & 1) == 1)
  }
  out
}

///|
/// The integer one varint names: zigzag coded when the stream is signed,
/// plain when it is not.
fn varint_value(c : Cursor, signed : Bool) -> Int64 raise @types.DataError {
  if signed {
    c.zigzag()
  } else {
    c.varint().reinterpret_as_int64()
  }
}

///|
/// `count` integers of an integer run length stream spelled in `rle`:
/// zigzag coded when `signed`, plain when not. The last run may hold more
/// values than the column needs.
fn Rle::ints(
  self : Rle,
  c : Cursor,
  signed : Bool,
  count : Int32,
) -> Array[Int64] raise @types.DataError {
  let out : Array[Int64] = []
  let mut left = count
  while left > 0 {
    match self {
      V1 => left = left - v1_run(c, signed, left, out)
      V2 => left = left - v2_run(c, signed, left, out)
    }
  }
  out
}

///|
/// One run of the 0.11 format's integer encoding: a header below 128
/// names a run of header + 3 values a fixed delta apart, the delta a byte
/// and the first value a varint; a header of 128 or more names 256 -
/// header literal values, a varint each. The values pushed are at most
/// `left`; the run's length is answered.
fn v1_run(
  c : Cursor,
  signed : Bool,
  left : Int32,
  out : Array[Int64],
) -> Int32 raise @types.DataError {
  let header = c.byte()
  if header < 128 {
    let raw_delta = c.byte()
    let delta = if raw_delta < 128 {
      raw_delta.to_int64()
    } else {
      raw_delta.to_int64() - 256L
    }
    let first = varint_value(c, signed)
    let run = if header + 3 < left { header + 3 } else { left }
    for i in 0..<run {
      out.push(first + delta * i.to_int64())
    }
    run
  } else {
    let run = if 256 - header < left { 256 - header } else { left }
    for _ in 0..<run {
      out.push(varint_value(c, signed))
    }
    run
  }
}

///|
/// The bit width a run header's five bits name — the 0.12 format's table:
/// every width from one bit to twenty-four, then the even ones and the
/// byte-aligned ones to sixty-four.
fn bit_width(encoded : Int32) -> Int32 {
  match encoded {
    24 => 26
    25 => 28
    26 => 30
    27 => 32
    28 => 40
    29 => 48
    30 => 56
    31 => 64
    _ => encoded + 1
  }
}

///|
/// The fixed bit width a patch list entry is packed in: the smallest of
/// the format's widths that holds the sum of a patch's width and its
/// gap's.
fn closest_width(total : Int32) -> Int32 {
  if total <= 24 {
    total
  } else if total <= 26 {
    26
  } else if total <= 28 {
    28
  } else if total <= 30 {
    30
  } else if total <= 32 {
    32
  } else if total <= 40 {
    40
  } else if total <= 48 {
    48
  } else if total <= 56 {
    56
  } else {
    64
  }
}

///|
/// The bit reader of the 0.12 format's packed runs: a run's values ride
/// whole bytes, most significant bit first, and the bits left in the last
/// byte are dropped.
priv struct Packed {
  c : Cursor
  mut byte : Int32
  mut bits : Int32
}

///|
/// The next `width` bits as an unsigned value.
fn Packed::take(self : Packed, width : Int32) -> UInt64 raise @types.DataError {
  let mut value : UInt64 = 0UL
  for _ in 0..<width {
    if self.bits == 0 {
      self.byte = self.c.byte()
      self.bits = 8
    }
    self.bits = self.bits - 1
    value = (value << 1) | ((self.byte >> self.bits) & 1).to_uint64()
  }
  value
}

///|
/// The integer one packed value names: zigzag coded when the stream is
/// signed, plain when it is not.
fn packed_value(u : UInt64, signed : Bool) -> Int64 {
  if signed {
    unzigzag(u)
  } else {
    u.reinterpret_as_int64()
  }
}

///|
/// One run of the 0.12 format's integer encoding, of the four kinds its
/// first byte's top two bits name. The values pushed are at most `left`;
/// the run's length is answered.
fn v2_run(
  c : Cursor,
  signed : Bool,
  left : Int32,
  out : Array[Int64],
) -> Int32 raise @types.DataError {
  let header_at = c.offset()
  let first = c.byte()
  match first >> 6 {
    0 => {
      // Short repeat: three bits the repeating value's width in bytes,
      // three its count above two, then the value, big endian.
      let width = ((first >> 3) & 7) + 1
      let value = packed_value(c.be(width), signed)
      let run = if (first & 7) + 3 < left { (first & 7) + 3 } else { left }
      for _ in 0..<run {
        out.push(value)
      }
      run
    }
    1 =>
      // Direct: five bits the values' width, nine their count below one,
      // then the values packed.
      direct_run(c, signed, left, out, (first >> 1) & 31, first & 1)
    2 => patched_run(c, left, out, header_at, (first >> 1) & 31, first & 1)
    _ =>
      delta_run(c, signed, left, out, header_at, (first >> 1) & 31, first & 1)
  }
}

///|
/// The nine bits of a run's length that follow its first byte: the first
/// byte's last bit above, eight more below, one less than the count.
fn run_length(c : Cursor, high : Int32) -> Int32 raise @types.DataError {
  ((high << 8) | c.byte()) + 1
}

///|
/// A direct run: `count` values of the width the header names, packed.
fn direct_run(
  c : Cursor,
  signed : Bool,
  left : Int32,
  out : Array[Int64],
  encoded : Int32,
  high : Int32,
) -> Int32 raise @types.DataError {
  let packed = Packed::{ c, byte: 0, bits: 0, }
  let width = bit_width(encoded)
  let count = run_length(c, high)
  for i in 0..<count {
    let value = packed_value(packed.take(width), signed)
    if i < left {
      out.push(value)
    }
  }
  if count < left {
    count
  } else {
    left
  }
}

///|
/// The gap and the patch one patch list entry names, and the entry the
/// next one is: a patch of zero with a gap of 255 skips 255 values, and
/// may repeat. The caller holds an entry for `start` — a run's patch
/// list is never empty, and the next is asked for only while one is
/// left — but a skip may run past the list's end, and that is the
/// refusal.
fn adjust_gap(
  patches : Array[UInt64],
  start : Int32,
  patch_width : Int32,
  patch_mask : Int64,
  c : Cursor,
) -> (Int64, Int64, Int32) raise @types.DataError {
  let mut index = start
  let mut gap = (patches[start] >> patch_width).reinterpret_as_int64()
  let mut patch = patches[start].reinterpret_as_int64() & patch_mask
  let mut skipped = 0L
  while gap == 255L && patch == 0L {
    skipped = skipped + 255L
    index = index + 1
    let next = match patches.get(index) {
      Some(e) => e
      None => raise c.bad("the bytes hold a patch list that ends inside a gap")
    }
    gap = (next >> patch_width).reinterpret_as_int64()
    patch = next.reinterpret_as_int64() & patch_mask
  }
  (skipped + gap, patch, index)
}

///|
/// A patched base run: five bits the values' width and nine their count
/// below one; then a byte naming the base's width in bytes and the
/// patches' width; then a byte naming the gaps' width in bits and the
/// patch list's length; the base, big endian with its top bit a sign; the
/// values, packed offsets above the base; and the patch list, each entry a
/// gap above the last patch and the value's missing high bits, packed in
/// the width that holds both. A patch is laid over its value's low bits
/// and the base added.
fn patched_run(
  c : Cursor,
  left : Int32,
  out : Array[Int64],
  header_at : Int32,
  encoded : Int32,
  high : Int32,
) -> Int32 raise @types.DataError {
  let count = run_length(c, high)
  let third = c.byte()
  let base_width = ((third >> 5) & 7) + 1
  let patch_width = bit_width(third & 31)
  let fourth_at = c.offset()
  let fourth = c.byte()
  let gap_width = ((fourth >> 5) & 7) + 1
  let patch_count = fourth & 31
  if patch_count == 0 {
    raise c.bad_at(fourth_at, "the bytes hold a patched base run with no patch")
  }
  if patch_width + gap_width > 64 {
    let error = c.bad_at(
      header_at, "the bytes hold a patched base run whose patch and gap widths pass 64 bits",
    )
    raise error
  }
  let raw_base = c.be(base_width)
  let sign = 1UL << (base_width * 8 - 1)
  let base = if (raw_base & sign) == 0UL {
    raw_base.reinterpret_as_int64()
  } else {
    -(raw_base & sign.lnot()).reinterpret_as_int64()
  }
  let packed = Packed::{ c, byte: 0, bits: 0, }
  let width = bit_width(encoded)
  let values : Array[Int64] = []
  for _ in 0..<count {
    values.push(packed.take(width).reinterpret_as_int64())
  }
  // The patch list starts at the next byte: the bits the values left in
  // their last byte are dropped.
  packed.bits = 0
  let slot = closest_width(patch_width + gap_width)
  let patches : Array[UInt64] = []
  for _ in 0..<patch_count {
    patches.push(packed.take(slot))
  }
  let patch_mask = (1UL << patch_width).reinterpret_as_int64() - 1L
  let (gap, patch, used) = adjust_gap(patches, 0, patch_width, patch_mask, c)
  let mut at = gap
  let mut high_bits = patch
  let mut next = used
  for i in 0..<count {
    let value = if i.to_int64() == at {
      // A patch sits above the value's own bits; a width of 64 leaves
      // it no room, and the patch is nothing there.
      let shifted = if width >= 64 { 0L } else { high_bits << width }
      next = next + 1
      if next < patch_count {
        let (gap, patch, used) = adjust_gap(
          patches, next, patch_width, patch_mask, c,
        )
        at = gap + i.to_int64()
        high_bits = patch
        next = used
      }
      base + (values[i] | shifted)
    } else {
      values[i] + base
    }
    if i < left {
      out.push(value)
    }
  }
  if count < left {
    count
  } else {
    left
  }
}

///|
/// A delta run: five bits the deltas' width — zero when every delta is
/// the one the run names — and nine their count below one; the first
/// value and the first delta as varints, the delta always zigzag coded;
/// then the deltas after the first, packed, to be added when the first
/// delta is positive and subtracted when it is negative.
fn delta_run(
  c : Cursor,
  signed : Bool,
  left : Int32,
  out : Array[Int64],
  header_at : Int32,
  encoded : Int32,
  high : Int32,
) -> Int32 raise @types.DataError {
  let width = if encoded == 0 { 0 } else { bit_width(encoded) }
  let count = run_length(c, high)
  let first = varint_value(c, signed)
  let delta_base = c.zigzag()
  if width == 0 {
    for i in 0..<count {
      if i < left {
        out.push(first + delta_base * i.to_int64())
      }
    }
    if count < left {
      count
    } else {
      left
    }
  } else {
    if count < 2 {
      let error = c.bad_at(
        header_at, "the bytes hold a delta run of one value with a bit width",
      )
      raise error
    }
    let packed = Packed::{ c, byte: 0, bits: 0, }
    if left > 0 {
      out.push(first)
    }
    let mut previous = first + delta_base
    if left > 1 {
      out.push(previous)
    }
    for i in 2..<count {
      let delta = packed.take(width).reinterpret_as_int64()
      previous = if delta_base < 0L {
        previous - delta
      } else {
        previous + delta
      }
      if i < left {
        out.push(previous)
      }
    }
    if count < left {
      count
    } else {
      left
    }
  }
}
