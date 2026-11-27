// Blackbox refusals of the extension records the reader reads — the long
// variable names record, the very long string record and the long string
// missing values record — asserted by variant and by text on files built
// by hand, with the edge each record's valid spellings must accept.

///|
/// A file whose dictionary holds the numeric variable N: the next
/// record lies at byte 208 and its data at 224; the caller adds records
/// there, then the terminator and the data.
fn numeric_open() -> File {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  f
}

///|
/// A file holding the very long string S — the variable S of 255 bytes
/// with its 31 continuation records — followed by the variables `after`
/// spells, each a string of `width` bytes or, at width 0, the numeric N;
/// the next record lies at byte 1392 and its data at 1408.
fn very_long(after : ReadOnlyArray[Int32]) -> File {
  let f = header(false, 0, 1)
  variable(f, 255, b"S", fmt(1, 255, 0))
  for _ in 0..<31 {
    continuation(f)
  }
  for width in after {
    if width == 0 {
      variable(f, 0, b"N", fmt(5, 8, 2))
    } else {
      variable(f, width, b"T", fmt(1, width, 0))
      let more = (width + 7) / 8 - 1
      for _ in 0..<more {
        continuation(f)
      }
    }
  }
  f
}

///|
/// The very long string record naming S as `width` bytes wide, its
/// width five digits zero-padded, as a reference writer spells it.
fn lengths(width : Int32) -> Bytes {
  let f = File::new()
  ignore(
    f
    .raw(b"S=")
    .byte(48 + width / 10000)
    .byte(48 + width / 1000 % 10)
    .byte(48 + width / 100 % 10)
    .byte(48 + width / 10 % 10)
    .byte(48 + width % 10)
    .raw(b"\x00\x09"),
  )
  f.finish()
}

///|
/// A long string missing values record: the variable `name`, `count`
/// values of `value_len` bytes each, and `values` the bytes that follow.
fn long_missing(
  f : File,
  name : Bytes,
  count : Int32,
  value_len : Int32,
  values : Bytes,
) -> Unit {
  let data = File::new()
  ignore(
    data.int(name.length()).raw(name).byte(count).int(value_len).raw(values),
  )
  extension(f, 22, 1, data.bytes.length(), data.finish())
}

///|
test "a long variable names entry that spells no pair is refused" {
  let f = numeric_open()
  extension(f, 13, 1, 8, b"NOEQUALS")
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    parse(
      "byte 224: the long variable name record's entry NOEQUALS spells no variable and long name",
    ),
  )
}

///|
test "a long variable names entry that gives no long name is refused" {
  let f = numeric_open()
  extension(f, 13, 1, 2, b"N=")
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    parse(
      "byte 224: the long variable name record gives the variable N no long name",
    ),
  )
}

///|
test "a very long string entry that spells no variable and width is refused" {
  let f = very_long([48])
  extension(f, 14, 1, 1, b"S")
  terminator(f)
  ignore(f.blanks(304))
  refuses(
    f.finish(),
    parse(
      "byte 1408: the very long string record's entry S spells no variable and width",
    ),
  )
  let g = very_long([48])
  extension(g, 14, 1, 5, b"S=abc")
  terminator(g)
  ignore(g.blanks(304))
  refuses(
    g.finish(),
    parse(
      "byte 1408: the very long string record's entry S=abc spells no variable and width",
    ),
  )
}

///|
test "a very long string entry naming a variable the dictionary does not hold is refused" {
  let f = very_long([48])
  extension(f, 14, 1, 9, b"Q=00300\x00\x09")
  terminator(f)
  ignore(f.blanks(304))
  refuses(
    f.finish(),
    parse(
      "byte 1408: the very long string record names the variable Q, which the dictionary does not hold",
    ),
  )
}

///|
test "a very long string entry naming a numeric variable is refused" {
  let f = numeric_open()
  extension(f, 14, 1, 9, b"N=00300\x00\x09")
  terminator(f)
  ignore(f.double(1.0))
  refuses(
    f.finish(),
    parse("byte 224: the very long string record names the numeric variable N"),
  )
}

///|
test "a very long string entry naming a variable a second time is refused" {
  let f = very_long([48])
  extension(f, 14, 1, 18, lengths(300) + lengths(300))
  terminator(f)
  ignore(f.blanks(304))
  refuses(
    f.finish(),
    parse(
      "byte 1417: the very long string record names the variable S a second time",
    ),
  )
}

///|
test "a very long string entry whose width one variable holds is refused" {
  let f = very_long([48])
  extension(f, 14, 1, 9, lengths(200))
  terminator(f)
  ignore(f.blanks(304))
  refuses(
    f.finish(),
    parse(
      "byte 1408: the very long string record gives the variable S a width of 200, which one variable holds",
    ),
  )
}

