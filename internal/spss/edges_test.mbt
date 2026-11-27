// Blackbox edge tests, on files built by hand and on reference files:
// no row, nothing but missing cells, names and strings at the format's
// limits, the case count's three spellings, the numbers a cell can hold,
// the date families, declared missing values, the encodings, and the
// records a dictionary can carry around its variables.

///|
/// A reference file read through the codec.
fn read_fixture(
  file : String,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  read_spss_frame(fixture(".github/fixtures/spss/reference/\{file}"))
}

///|
/// The cells of column `name` of a table, spelled.
fn column(
  columns : Array[(String, @series.Series)],
  name : String,
) -> Array[String] raise @types.DataError {
  for (column_name, series) in columns {
    if column_name == name {
      return series.to_scalars().map(spelled)
    }
  }
  raise problem("no column named \{name}")
}

///|
/// The bytes of `values`, for a variable record's missing values.
fn doubles(values : ReadOnlyArray[Double]) -> Bytes {
  let f = File::new()
  for value in values {
    ignore(f.double(value))
  }
  f.finish()
}

///|
/// `text` repeated `count` times.
fn repeat(text : String, count : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_string(text)
  }
  out.to_string()
}

///|
test "columns and no row keep their columns and dtypes, compressed or not" {
  for file in ["pyrs_norows.sav", "pyrs_norows.zsav"] {
    let (columns, rows) = read_fixture(file)
    assert_eq(rows, 0)
    assert_eq(
      columns.map(pair => "\{pair.0} \{pair.1.dtype()} \{pair.1.len()}"),
      ["a Float 0", "s String 0"],
    )
  }
  let f = header(false, 0, 0)
  variable(f, 0, b"N", fmt(5, 8, 2))
  variable(f, 3, b"S", fmt(1, 3, 0))
  terminator(f)
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 0)
  assert_eq(columns.length(), 2)
}

///|
test "a column of nothing but missing values, and one of blank strings" {
  let (columns, _) = read_fixture("pyrs_allmissing.sav")
  assert_eq(spelled_columns(columns), [
    "allnan(Float): Null, Null, Null", "blank(String): String , String , String ",
  ])
  // The system-missing value spelled by a code 255 under bytecode.
  let f = header(false, 1, 3)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.raw(b"\xff\xff\xff\xfc\x00\x00\x00\x00"))
  let (coded, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 3)
  assert_eq(spelled_columns(coded), ["N(Float): Null, Null, Null"])
}

///|
test "a dictionary of no variable is refused: a case would have no size" {
  let f = header(false, 0, 0)
  terminator(f)
  assert_eq(
    read_error(f.finish()),
    parse("byte 184: the dictionary holds no variable, so a case has no size"),
  )
  assert_eq(
    read_error(fixture(".github/fixtures/spss/reference/pyrs_nocols.sav"))
    .message()
    .has_suffix("the dictionary holds no variable, so a case has no size"),
    true,
  )
}

///|
test "a name fills its eight-byte field, and a long name its sixty-four" {
  let f = header(false, 0, 1)
  variable(f, 0, b"ABCDEFGH", fmt(5, 8, 2))
  variable(f, 0, b"b", fmt(5, 8, 2))
  extension(
    f,
    13,
    1,
    66,
    b"b=" + b"0123456789012345678901234567890123456789012345678901234567890123",
  )
  terminator(f)
  ignore(f.double(1.0))
  ignore(f.double(2.0))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(columns.map(pair => pair.0), [
    "ABCDEFGH", "0123456789012345678901234567890123456789012345678901234567890123",
  ])
  // A name repeated is returned as spelled, twice.
  let g = header(false, 0, 1)
  variable(g, 0, b"N", fmt(5, 8, 2))
  variable(g, 0, b"n", fmt(5, 8, 2))
  terminator(g)
  ignore(g.double(1.0))
  ignore(g.double(2.0))
  let (twice, _) = read_spss_frame(g.finish())
  assert_eq(twice.map(pair => pair.0), ["N", "n"])
}

