// Blackbox refusals: every message the reader raises, asserted by
// variant and by text, on files built by hand or patched from one — the
// signature and header, the dictionary's records, the data record under
// each compression, and text in its encoding; the extension records the
// reader reads have a test of the same shape to themselves.

///|
test "a system file inside an encrypted wrapper is refused by name" {
  let f = File::new()
  ignore(f.raw(b"\x1c\x00\x00\x00\x00\x00\x00\x00ENCRYPTEDSAV\x15\x00\x00\x00"))
  ignore(f.blanks(176))
  refuses(
    f.finish(),
    unsupported(
      "byte 0: the file is a system file inside an encrypted wrapper, which this reader does not decrypt",
    ),
  )
}

///|
test "a system file signature in EBCDIC is refused by name" {
  refuses(
    patched_bytes(one_case(), 0, b"\x5b\xc6\xd3\xf2"),
    unsupported(
      "byte 0: the file signature is a system file's in EBCDIC, whose text this reader does not decode",
    ),
  )
}

///|
test "a file whose signature is not a system file's is refused by name" {
  refuses(
    patched_bytes(one_case(), 0, b"NOPE"),
    unsupported("byte 0: the file signature is not a system file's"),
  )
  refuses(
    b"NO",
    unsupported("byte 0: the file signature is not a system file's"),
  )
}

///|
test "a layout code that is 2 or 3 in neither byte order is refused by name" {
  refuses(
    patched(one_case(), 64, 7),
    unsupported(
      "byte 64: the layout code is 2 or 3 in neither byte order, so the file is not a system file",
    ),
  )
}

///|
test "a compression code the reader does not decode is refused by name" {
  refuses(
    patched(one_case(), 72, 5),
    unsupported(
      "byte 72: the header declares compression 5, which this reader does not decode",
    ),
  )
  refuses(
    patched(one_case(), 72, -1),
    unsupported(
      "byte 72: the header declares compression -1, which this reader does not decode",
    ),
  )
}

///|
test "a compression bias that is not 100, or a floating-point format that is not IEEE 754, is refused by name" {
  let two_hundred = 200.0.reinterpret_as_uint64().reinterpret_as_int64()
  refuses(
    patched_wide(one_case(), 84, two_hundred),
    unsupported(
      "byte 84: the compression bias is not 100 or the floating-point format is not IEEE 754, and this reader decodes neither",
    ),
  )
  let zero_bias = patched_wide(one_case(), 84, 0L)
  refuses(
    zero_bias,
    unsupported(
      "byte 84: the compression bias is not 100 or the floating-point format is not IEEE 754, and this reader decodes neither",
    ),
  )
}

///|
test "a floating-point representation that is not IEEE 754 is refused by name" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  ignore(f.raw(integer_info(2, 65001).finish()))
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    unsupported(
      "byte 208: the file declares floating-point representation 2, which is not IEEE 754 and this reader does not decode",
    ),
  )
}

///|
test "a character encoding the reader does not decode is refused by name" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  extension(f, 20, 1, 6, b"KOI8-R")
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    unsupported(
      "the file declares the character encoding KOI8-R, which this reader does not decode",
    ),
  )
  let g = header(false, 0, 1)
  variable(g, 0, b"N", fmt(5, 8, 2))
  extension(g, 20, 1, 8, b"UTF-16LE")
  terminator(g)
  ignore(g.double(1.0))
  refuses(
    g.finish(),
    unsupported(
      "the file declares the character encoding UTF-16LE, which this reader does not decode",
    ),
  )
}

///|
test "the EBCDIC character code is refused by name" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  ignore(f.raw(integer_info(1, 1).finish()))
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    unsupported(
      "the file declares character code 1, EBCDIC, which this reader does not decode",
    ),
  )
}

///|
test "a character code the reader does not decode is refused by name" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  ignore(f.raw(integer_info(1, 1251).finish()))
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    unsupported(
      "the file declares character code 1251, which this reader does not decode",
    ),
  )
}

///|
test "a file cut short inside a record is refused at the byte it ends" {
  refuses(
    cut(one_case(), 194),
    parse("the file ends at byte 194 before the 4 bytes needed at byte 192"),
  )
  refuses(
    cut(one_case(), 100),
    parse("the file ends at byte 100 before the 84 bytes needed at byte 92"),
  )
  refuses(
    cut(one_case(), 210),
    parse("the file ends at byte 210 before the 4 bytes needed at byte 208"),
  )
}