///|
test "a very long string with more segments than the dictionary holds is refused" {
  let f = very_long([48])
  extension(f, 14, 1, 9, lengths(2000))
  terminator(f)
  ignore(f.blanks(304))
  refuses(
    f.finish(),
    parse(
      "byte 1408: the very long string S of width 2000 needs 8 segments and the dictionary holds 2 variables from it on",
    ),
  )
}

///|
test "a very long string with a numeric segment is refused" {
  let f = very_long([255, 0])
  extension(f, 14, 1, 9, lengths(508))
  terminator(f)
  ignore(f.blanks(520))
  refuses(
    f.finish(),
    parse(
      "byte 2272: segment 3 of the very long string S is the numeric variable N",
    ),
  )
}

///|
test "a very long string with a segment of the wrong width is refused" {
  let f = very_long([64])
  extension(f, 14, 1, 9, lengths(300))
  terminator(f)
  ignore(f.blanks(320))
  refuses(
    f.finish(),
    parse(
      "byte 1472: segment 2 of the very long string S is 64 bytes wide, where its width 300 calls for 48",
    ),
  )
}

///|
test "a long string missing values record that ends inside a name length is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  extension(f, 22, 1, 2, b"\x01\x00")
  terminator(f)
  ignore(f.blanks(24))
  refuses(
    f.finish(),
    parse(
      "byte 256: the long string missing values record ends inside a name length",
    ),
  )
}

///|
test "a long string missing values record that ends inside a name is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  ignore(f.int(7).int(22).int(1).int(5).int(20).raw(b"S"))
  terminator(f)
  ignore(f.blanks(24))
  refuses(
    f.finish(),
    parse(
      "byte 256: the long string missing values record names a variable in 20 bytes and ends before them",
    ),
  )
}

///|
test "a long string missing values record that ends before its values is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  ignore(f.int(7).int(22).int(1).int(5).int(1).raw(b"S"))
  terminator(f)
  ignore(f.blanks(24))
  refuses(
    f.finish(),
    parse(
      "byte 256: the long string missing values record ends before the variable's missing values",
    ),
  )
}

///|
test "a long string missing values record with a count that is not 1, 2 or 3 is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  long_missing(f, b"S", 4, 8, b"zzzzzzzz")
  terminator(f)
  ignore(f.blanks(24))
  refuses(
    f.finish(),
    parse(
      "byte 261: the long string missing values record declares 4 missing values, not 1, 2 or 3",
    ),
  )
}

///|
test "a long string missing values record that ends inside its values is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  long_missing(f, b"S", 1, 8, b"zzz")
  terminator(f)
  ignore(f.blanks(24))
  refuses(
    f.finish(),
    parse(
      "byte 256: the long string missing values record declares 1 values of 8 bytes and ends before them",
    ),
  )
}

///|
test "a long string missing values record naming a variable the dictionary does not hold is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  long_missing(f, b"Q", 1, 8, b"zzzzzzzz")
  terminator(f)
  ignore(f.blanks(24))
  refuses(
    f.finish(),
    parse(
      "byte 256: the long string missing values record names the variable Q, which the dictionary does not hold",
    ),
  )
}

///|
test "a long string missing values record naming a numeric variable is refused" {
  let f = header(false, 0, 1)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  variable(f, 0, b"N", fmt(5, 8, 2))
  long_missing(f, b"N", 1, 8, b"zzzzzzzz")
  terminator(f)
  ignore(f.blanks(32))
  refuses(
    f.finish(),
    parse(
      "byte 288: the long string missing values record names the numeric variable N",
    ),
  )
}

///|
test "the long variable names record renames what it names and passes the rest over" {
  let f = numeric_open()
  extension(f, 13, 1, 19, b"N=number\tX=nowhere\t")
  terminator(f)
  ignore(f.double(1.0))
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 1)
  assert_eq(spelled_columns(columns), ["number(Float): Float 3ff0000000000000"])
}

///|
test "a very long string joins its segments, 255 bytes to a segment" {
  let f = very_long([48])
  extension(f, 14, 1, 9, lengths(300))
  terminator(f)
  // 255 bytes of S, one of padding, then 48 of T: 45 carry text.
  ignore(f.blanks(256))
  ignore(f.blanks(48))
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 1)
  assert_eq(spelled_columns(columns), ["S(String): String "])
  let g = very_long([48])
  extension(g, 14, 1, 9, lengths(300))
  terminator(g)
  ignore(g.raw(b"a"))
  ignore(g.blanks(303))
  let (text, _) = read_spss_frame(g.finish())
  assert_eq(spelled_columns(text), ["S(String): String a"])
}

///|
test "a long string's declared missing values null the cells that spell them" {
  let f = header(false, 0, 3)
  variable(f, 12, b"S", fmt(1, 12, 0))
  continuation(f)
  long_missing(f, b"S", 2, 12, b"zz          ddd         ")
  terminator(f)
  ignore(f.text(b"zz", 16))
  ignore(f.text(b"ddd", 16))
  ignore(f.text(b"e", 16))
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 3)
  assert_eq(spelled_columns(columns), ["S(String): Null, Null, String e"])
}
