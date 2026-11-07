// Whitebox round-trips for the compact protocol — every primitive the
// metadata layer uses, written by the writer and read back by the reader,
// plus the unknown-field skip the forward-compatibility rule needs.

///|
test "compact round-trip: scalars, deltas, and the long-form id" {
  let w = thrift_writer()
  w.i32_field(1, 42)
  w.i64_field(2, -1234567890123L)
  w.field_header(3, 1)
  w.field_header(4, 2)
  w.text_field(5, "name")
  // A delta above 15 exercises the absolute-id spelling.
  w.i32_field(40, 7)
  w.struct_end()
  let bytes = w.finish()
  let r = thrift_reader(bytes)
  let mut last = 0
  let seen : Array[String] = []
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    match h.id {
      1 => seen.push("i32=\{r.zigzag_i32().unwrap()}")
      2 => seen.push("i64=\{r.zigzag_i64().unwrap()}")
      3 => seen.push("bool_true")
      4 => seen.push("bool_false")
      5 => seen.push("text=\{r.text().unwrap()}")
      40 => seen.push("long=\{r.zigzag_i32().unwrap()}")
      _ => {
        assert_true(r.skip(h.wire))
        seen.push("skipped")
      }
    }
  }
  assert_eq(seen, [
    "i32=42", "i64=-1234567890123", "bool_true", "bool_false", "text=name", "long=7",
  ])
}

///|
test "compact round-trip: nested struct and binary" {
  let w = thrift_writer()
  w.struct_field_begin(1)
  w.i32_field(2, 5)
  w.binary_field(3, b"\x01\x02\xff")
  w.struct_end()
  w.i64_field(9, 1L)
  w.struct_end()
  let r = thrift_reader(w.finish())
  let mut last = 0
  let mut outer = 0
  let inner : Array[String] = []
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    if h.id == 1 && h.wire is StructV {
      let mut last_inner = 0
      for ;; {
        let hi = r.field_header(last_inner).unwrap()
        if hi.wire is Stop {
          break
        }
        last_inner = hi.id
        if hi.id == 2 {
          inner.push("i=\{r.zigzag_i32().unwrap()}")
        } else if hi.id == 3 {
          let b = r.binary().unwrap()
          inner.push("len=\{b.length()}:0x\{b[0].to_int()}")
        }
      }
    } else if h.id == 9 {
      outer = r.zigzag_i64().unwrap().to_int()
    }
  }
  assert_eq(inner, ["i=5", "len=3:0x1"])
  assert_eq(outer, 1)
}

///|
test "the reader skips unknown fields by wire type" {
  // A struct carrying a binary (id 7), a list of i32 (id 8), and a
  // nested struct (id 9) around the known i32 at id 2 — reading only
  // the known field must land on the right bytes.
  let w = thrift_writer()
  w.i32_field(2, 11)
  w.binary_field(7, b"unknown")
  // A list of three varints, element wire type i32 (5).
  w.field_header(8, 9)
  w.list_header(3, 5)
  w.write_zigzag(1L)
  w.write_zigzag(2L)
  w.write_zigzag(3L)
  w.struct_field_begin(9)
  w.i32_field(1, 4)
  w.struct_end()
  w.struct_end()
  let r = thrift_reader(w.finish())
  let mut last = 0
  let mut value = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    if h.id == 2 {
      value = r.zigzag_i32().unwrap()
    } else {
      assert_true(r.skip(h.wire))
    }
  }
  assert_eq(value, 11)
}

///|
test "a byte field skips as its one raw byte" {
  // Wire type 3 (BYTE) carries a single raw byte, not the varint the
  // i16 / i32 family rides — the parquet metadata itself spells no byte
  // field, so the type matters to the unknown-field skip alone. A skip
  // that read it as a varint would swallow the next header's first byte
  // through the continuation bit, so the i32 after it reading back
  // proves the spelling. Bytes: field 1 (delta 1, type 3) + 0xAB, field
  // 2 (delta 1, type 5) + zigzag 11, stop.
  let bytes = Bytes::from_array([0x13, 0xAB, 0x15, 0x16, 0x00])
  let r = thrift_reader(bytes)
  let mut last = 0
  let mut value = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    if h.id == 1 {
      assert_true(h.wire is ByteV)
      assert_true(r.skip(h.wire))
    } else if h.id == 2 {
      value = r.zigzag_i32().unwrap()
    }
  }
  assert_eq(value, 11)
  // A byte field's payload cut short refuses rather than aborting: the
  // header byte is consumed, nothing follows it.
  let cut = thrift_reader(Bytes::from_array([0x13]))
  cut.pos = 1
  assert_true(!cut.skip(ByteV))
}

///|
test "a list of byte elements skips one byte each" {
  // Field 1 (delta 1, type 9), a two-element list of bytes (0x23: size
  // 2, element type 3), elements 0xAB / 0xCD — both past 0x80, so a
  // varint reading would fold the pair into one element and misalign
  // the field after it — then field 2's i32 and the stop.
  let bytes = Bytes::from_array([0x19, 0x23, 0xAB, 0xCD, 0x15, 0x16, 0x00])
  let r = thrift_reader(bytes)
  let mut last = 0
  let mut value = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    if h.id == 1 {
      assert_true(r.skip(h.wire))
    } else if h.id == 2 {
      value = r.zigzag_i32().unwrap()
    }
  }
  assert_eq(value, 11)
}

///|
test "a truncated buffer refuses instead of aborting" {
  let w = thrift_writer()
  w.binary_field(3, b"\x01\x02\x03")
  let whole = w.finish()
  for cut in 0..<whole.length() {
    let partial = Bytes::makei(cut, i => whole[i])
    let r = thrift_reader(partial)
    let h = r.field_header(0)
    // Whatever decodes, nothing aborts; a cut mid-value refuses.
    match h {
      Some(header) => if header.id == 3 { assert_true(r.binary() is None) }
      None => ()
    }
  }
}