///|
test "names longer than the field and names outside ASCII come from the long names record" {
  let (columns, _) = read_fixture("pyrs_plain.sav")
  assert_eq(columns.map(pair => pair.0), [
    "num", "s8", "s12", "s1", "s255", "s300", "a_very_long_column_name_here", "ünïcödé_nâmé",
  ])
  assert_eq(column(columns, "ünïcödé_nâmé"), [
    "String é", "String 日本", "String ", "String ", "String ü",
  ])
  // Without the record, the names are the fields as spelled: the first
  // eight bytes, upper-cased by the writer.
  let (short, _) = read_fixture("synthetic_no_long_names.sav")
  assert_eq(short.map(pair => pair.0), ["LOWER_CA", "ANOTHER_"])
}

///|
test "strings at the format's limits: one byte, eight, 255, and a very long string of 2000" {
  let (columns, _) = read_fixture("pyrs_plain.sav")
  assert_eq(column(columns, "s1"), [
    "String x", "String ", "String y", "String ", "String z",
  ])
  assert_eq(column(columns, "s8"), [
    "String 12345678", "String a", "String ", "String ", "String   pad",
  ])
  let long = column(columns, "s255")[0]
  assert_eq(long, "String " + repeat("x", 255))
  let very = column(columns, "s300")[0]
  assert_eq(very, "String " + repeat("a", 300))
  // Very long strings around the segment counts: two, two, three and
  // eight segments, the third of the 505-byte one all padding.
  let (vls, rows) = read_fixture("pyrs_vls.sav")
  assert_eq(rows, 2)
  assert_eq(column(vls, "s253"), ["String " + repeat("a", 253), "String ab"])
  assert_eq(column(vls, "s256"), ["String " + repeat("b", 256), "String "])
  assert_eq(column(vls, "s505"), [
    "String " + repeat("c", 505),
    "String " + repeat("c", 300),
  ])
  assert_eq(column(vls, "s2000"), ["String " + repeat("d", 2000), "String "])
}

///|
test "a string cell keeps its leading blanks, drops NUL bytes inside it, and loses a character cut at its end" {
  let (columns, _) = read_fixture("synthetic_text_quirks.sav")
  assert_eq(column(columns, "t8"), [
    "String abcd", "String ab", "String ef", "String ",
  ])
}

///|
test "a declared case count of none reads to the end of the data, and a smaller one reads that many" {
  let (_, unknown) = read_fixture("pyrs_ncases_unknown.sav")
  assert_eq(unknown, 4)
  let (short, rows) = read_fixture("pyrs_ncases_short.sav")
  assert_eq(rows, 3)
  assert_eq(column(short, "a"), [
    "Float 3ff0000000000000", "Float 4004000000000000", "Float c008000000000000",
  ])
  // Under bytecode, the end code 252 closes a stream of no declared count.
  let f = header(false, 1, -1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.raw(b"\x65\x66\x67\xfc\x00\x00\x00\x00"))
  let (coded, count) = read_spss_frame(f.finish())
  assert_eq(count, 3)
  assert_eq(spelled_columns(coded), [
    "N(Float): Float 3ff0000000000000, Float 4000000000000000, Float 4008000000000000",
  ])
  // Data beyond a declared count is passed over.
  let g = header(false, 0, 2)
  variable(g, 0, b"N", fmt(5, 8, 2))
  terminator(g)
  ignore(g.double(1.0))
  ignore(g.double(2.0))
  ignore(g.double(3.0))
  ignore(g.double(4.0))
  let (two, count_two) = read_spss_frame(g.finish())
  assert_eq(count_two, 2)
  assert_eq(column(two, "N"), [
    "Float 3ff0000000000000", "Float 4000000000000000",
  ])
}

///|
test "a NaN cell, HIGHEST and LOWEST stay the numbers they are, bit for bit" {
  let top = 1.7976931348623157e308
  let lowest = 0xFFEFFFFFFFFFFFFEUL.reinterpret_as_double()
  let nan = 0x7FF8000000000000UL.reinterpret_as_double()
  let f = header(false, 0, 4)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  ignore(f.double(nan))
  ignore(f.double(top))
  ignore(f.double(lowest))
  ignore(f.double(-0.0))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(column(columns, "N"), [
    "Float 7ff8000000000000", "Float 7fefffffffffffff", "Float ffeffffffffffffe",
    "Float 8000000000000000",
  ])
}

