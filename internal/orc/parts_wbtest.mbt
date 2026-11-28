// Whitebox tests of the reader's parts in isolation: the lines a file
// cannot reach. Every caller of the byte cursor's `take` proves the bytes
// are there before asking, and no file under a compression kind of none
// comes to the block inflater or the kind's name: these pin them. The
// blackbox suite compares every cell with what the reference reader gets
// and every refusal with its sidecar's text; these are the ends of the
// parts the files leave alone.

///|
test "a block stored as it is inflates to itself under the kind of none" {
  let inflated : Bytes = inflate(None, b"\x00\x7f\x80\xff", 16) catch {
    _ => fail("a block stored as it is does not inflate")
  }
  assert_eq(inflated, b"\x00\x7f\x80\xff")
}

///|
test "every compression kind names itself as the format spells it" {
  assert_eq(None.name(), "NONE")
  assert_eq(Zlib.name(), "ZLIB")
  assert_eq(Snappy.name(), "SNAPPY")
  assert_eq(Lz4.name(), "LZ4")
  assert_eq(Zstd.name(), "ZSTD")
}

///|
test "the cursor gives the bytes it holds and refuses the ones it does not" {
  let c = cursor(b"\x01\x02\x03", 10, "the run")
  let taken : Bytes = c.take(2) catch {
    _ => fail("two bytes of three are the cursor's to give")
  }
  assert_eq(taken, b"\x01\x02")
  assert_eq(c.offset(), 12)
  let past : Result[Bytes, @types.DataError] = Ok(c.take(2)) catch {
    e => Err(e)
  }
  match past {
    Ok(_) => fail("the cursor gave a byte it does not hold")
    Err(error) =>
      assert_eq(
        error.message(),
        "Parse error: orc: byte 12: the run: the bytes end inside a value",
      )
  }
  let negative : Result[Bytes, @types.DataError] = Ok(c.take(-1)) catch {
    e => Err(e)
  }
  match negative {
    Ok(_) => fail("the cursor gave a negative count of bytes")
    Err(error) =>
      assert_eq(
        error.message(),
        "Parse error: orc: byte 12: the run: the bytes end inside a value",
      )
  }
  let last : Bytes = c.take(1) catch {
    _ => fail("the last byte is the cursor's to give")
  }
  assert_eq(last, b"\x03")
}

///|
test "a varint of ten bytes carries its last bit, and past it refuses" {
  let wide = cursor(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01", 0, "the run")
  let value : UInt64 = wide.varint() catch {
    _ => fail("a ten-byte varint of one bit")
  }
  assert_eq(value, 0x8000_0000_0000_0000UL)
  let past = cursor(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02", 0, "the run")
  let outcome : Result[UInt64, @types.DataError] = Ok(past.varint()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("a varint of 65 bits read back")
    Err(error) =>
      assert_eq(
        error.message(),
        "Parse error: orc: byte 10: the run: the bytes hold a varint wider than 64 bits",
      )
  }
}

///|
test "every type kind names itself as the format spells it, and past them by number" {
  let names = kind_names()
  assert_eq(names.length(), 19)
  for kind, name in names {
    assert_eq(kind_name(kind.to_int()), name)
  }
  assert_eq(kind_name(19), "type kind 19")
  assert_eq(kind_name(-1), "type kind -1")
}

///|
test "a count spells its noun, and a word takes its article" {
  assert_eq(counted(1L, "subtype"), "1 subtype")
  assert_eq(counted(2L, "subtype"), "2 subtypes")
  assert_eq(counted(0L, "field name"), "0 field names")
  assert_eq(
    counted(1L, "dictionary entry", many="dictionary entries"),
    "1 dictionary entry",
  )
  assert_eq(
    counted(2L, "dictionary entry", many="dictionary entries"),
    "2 dictionary entries",
  )
  assert_eq(a("INT"), "an")
  assert_eq(a("offset"), "an")
  assert_eq(a("STRING"), "a")
  assert_eq(a("list"), "a")
}
