// Blackbox tests of the edges: a table with no column, one with no row, a
// column of nothing but missing values, and names and strings at the
// format's limits.

///|
test "a table with no column writes a file of header records only, which reads back as 0 x 0" {
  let bytes = write_xport_bytes([])
  // Eight header records and the observation header record.
  assert_eq(bytes.length(), 720)
  let (columns, height) = read_xport_frame(bytes)
  assert_eq(columns.length(), 0)
  assert_eq(height, 0)
  // A pinned height of zero writes the same file; any other has no place
  // to go, which the refusal tests pin.
  let pinned = write_xport_bytes([], height=0)
  assert_eq(pinned.length(), bytes.length())
  for i in 0..<bytes.length() {
    if pinned[i] != bytes[i] {
      fail("byte \{i} differs between a pinned and an unpinned empty table")
    }
  }
}

///|
test "a table with columns and no row keeps its columns, in order and with their dtypes" {
  let columns : Array[@series.Series] = [
    @series.Series::from_bools("flag", []),
    @series.Series::from_ints("num", []),
    @series.Series::from_floats("ratio", []),
    @series.Series::from_strings("label", []),
    @series.Series::from_date_options("day", []),
    @series.Series::from_timestamp_options("stamp", []),
  ]
  let (read, height) = read_xport_frame(write_xport_bytes(columns))
  assert_eq(height, 0)
  assert_eq(read.length(), 6)
  let names : ReadOnlyArray[String] = [
    "flag", "num", "ratio", "label", "day", "stamp",
  ]
  let dtypes : ReadOnlyArray[@types.DataType] = [
    @types.DataType::Float,
    @types.DataType::Float,
    @types.DataType::Float,
    @types.DataType::String,
    @types.DataType::Date,
    @types.DataType::Timestamp,
  ]
  for i, (name, series) in read {
    assert_eq(name, names[i])
    assert_eq(series.dtype(), dtypes[i])
    assert_eq(series.len(), 0)
  }
  println(
    "edges: a table of six columns and no row keeps its columns and dtypes",
  )
}

///|
test "a column of nothing but missing values reads as nulls, never as the string \"null\"" {
  let nothing = @series.Series::from_i64_options(
    "nothing",
    @types.DataType::Null,
    [None, None, None],
  )
  let (read, height) = read_xport_frame(write_xport_bytes([nothing]))
  assert_eq(height, 3)
  assert_eq(read[0].1.dtype(), @types.DataType::Float)
  assert_eq(read[0].1.null_count(), 3)
  // A text column of nothing but missing cells is blanks in the file, and
  // blanks are the empty string — and a row of nothing else is padding, so
  // a number beside it keeps the rows.
  let blank = [
    @series.Series::from_ints("keep", [1L, 2L]),
    @series.Series::from_string_options("blank", [None, None]),
  ]
  let (text, text_rows) = read_xport_frame(write_xport_bytes(blank))
  assert_eq(text_rows, 2)
  assert_eq(text[1].1.dtype(), @types.DataType::String)
  assert_eq(spelled(text[1].1.to_scalars()[0]), "String ")
  assert_eq(spelled(text[1].1.to_scalars()[1]), "String ")
  // A missing cell beside a present one keeps the present one.
  let mixed = @series.Series::from_float_options("mixed", [Some(1.5), None])
  let (numbers, _) = read_xport_frame(write_xport_bytes([mixed]))
  assert_eq(spelled(numbers[0].1.to_scalars()[0]), "Float 3ff8000000000000")
  assert_eq(numbers[0].1.to_scalars()[1], @types.Scalar::Null)
  // The same of an `Int`, a `Date` and a `Timestamp` column.
  let counts = [
    @series.Series::from_int_options("n", [Some(1L), None]),
    @series.Series::from_date_options("d", [None, Some(1L)]),
    @series.Series::from_timestamp_options("t", [Some(15625L), None]),
  ]
  let (kept, kept_rows) = read_xport_frame(write_xport_bytes(counts))
  assert_eq(kept_rows, 2)
  assert_eq(spelled(kept[0].1.to_scalars()[0]), "Float 3ff0000000000000")
  assert_eq(kept[0].1.to_scalars()[1], @types.Scalar::Null)
  assert_eq(kept[1].1.to_scalars()[0], @types.Scalar::Null)
  assert_eq(spelled(kept[1].1.to_scalars()[1]), "Date 1")
  assert_eq(spelled(kept[2].1.to_scalars()[0]), "Timestamp 15625")
  assert_eq(kept[2].1.to_scalars()[1], @types.Scalar::Null)
}

