// The RLE / bit-packed hybrid the parquet definition levels and
// dictionary indices ride — one `bit_width`-wide run-length coding, the
// parquet spec's own encoding: a varint header whose low bit names the
// run kind (0 = RLE run: the header's high bits are the count, then one
// value; 1 = bit-packed run: the header's high bits are the number of
// *groups* of eight values, then that many byte-packed groups). Values
// are LSB-first: within a group, value `k`'s bit `b` lives at byte
// `(k·bit_width + b) / 8`, bit `(k·bit_width + b) % 8`.

///|
/// Decode a whole hybrid stream of `count` values at `bit_width` bits,
/// under the caller's own ceiling `limit` on the count — the chunk walk
/// passes the cells its budget has vouched for, so the decoder refuses a
/// count past it (a negative count the same way) before anything is
/// built by the number. Every value must fit an `Int32` (a def level is
/// 0/1; a dict index is bounded by the dictionary page the caller has
/// read), so widths above 31 refuse — no truncation could stay honest.
/// A short stream (a run past `count`, or the values running out
/// mid-run) refuses; the writer never produces either, and a hostile
/// file surfaces as a located error rather than a short column. The
/// output grows with what the stream actually decodes — never a
/// pre-allocation sized by the count alone — so a run's claimed
/// repetitions are bounded by the count the stream must fill, and a
/// short stream costs its own bytes, not the count's.
fn rle_decode(
  bytes : Bytes,
  count : Int32,
  bit_width : Int32,
  limit : Int32,
) -> (Array[Int32], Int32)? {
  // The second half of the answer is the stream.s own byte length —
  // where the PLAIN values that follow a level stream begin. Spelled
  // by the decoder itself (its reader already walked the bytes) rather
  // than a second walk that could drift from this one.
  if bit_width < 0 || bit_width > 31 || count < 0 || count > limit {
    return None
  }
  // Width 0: every value is the zero the width names — the writer emits
  // no bytes, and any stream decodes (only zeros are representable).
  // The count is already limit-bounded, so the zeros it names are
  // bounded with it.
  if bit_width == 0 {
    return Some((Array::makei(count, _ => 0), 0))
  }
  let out : Array[Int32] = []
  let r = thrift_reader(bytes)
  let mut written = 0
  while written < count {
    let header = match r.varint() {
      Some(v) => v
      None => return None
    }
    if (header & 1UL) == 0UL {
      // An RLE run: `header >> 1` repetitions of one value. The bound is
      // spelled `repetitions > count - written`, never `written +
      // repetitions > count`: `written` never passes `count` (the loop
      // guard), so the subtraction cannot overflow, while the addition
      // wraps on a hostile half-gigabyte run count and slips past.
      let repetitions = (header >> 1).to_int()
      if repetitions < 0 || repetitions > count - written {
        return None
      }
      let value = match read_bit_width(r, bit_width) {
        Some(v) => v
        None => return None
      }
      for _ in 0..<repetitions {
        out.push(value)
        written = written + 1
      }
    } else {
      // A bit-packed run: `(header >> 1)` groups of eight values.
      let groups = (header >> 1).to_int()
      if groups < 0 || groups > 0x1000_0000 {
        return None
      }
      // A bit-packed run's tail group pads to eight with zeros, so the
      // FINAL run may exceed the remaining count by up to seven — the
      // writer relies on exactly this; mid-stream runs may claim any
      // part of it. The bound is the division form of `groups * 8 >
      // remaining + 7`: the multiplication wraps at 0x1000_0000 groups,
      // and `remaining + 7` itself wraps with count near the Int32
      // ceiling, while `remaining >> 3` plus one can do neither.
      let remaining = count - written
      if groups > (remaining >> 3) + 1 {
        return None
      }
      for g in 0..<groups {
        // `g` stays below `groups`, so `g * 8` never passes `remaining`
        // and `base` never passes `count` — both stay inside Int32.
        let base = written + g * 8
        // The group's bytes first, then the values extracted out of
        // them — the reader is sequential, the scatter is not.
        let group : Array[Byte] = Array::make(bit_width, b'\x00')
        for at in 0..<bit_width {
          match r.byte() {
            Some(b) => group[at] = b.to_byte()
            None => return None
          }
        }
        // Only the values the count still needs land; a padded tail's
        // extra slots are read past (the bytes consumed, the values
        // dropped). The subtraction forms cannot wrap (`base` never
        // passes `count`), so `emit` is always 0..8 — and the pushes
        // stay in stream order, every group's emitted values right
        // behind the ones before it (`slot` is the group's own bit
        // position, not an output index).
        let emit = if count - base < 8 { count - base } else { 8 }
        for slot in 0..<emit {
          let mut value = 0
          for bit in 0..<bit_width {
            let flat = slot * bit_width + bit
            if ((group[flat / 8].to_int() >> (flat % 8)) & 1) != 0 {
              value = value | (1 << bit)
            }
          }
          out.push(value)
        }
      }
      // The whole run's slots are consumed — a padded tail's extras
      // past `count` write nothing and merely end the walk. The sum
      // rides an Int64 because a padded final run pushes `written`
      // past `count`, which near the Int32 ceiling would wrap.
      let advanced = written.to_int64() + groups.to_int64() * 8
      written = if advanced >= count.to_int64() {
        count
      } else {
        advanced.to_int()
      }
    }
  }
  Some((out, r.pos))
}

