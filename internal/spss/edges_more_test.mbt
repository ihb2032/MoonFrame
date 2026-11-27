// Blackbox edge tests of the encoding a file declares, of a stream that
// stops between its groups of codes, of a missing range open above, and
// of a very long string entry with no width.

///|
/// A file of one string S of eight bytes and `code` as its character code,
/// with no encoding record; the cells are `cells`.
fn code_page_file(code : Int32, cells : Bytes) -> Bytes {
  let f = header(false, 0, 1)
  variable(f, 8, b"S", fmt(1, 8, 0))
  ignore(f.raw(integer_info(1, code).finish()))
  terminator(f)
  ignore(f.raw(cells))
  f.finish()
}

///|
test "a character code alone names the encoding: 65001, 28591, 2 and 1252" {
  let (utf8, _) = read_spss_frame(code_page_file(65001, b"\xc3\xa9      "))
  assert_eq(spelled_columns(utf8), ["S(String): String é"])
  let (latin, _) = read_spss_frame(code_page_file(28591, b"\xe9       "))
  assert_eq(spelled_columns(latin), ["S(String): String é"])
  for code in [2, 3, 1252] {
    let (windows, _) = read_spss_frame(
      code_page_file(code, b"\x80\x93\x94     "),
    )
    assert_eq(spelled_columns(windows), ["S(String): String €“”"])
  }
  // A file that declares nothing at all decodes as UTF-8.
  let f = header(false, 0, 1)
  variable(f, 8, b"S", fmt(1, 8, 0))
  terminator(f)
  ignore(f.raw(b"\xc3\xa9      "))
  let (undeclared, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(undeclared), ["S(String): String é"])
}

///|
test "an encoding name matches without regard to case or to the separators it is spelled with" {
  for
    (name, cells, text) in [
      (b"utf-8", b"\xc3\xa9      ", "é"),
      (b"UTF8", b"\xc3\xa9      ", "é"),
      (b"latin1", b"\xe9       ", "é"),
      (b"iso_8859-1", b"\xe9       ", "é"),
      (b"L1", b"\xe9       ", "é"),
      (b"cp1252", b"\x80       ", "€"),
      (b"Windows-1252", b"\x99       ", "™"),
      (b"MS_ANSI", b"\x93\x94      ", "“”"),
    ] {
    let f = header(false, 0, 1)
    variable(f, 8, b"S", fmt(1, 8, 0))
    extension(f, 20, 1, name.length(), name)
    terminator(f)
    ignore(f.raw(cells))
    let (columns, _) = read_spss_frame(f.finish())
    assert_eq(spelled_columns(columns), ["S(String): String \{text}"])
  }
}

///|
test "a very long string entry with no width, or one too long to read, is refused" {
  for data in [b"S=", b"S=000000000000000000001"] {
    let f = very_long([48])
    extension(f, 14, 1, data.length(), data)
    terminator(f)
    ignore(f.blanks(304))
    let shown = if data.length() == 2 {
      "S="
    } else {
      "S=000000000000000000001"
    }
    refuses(
      f.finish(),
      parse(
        "byte 1408: the very long string record's entry \{shown} spells no variable and width",
      ),
    )
  }
}

///|
test "a missing range open below — spelled LOWEST, or the system-missing value since one release — takes negative infinity in" {
  let lowest = 0xFFEFFFFFFFFFFFFEUL.reinterpret_as_double()
  let f = header(false, 0, 4)
  record(f, 0, 0, -2, fmt(5, 8, 2), b"N", doubles([-1.0e300, 5.0]))
  record(f, 0, 0, -2, fmt(5, 8, 2), b"M", doubles([lowest, 5.0]))
  record(
    f,
    0,
    0,
    -2,
    fmt(5, 8, 2),
    b"K",
    doubles([-1.7976931348623157e308, 5.0]),
  )
  terminator(f)
  for value in [-1.0 / 0.0, -1.0, 5.0, 6.0] {
    ignore(f.double(value))
    ignore(f.double(value))
    ignore(f.double(value))
  }
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), [
    "N(Float): Float fff0000000000000, Null, Null, Float 4018000000000000", "M(Float): Null, Null, Null, Float 4018000000000000",
    "K(Float): Null, Null, Null, Float 4018000000000000",
  ])
}

///|
test "a missing range open above, spelled HIGHEST, nulls every cell from its bottom up" {
  let top = 1.7976931348623157e308
  let f = header(false, 0, 4)
  record(f, 0, 0, -2, fmt(5, 8, 2), b"N", doubles([4.0, top]))
  terminator(f)
  for value in [3.0, 4.0, 1.0e300, top] {
    ignore(f.double(value))
  }
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), [
    "N(Float): Float 4008000000000000, Null, Null, Null",
  ])
}

///|
test "a stream that stops between its groups of codes ends there" {
  // Eight cases of one unit each from the first group, then three bytes
  // that are no group: eight cases, and no ninth.
  let f = header(false, 1, -1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.raw(b"\x65\x66\x67\x68\x69\x6a\x6b\x6c\x65\x66\x67"))
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 8)
  assert_eq(spelled_columns(columns), [
    "N(Float): Float 3ff0000000000000, Float 4000000000000000, Float 4008000000000000, Float 4010000000000000, Float 4014000000000000, Float 4018000000000000, Float 401c000000000000, Float 4020000000000000",
  ])
}

///|
test "a very long string record that opens and ends with its delimiters is read" {
  let f = very_long([48])
  extension(f, 14, 1, 12, b"\x00\x09" + lengths(300) + b"\x00")
  terminator(f)
  ignore(f.blanks(304))
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 1)
  assert_eq(spelled_columns(columns), ["S(String): String "])
}

///|
test "a variable record of type 0 is numeric whatever format it carries" {
  // The string format A on a numeric variable: the type decides, as the
  // format's own reference reader decides.
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(1, 8, 0))
  terminator(f)
  ignore(f.double(1.0))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), ["N(Float): Float 3ff0000000000000"])
}