///|
test "names at eight characters and strings at 200 bytes round trip as spelled" {
  let names : ReadOnlyArray[String] = [
    "abcdefgh", "_", "_1234567", "Z9", "Mixed",
  ]
  let texts : ReadOnlyArray[String] = [
    repeated("x", 200),
    repeated("é", 100),
    repeated("日", 66),
    "",
  ]
  let columns : Array[@series.Series] = []
  for name in names {
    columns.push(@series.Series::from_ints(name, [1L, 2L, 3L, 4L]))
  }
  columns.push(
    @series.Series::from_string_options("text", [
      Some(texts[0]),
      Some(texts[1]),
      Some(texts[2]),
      Some(texts[3]),
    ]),
  )
  // The last row's text is blank, so a number keeps the row.
  columns.push(@series.Series::from_ints("keep", [1L, 2L, 3L, 4L]))
  let bytes = write_xport_bytes(columns)
  // The text variable is 200 bytes wide: the sixth NAMESTR's width field.
  let width_at = 640 + 5 * 140 + 4
  assert_eq(bytes[width_at].to_int(), 200 >> 8)
  assert_eq(bytes[width_at + 1].to_int(), 200 & 0xFF)
  // Five names and `keep` at 8 bytes each, 200: a row is 248 bytes; four
  // rows are 992, padded to 1040. Seven NAMESTRs fill 1040 bytes of
  // records, so the observations start at byte 1760.
  assert_eq(bytes.length(), 1760 + 1040)
  let (read, height) = read_xport_frame(bytes)
  assert_eq(height, 4)
  for i, name in names {
    assert_eq(read[i].0, name)
  }
  let back = read[5].1.to_scalars()
  for row in 0..<4 {
    if !cell_equal(back[row], @types.Scalar::String(texts[row])) {
      fail("text, row \{row + 1}: read back \{spelled(back[row])}")
    }
  }
  println(
    "edges: names at eight characters and strings at 200, 198 and 0 bytes round trip",
  )
}

///|
test "a last row of nothing but blank character cells is padding to the reader" {
  // The format pads its last record with blanks, so a trailing row whose
  // every cell is blank cannot be told from the padding.
  let text = @series.Series::from_strings("t", ["ab", "cd", ""])
  let (lost, lost_rows) = read_xport_frame(write_xport_bytes([text]))
  assert_eq(lost_rows, 2)
  assert_eq(spelled(lost[0].1.to_scalars()[0]), "String ab")
  assert_eq(spelled(lost[0].1.to_scalars()[1]), "String cd")
  // A blank cell beside a number is kept: the row is not all blank.
  let kept = [
    @series.Series::from_ints("n", [1L, 2L, 3L]),
    @series.Series::from_strings("t", ["ab", "cd", ""]),
  ]
  let (read, height) = read_xport_frame(write_xport_bytes(kept))
  assert_eq(height, 3)
  assert_eq(spelled(read[1].1.to_scalars()[2]), "String ")
}

///|
test "one observation, and a one-byte text column, round trip" {
  let (one, height) = read_xport_frame(
    write_xport_bytes([@series.Series::from_strings("c", ["a"])]),
  )
  assert_eq(height, 1)
  assert_eq(spelled(one[0].1.to_scalars()[0]), "String a")
  let (empty_text, no_rows) = read_xport_frame(
    write_xport_bytes([@series.Series::from_strings("c", [""])]),
  )
  // The only row is a blank cell: it is the padding.
  assert_eq(no_rows, 0)
  assert_eq(empty_text[0].1.dtype(), @types.DataType::String)
}

///|
test "height pins the height when columns are present, and is derived when not" {
  let columns = [
    @series.Series::from_ints("a", [1L, 2L, 3L]),
    @series.Series::from_ints("b", [4L, 5L, 6L]),
  ]
  let (_, derived) = read_xport_frame(write_xport_bytes(columns))
  let (_, pinned) = read_xport_frame(write_xport_bytes(columns, height=3))
  assert_eq(derived, 3)
  assert_eq(pinned, 3)
}