///|
test "a compression code under the wrong signature is refused" {
  refuses(
    patched(one_case(), 72, 2),
    parse(
      "byte 72: the header declares compression 2 under the $FL2 signature, and only $FL3 carries compression 2",
    ),
  )
  refuses(
    patched_bytes(one_case(), 0, b"$FL3"),
    parse(
      "byte 72: the header declares compression 0 under the $FL3 signature, and only $FL3 carries compression 2",
    ),
  )
}

///|
test "a case count below -1 is refused" {
  refuses(
    patched(one_case(), 80, -2),
    parse("byte 80: the header declares -2 cases"),
  )
}

///|
test "a continuation record no string variable awaits is refused by name" {
  let f = header(false, 0, 1)
  continuation(f)
  terminator(f)
  refuses(
    f.finish(),
    unsupported(
      "byte 180: the variable type -1 is neither numeric (0) nor string (greater than 0)",
    ),
  )
  let g = header(false, 0, 1)
  variable(g, 16, b"S", fmt(1, 16, 0))
  record(g, -2, 0, 0, fmt(1, 16, 0), b"", b"")
  refuses(
    g.finish(),
    unsupported(
      "byte 212: the variable type -2 is neither numeric (0) nor string (greater than 0)",
    ),
  )
}

///|
test "string continuation records that are missing are refused" {
  let f = header(false, 0, 1)
  variable(f, 16, b"S", fmt(1, 16, 0))
  terminator(f)
  ignore(f.blanks(32))
  refuses(
    f.finish(),
    parse(
      "byte 208: 1 continuation record of the string variable at byte 176 is missing",
    ),
  )
  let g = header(false, 0, 1)
  variable(g, 24, b"S", fmt(1, 24, 0))
  variable(g, 0, b"N", fmt(5, 8, 2))
  variable(g, 0, b"M", fmt(5, 8, 2))
  terminator(g)
  refuses(
    g.finish(),
    parse(
      "byte 208: 2 continuation records of the string variable at byte 176 are missing",
    ),
  )
}

///|
test "a variable label indicator that is not 0 or 1 is refused" {
  let f = header(false, 0, 1)
  record(f, 0, 2, 0, fmt(5, 8, 2), b"N", b"")
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    parse("byte 184: the variable label indicator is 2, not 0 or 1"),
  )
}

///|
test "a string width whose continuation records the file cannot hold is refused" {
  let f = header(false, 0, 1)
  variable(f, 1000, b"S", fmt(1, 255, 0))
  terminator(f)
  ignore(f.blanks(16))
  refuses(
    f.finish(),
    parse(
      "byte 176: the string variable is 1000 bytes wide and needs 124 continuation records of 32 bytes, and only 24 bytes remain",
    ),
  )
}

///|
test "a string variable's missing value count that is not 1, 2 or 3 is refused" {
  let f = header(false, 0, 1)
  record(f, 3, 0, -1, fmt(1, 3, 0), b"S", b"")
  terminator(f)
  refuses(
    f.finish(),
    parse(
      "byte 188: the missing value indicator -1 of a string variable is not 1, 2 or 3",
    ),
  )
  let g = header(false, 0, 1)
  record(g, 3, 0, 4, fmt(1, 3, 0), b"S", b"")
  terminator(g)
  refuses(
    g.finish(),
    parse(
      "byte 188: the missing value indicator 4 of a string variable is not 1, 2 or 3",
    ),
  )
}

///|
test "a numeric variable's missing value count that is not -3, -2, 1, 2 or 3 is refused" {
  let f = header(false, 0, 1)
  record(f, 0, 0, -1, fmt(5, 8, 2), b"N", b"")
  terminator(f)
  refuses(
    f.finish(),
    parse(
      "byte 188: the missing value indicator -1 of a numeric variable is not -3, -2, 1, 2 or 3",
    ),
  )
  let g = header(false, 0, 1)
  record(g, 0, 0, -4, fmt(5, 8, 2), b"N", b"")
  terminator(g)
  refuses(
    g.finish(),
    parse(
      "byte 188: the missing value indicator -4 of a numeric variable is not -3, -2, 1, 2 or 3",
    ),
  )
}