///|
test "the numbers at both edges of the codes a bytecode stream can compress" {
  let (columns, _) = read_fixture("pyrs_extremes_rows.sav")
  let cells = column(columns, "v")
  assert_eq(cells[0], "Float \{hex64((-99.0).reinterpret_as_uint64())}")
  assert_eq(cells[1], "Float \{hex64(151.0.reinterpret_as_uint64())}")
  assert_eq(cells[2], "Float \{hex64((-100.0).reinterpret_as_uint64())}")
  assert_eq(cells[3], "Float \{hex64(152.0.reinterpret_as_uint64())}")
  // The reference writer itself spells -0.0 as 0.0 under bytecode: a code is a number.
  assert_eq(cells[5], "Float 0000000000000000")
  assert_eq(cells[9], "Float ffeffffffffffffe")
  assert_eq(cells[13], "Null")
}

///|
test "a code 254 spells eight blanks and a code 253 the eight bytes after the group" {
  let f = header(false, 1, 1)
  variable(f, 16, b"S", fmt(1, 16, 0))
  continuation(f)
  variable(f, 0, b"N", fmt(5, 8, 2))
  terminator(f)
  // Two blank units, the number 5, then its eight bytes; the rest of the
  // group fills with 0.
  ignore(f.raw(b"\xfe\xfe\x69\xfd\x00\x00\x00\x00"))
  ignore(f.raw(b"\x00\x00\x00\x00\x00\x00\x14\x40"))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), [
    "S(String): String ", "N(Float): Float 4014000000000000",
  ])
}

///|
test "the system-missing value a file's floating-point info record spells is the one honoured" {
  let own = (-1234.5).reinterpret_as_uint64()
  let f = header(false, 0, 3)
  variable(f, 0, b"N", fmt(5, 8, 2))
  let floating = File::new()
  ignore(floating.int(7).int(4).int(8).int(3))
  ignore(floating.wide(own.reinterpret_as_int64()))
  ignore(floating.wide(0x7FEFFFFFFFFFFFFFUL.reinterpret_as_int64()))
  ignore(floating.wide(0xFFEFFFFFFFFFFFFEUL.reinterpret_as_int64()))
  ignore(f.raw(floating.finish()))
  terminator(f)
  ignore(f.double(-1234.5))
  ignore(f.double(-1.7976931348623157e308))
  ignore(f.double(1.0))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(column(columns, "N"), [
    "Null", "Float ffefffffffffffff", "Float 3ff0000000000000",
  ])
}

///|
test "a date, datetime or time cell reads by its family's unit" {
  let day = 86400.0 * 159750.0
  let f = header(false, 0, 3)
  variable(f, 0, b"adate", fmt(23, 11, 0))
  variable(f, 0, b"qyr", fmt(29, 6, 0))
  variable(f, 0, b"stamp", fmt(22, 17, 0))
  variable(f, 0, b"time", fmt(21, 8, 2))
  variable(f, 0, b"mtime", fmt(40, 8, 2))
  variable(f, 0, b"wkday", fmt(26, 9, 0))
  variable(f, 0, b"month", fmt(27, 9, 0))
  terminator(f)
  for
    row in [
      [day, day, -0.5, 90.0, 90.0, 3.0, 1.0],
      [0.0, 0.0, 0.0, 0.0, 0.0, 7.0, 12.0],
      [
        day + 86400.0,
        day + 86400.0,
        12219379200.0,
        86399.25,
        86399.25,
        1.0,
        6.0,
      ],
    ] {
    for value in row {
      ignore(f.double(value))
    }
  }
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), [
    "adate(Date): Date 18322, Date -141428, Date 18323", "qyr(Date): Date 18322, Date -141428, Date 18323",
    "stamp(Timestamp): Timestamp -12219379200500000, Timestamp -12219379200000000, Timestamp 0",
    "time(Timestamp): Timestamp 90000000, Timestamp 0, Timestamp 86399250000", "mtime(Timestamp): Timestamp 90000000, Timestamp 0, Timestamp 86399250000",
    "wkday(Float): Float 4008000000000000, Float 401c000000000000, Float 3ff0000000000000",
    "month(Float): Float 3ff0000000000000, Float 4028000000000000, Float 4018000000000000",
  ])
}