///|
/// One `bit_width`-wide value, LSB-first — the RLE run's payload.
fn read_bit_width(r : ThriftReader, bit_width : Int32) -> Int32? {
  let mut value = 0
  let mut shift = 0
  let mut remaining = bit_width
  while remaining > 0 {
    match r.byte() {
      Some(b) => {
        let take = if remaining >= 8 { 8 } else { remaining }
        value = value | ((b & ((1 << take) - 1)) << shift)
        shift = shift + 8
        remaining = remaining - 8
      }
      None => return None
    }
  }
  Some(value)
}

///|
/// Encode a whole hybrid stream at `bit_width` bits — the writer's
/// spelling: consecutive equal values ride one RLE run, any other
/// stretch rides bit-packed groups of eight. A group's tail pads to
/// eight with zeros — the spec's own tail rule — and because a padded
/// group injects its zeros as real values, padding is legal only at
/// the stream's END: a mid-stream stretch that would leave a partial
/// group (because an 8-plus run interrupts before eight accumulate)
/// falls back to one RLE run per value instead, which never pads.
fn rle_encode(values : Array[Int32], bit_width : Int32) -> Bytes {
  if bit_width == 0 {
    return Bytes::from_array([])
  }
  let buf : Array[Byte] = []
  let n = values.length()
  let mut i = 0
  while i < n {
    let v = values[i]
    let mut run = 1
    while i + run < n && values[i + run] == v {
      run = run + 1
    }
    if run >= 8 {
      push_rle_run(buf, run, v, bit_width)
      i = i + run
    } else {
      // Take the stretch up to the next 8-plus run (or the end).
      let start = i
      let mut end = i
      let mut interrupted = false
      while end < n {
        let w = values[end]
        let mut next_run = 1
        while end + next_run < n && values[end + next_run] == w {
          next_run = next_run + 1
        }
        if next_run >= 8 {
          interrupted = end < n
          break
        }
        end = end + 1
      }
      let total = end - start
      // A partial group before more stream follows cannot pad — the
      // zeros would precede real values. Each value rides its own
      // one-long RLE run instead.
      if interrupted && total % 8 != 0 {
        for k in 0..<total {
          push_rle_run(buf, 1, values[start + k], bit_width)
        }
        i = end
        continue
      }
      let groups = (total + 7) / 8
      push_varint_bytes(buf, (groups.to_uint64() << 1) | 1UL)
      for g in 0..<groups {
        // One group: `bit_width` bytes, every value's bits scattered
        // LSB-first into place.
        let group : Array[Byte] = Array::make(bit_width, b'\x00')
        for slot in 0..<8 {
          let idx = start + g * 8 + slot
          let value = if idx < end { values[idx] } else { 0 }
          for bit in 0..<bit_width {
            if ((value >> bit) & 1) != 0 {
              let flat = slot * bit_width + bit
              let at = flat / 8
              group[at] = (group[at].to_int() | (1 << (flat % 8))).to_byte()
            }
          }
        }
        for b in group {
          buf.push(b)
        }
      }
      i = end
    }
  }
  Bytes::from_array(buf)
}

///|
/// One RLE run: the count header (low bit 0) and the LSB-first value.
fn push_rle_run(
  buf : Array[Byte],
  count : Int32,
  value : Int32,
  bit_width : Int32,
) -> Unit {
  push_varint_bytes(buf, count.to_uint64() << 1)
  let mut remaining = bit_width
  let mut v = value
  while remaining > 0 {
    buf.push((v & 0xFF).to_byte())
    v = v >> 8
    remaining = remaining - 8
  }
}

///|
fn push_varint_bytes(buf : Array[Byte], v : UInt64) -> Unit {
  let mut rest = v
  for ;; {
    if rest < 0x80UL {
      buf.push(rest.to_byte())
      break
    }
    buf.push(((rest & 0x7FUL) | 0x80UL).to_byte())
    rest = rest >> 7
  }
}