///|
test "a value-label record not followed by a variables record is refused" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  ignore(f.int(3).int(0))
  ignore(f.int(6).int(0))
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    parse("byte 216: a type 4 record must follow the type 3 record at byte 208"),
  )
}

///|
test "an extension record longer than the file is refused" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  ignore(f.int(7).int(5).int(4).int(1000000))
  refuses(
    f.finish(),
    parse(
      "byte 208: the extension record of subtype 5 declares 1000000 elements of 4 bytes, and only 0 bytes remain",
    ),
  )
}

///|
test "a record of a type the format does not define is refused" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  ignore(f.int(8))
  refuses(
    f.finish(),
    parse("byte 208: record type 8 names no record of the format"),
  )
  let g = header(false, 0, 1)
  variable(g, 0, b"N", fmt(5, 8, 2))
  ignore(g.int(4).int(0))
  terminator(g)
  refuses(
    g.finish(),
    parse("byte 208: record type 4 names no record of the format"),
  )
}

///|
test "a dictionary with no variable, so a case of no size, is refused" {
  let f = header(false, 0, 0)
  terminator(f)
  refuses(
    f.finish(),
    parse("byte 184: the dictionary holds no variable, so a case has no size"),
  )
}

///|
test "a case count the uncompressed data cannot hold is refused" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  refuses(
    f.finish(),
    parse(
      "byte 216: the header declares 1 cases of 8 bytes, and the file holds 0",
    ),
  )
  let g = header(false, 0, 3)
  variable(g, 0, b"N", fmt(5, 8, 2))
  terminator(g)
  ignore(g.double(1.0))
  ignore(g.double(2.0))
  refuses(
    g.finish(),
    parse(
      "byte 216: the header declares 3 cases of 8 bytes, and the file holds 2",
    ),
  )
}

///|
test "uncompressed data that ends inside a case is refused" {
  let f = header(false, 0, -1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.double(1.0))
  ignore(f.double(2.0))
  ignore(f.blanks(4))
  refuses(
    f.finish(),
    parse("byte 232: the data ends inside case 3, which holds 8 bytes"),
  )
}

///|
test "a case count the compressed data cannot hold is refused before a case is read" {
  let f = header(false, 1, 20)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.blanks(8))
  refuses(
    f.finish(),
    parse(
      "byte 216: the header declares 20 cases of 1 units, and the compressed data holds at most 8",
    ),
  )
  let z = zsav(20, b"\x00\x00\x00\x00\x00\x00\x00\x00")
  refuses(
    z.bytes,
    parse(
      "the zlib data: the header declares 20 cases of 1 units, and the compressed data holds at most 8",
    ),
  )
}

///|
test "a compressed value a code 253 names and the data cuts off is refused" {
  let f = header(false, 1, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.raw(b"\xfd\x00\x00\x00\x00\x00\x00\x00"))
  refuses(
    f.finish(),
    parse(
      "byte 224: the compressed data ends inside the value a code 253 names",
    ),
  )
  let z = zsav(1, b"\xfd\x00\x00\x00\x00\x00\x00\x00")
  refuses(
    z.bytes,
    parse(
      "the zlib data: the compressed data ends inside the value a code 253 names",
    ),
  )
}

///|
test "compressed data that ends inside a case is refused" {
  let f = header(false, 1, -1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  variable(f, 0, b"M", fmt(5, 8, 2))
  terminator(f)
  ignore(f.raw(one_unit_codes()))
  refuses(
    f.finish(),
    parse(
      "byte 256: the compressed data ends inside case 1, after 1 of its 2 units",
    ),
  )
  let g = header(true, 2, -1)
  variable(g, 0, b"N", fmt(5, 8, 2))
  variable(g, 0, b"M", fmt(5, 8, 2))
  terminator(g)
  ignore(zlib_data(g, one_unit_codes()))
  refuses(
    g.finish(),
    parse(
      "the zlib data: the compressed data ends inside case 1, after 1 of its 2 units",
    ),
  )
}

///|
test "a case count the decoded cases fall short of is refused" {
  let f = header(false, 1, 2)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.raw(one_unit_codes()))
  refuses(
    f.finish(),
    parse(
      "byte 224: the header declares 2 cases and the compressed data holds 1",
    ),
  )
  let z = zsav(2, one_unit_codes())
  refuses(
    z.bytes,
    parse(
      "the zlib data: the header declares 2 cases and the compressed data holds 1",
    ),
  )
}