///|
test "one cell short of the unit leaves its whole column numbers" {
  let (columns, _) = read_fixture("pyrs_fractional.sav")
  assert_eq(columns.map(pair => "\{pair.0} \{pair.1.dtype()}"), [
    "half_day Float", "submicro_d Float", "submicro_t Float", "neg_date Date", "neg_stamp Timestamp",
  ])
  assert_eq(column(columns, "neg_date"), [
    "Date -141429", "Date -141428", "Date -141427", "Null",
  ])
  assert_eq(column(columns, "neg_stamp"), [
    "Timestamp -12219379200500000", "Timestamp -12219379200000000", "Timestamp -12219379199000000",
    "Null",
  ])
}

///|
test "a variable's declared missing values read as null" {
  let (columns, _) = read_fixture("pyrs_missing.sav")
  assert_eq(column(columns, "m3"), [
    "Null", "Null", "Null", "Float 4010000000000000", "Float 4014000000000000",
  ])
  assert_eq(column(columns, "mrange"), [
    "Float 3ff0000000000000", "Null", "Null", "Null", "Float 4022000000000000",
  ])
  assert_eq(column(columns, "mrangev"), [
    "Float 3ff0000000000000", "Null", "Float 4022000000000000", "Float 4024000000000000",
    "Null",
  ])
  assert_eq(column(columns, "mopen"), [
    "Null", "Null", "Float 4012000000000000", "Float 4022000000000000", "Null",
  ])
  assert_eq(column(columns, "s3"), [
    "Null", "String a", "Null", "String b", "String ",
  ])
  assert_eq(column(columns, "s12"), [
    "Null", "String a", "String zzzzzzzzzzzz", "String b", "String ",
  ])
}

///|
test "value labels are not applied: a labelled column reads as its numbers" {
  let (columns, rows) = read_fixture("pyrs_labels.sav")
  assert_eq(rows, 3)
  assert_eq(spelled_columns(columns), [
    "num(Float): Float 3ff0000000000000, Float 4000000000000000, Float 3ff0000000000000",
    "s(String): String a, String b, String a",
  ])
}

///|
test "windows-1252's printable range, Latin-1, and character code 2 decode as declared" {
  let (windows, _) = read_fixture("synthetic_windows1252.sav")
  assert_eq(column(windows, "t8"), [
    "String €€", "String “”", "String é", "String ",
  ])
  assert_eq(column(windows, "t12")[0], "String ™Ÿ x")
  let (latin, _) = read_fixture("synthetic_latin1.sav")
  assert_eq(column(latin, "t8"), [
    "String é¥ÿð", "String \u{81}\u{9d} x", "String ü", "String ",
  ])
  assert_eq(column(latin, "t12")[0], "String ß ab")
  let (code, _) = read_fixture("synthetic_codepage2.sav")
  assert_eq(column(code, "t12")[0], "String € z")
  let (unassigned, _) = read_fixture("synthetic_windows1252_c1.sav")
  assert_eq(column(unassigned, "t8")[2], "String \u{81}\u{8d} x")
}

///|
test "files in the other byte order read the same, uncompressed and bytecode-compressed" {
  let (plain, rows) = read_fixture("synthetic_big_endian.sav")
  assert_eq(rows, 4)
  assert_eq(spelled_columns(plain), [
    "a(Float): Float 3ff0000000000000, Float 4004000000000000, Float c008000000000000, Float 4010000000000000",
    "s(String): String aa, String bb, String cc, String dd",
  ])
  let (coded, count) = read_fixture("synthetic_big_endian_rows.sav")
  assert_eq(count, 17)
  assert_eq(column(coded, "v").length(), 17)
}

///|
test "a dictionary's value labels, document, and records of subtypes the reader does not read are stepped over" {
  let f = header(false, 0, 2)
  variable(f, 0, b"N", fmt(5, 8, 2))
  variable(f, 4, b"S", fmt(1, 4, 0))
  ignore(f.int(3).int(1))
  ignore(f.raw(b"\x00\x00\x00\x00\x00\x00\xf0\x3f\x04one    "))
  ignore(f.int(4).int(1).int(1))
  ignore(f.int(6).int(1))
  ignore(f.blanks(80))
  machine(f)
  ignore(f.int(7).int(11).int(4).int(4).blanks(16))
  ignore(f.int(7).int(16).int(8).int(2))
  ignore(f.wide(1L))
  ignore(f.wide(2L))
  ignore(f.int(7).int(18).int(1).int(5))
  ignore(f.raw(b"role("))
  ignore(f.int(7).int(21).int(1).int(3))
  ignore(f.raw(b"\x00\x00\x00"))
  ignore(f.int(7).int(99).int(0).int(5))
  ignore(f.int(7).int(3).int(2).int(8))
  ignore(f.blanks(16))
  terminator(f)
  ignore(f.double(1.0))
  ignore(f.text(b"one", 8))
  ignore(f.double(2.0))
  ignore(f.text(b"two", 8))
  let (columns, rows) = read_spss_frame(f.finish())
  assert_eq(rows, 2)
  assert_eq(spelled_columns(columns), [
    "N(Float): Float 3ff0000000000000, Float 4000000000000000", "S(String): String one, String two",
  ])
}

///|
test "a repeated extension record is passed over, and a machine record of the wrong length changes nothing" {
  let f = header(false, 0, 1)
  variable(f, 0, b"N", fmt(5, 8, 2))
  extension(f, 13, 1, 5, b"N=one")
  extension(f, 13, 1, 5, b"N=two")
  extension(
    f, 3, 2, 8, b"\x14\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x02\x00",
  )
  terminator(f)
  ignore(f.double(1.0))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(columns.map(pair => pair.0), ["one"])
}

///|
test "continuation records carrying a label and missing values are parsed like any other" {
  let f = header(false, 0, 1)
  variable(f, 16, b"S", fmt(1, 16, 0))
  let extra = File::new()
  ignore(extra.int(4).raw(b"abcd"))
  ignore(extra.raw(doubles([1.0])))
  record(f, -1, 1, 1, fmt(1, 16, 0), b"", extra.finish())
  terminator(f)
  ignore(f.text(b"abcdefgh", 8))
  ignore(f.text(b"ijklmnop", 8))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), ["S(String): String abcdefghijklmnop"])
}

///|
test "a string wider than 255 bytes spelled by one variable record is read by its width" {
  let f = header(false, 0, 1)
  variable(f, 264, b"S", fmt(1, 255, 0))
  let more = (264 + 7) / 8 - 1
  for _ in 0..<more {
    continuation(f)
  }
  terminator(f)
  ignore(f.raw(Bytes::makei(264, _ => b'x')))
  ignore(f.blanks(8))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), ["S(String): String " + repeat("x", 264)])
}

///|
test "a very long string's last segment can be all padding" {
  // 505 bytes: segments of 255, 255 and 1 declared width, the third
  // carrying no text at all.
  let f = header(false, 0, 1)
  variable(f, 255, b"S", fmt(1, 255, 0))
  for _ in 0..<31 {
    continuation(f)
  }
  variable(f, 255, b"T", fmt(1, 255, 0))
  for _ in 0..<31 {
    continuation(f)
  }
  variable(f, 1, b"U", fmt(1, 1, 0))
  extension(f, 14, 1, 9, lengths(505))
  terminator(f)
  ignore(f.raw(Bytes::makei(255, _ => b'a')))
  ignore(f.blanks(1))
  ignore(f.raw(Bytes::makei(250, _ => b'b')))
  ignore(f.blanks(6))
  ignore(f.blanks(8))
  let (columns, _) = read_spss_frame(f.finish())
  assert_eq(spelled_columns(columns), [
    "S(String): String " + repeat("a", 255) + repeat("b", 250),
  ])
}
