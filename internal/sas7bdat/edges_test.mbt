// Blackbox tests of the edges: no row but columns; columns of nothing but
// missing values; names and strings at the format's limits; one
// observation; rows a page holds beyond the declared count; a row stored
// as a subheader; a layout declared twice; the page kinds that read like
// META pages; the missing spellings; numeric columns narrower than eight
// bytes; the date, time and datetime conversions on named cells; text
// cells through the character sets; the page kinds; a data set of no
// variable. The helpers `fixture`, `patched`,
// `read_error` and `le` are the refusal tests'.

///|
/// Positive infinity: one over zero, in double arithmetic.
let edge_infinity : Double = 1.0 / 0.0

///|
/// A reference file read through the codec.
fn table(
  stem : String,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  read_sas7bdat_frame(
    fixture(".github/fixtures/sas7bdat/reference/\{stem}.sas7bdat"),
  )
}

///|
/// The cells of the column called `name`, which must be there.
fn cells(
  table : Array[(String, @series.Series)],
  name : String,
) -> Array[@types.Scalar] raise {
  for (column, series) in table {
    if column == name {
      return series.to_scalars()
    }
  }
  fail("no column is called \{name}")
}

///|
/// The column called `name`, which must be there.
fn column_of(
  table : Array[(String, @series.Series)],
  name : String,
) -> @series.Series raise {
  for (column, series) in table {
    if column == name {
      return series
    }
  }
  fail("no column is called \{name}")
}

///|
/// The 32-bit reference table and its map: the places the tests patch.
struct EdgeBase {
  bytes : Bytes
  type_at : Int32
  page_at : Int32
  rows_at : Int32
  row_length : Int32
  last_at : Int32
  row_size : Json
}

///|
/// The 32-bit reference table, with its map read.
fn edge_base() -> EdgeBase raise {
  let map = fixture_json(
    ".github/fixtures/sas7bdat/reference/w32_pyrs.map.json",
  )
  let pointers = jarray(field(map, "pointers"))
  let last = pointers[pointers.length() - 1]
  let mut row_size = pointers[0]
  for pointer in pointers {
    // The last pointer names no subheader, so its kind is null.
    if field(pointer, "kind") is String(kind) && kind == "ROWSIZE" {
      row_size = pointer
    }
  }
  EdgeBase::{
    bytes: fixture(".github/fixtures/sas7bdat/reference/w32_pyrs.sas7bdat"),
    type_at: jlong(field(map, "type_at")).to_int(),
    page_at: jlong(field(map, "page_at")).to_int(),
    rows_at: jlong(field(map, "rows_at")).to_int(),
    row_length: jlong(field(map, "row_length")).to_int(),
    last_at: jlong(field(last, "at")).to_int(),
    row_size,
  }
}

///|
/// A text repeated `count` times.
fn times(text : String, count : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_string(text)
  }
  out.to_string()
}

///|
/// The text of the `ParseError` the reader raises for `bytes`.
fn parse_text(bytes : Bytes) -> String raise {
  match read_error(bytes) {
    @types.DataError::ParseError(@types.ParseErrorDetail::Message(text)) => text
    other => fail("the reader raised \{other}, not a ParseError")
  }
}

///|
test "columns and no row keep their columns, in order, with their dtypes" {
  let (columns, height) = table("no_rows_syn")
  assert_eq(height, 0)
  assert_eq(columns.length(), 3)
  assert_eq(columns[0].0, "a")
  assert_eq(columns[0].1.dtype(), @types.DataType::Float)
  assert_eq(columns[1].0, "b")
  assert_eq(columns[1].1.dtype(), @types.DataType::String)
  assert_eq(columns[2].0, "c")
  assert_eq(columns[2].1.dtype(), @types.DataType::Date)
  for _, (_name, series) in columns {
    assert_eq(series.len(), 0)
  }
  println(
    "edges: a table of three columns and no row keeps its columns and dtypes",
  )
}

///|
test "a column of nothing but missing values keeps its dtype, and blank text is the empty string" {
  let (columns, height) = table("all_missing_syn")
  assert_eq(height, 3)
  assert_eq(columns.length(), 4)
  assert_eq(column_of(columns, "a").dtype(), @types.DataType::Date)
  assert_eq(column_of(columns, "a").null_count(), 3)
  assert_eq(column_of(columns, "b").dtype(), @types.DataType::Timestamp)
  assert_eq(column_of(columns, "b").null_count(), 3)
  assert_eq(column_of(columns, "c").dtype(), @types.DataType::Float)
  assert_eq(column_of(columns, "c").null_count(), 3)
  assert_eq(cells(columns, "c"), [Null, Null, Null])
  assert_eq(column_of(columns, "e").null_count(), 0)
  assert_eq(cells(columns, "e"), [
    @types.Scalar::String(""),
    @types.Scalar::String(""),
    @types.Scalar::String(""),
  ])
}

///|
test "names at the format's 32 characters, and a character variable 32767 bytes wide" {
  let (columns, height) = table("names_syn")
  assert_eq(height, 2)
  assert_eq(columns.length(), 5)
  assert_eq(columns[0].0, times("a", 32))
  assert_eq(columns[0].0.length(), 32)
  assert_eq(columns[1].0, "_lead9")
  assert_eq(columns[2].0, "Mixed_Case")
  assert_eq(columns[3].0, "d1g1ts")
  assert_eq(columns[4].0, "wide")
  let wide = cells(columns, "wide")
  assert_eq(wide[0], @types.Scalar::String(times("x", 32767)))
  assert_eq(wide[1], @types.Scalar::String(times("y", 100)))
  println(
    "edges: names at 32 characters and strings at 32767 and 100 bytes read",
  )
}

///|
test "one observation, and a numeric column with no format subheader" {
  let (columns, height) = table("noformat_syn")
  assert_eq(height, 1)
  assert_eq(cells(columns, "a"), [@types.Scalar::Float(1.0)])
  assert_eq(cells(columns, "b"), [@types.Scalar::Float(2.0)])
  assert_eq(column_of(columns, "b").dtype(), @types.DataType::Float)
}

///|
test "rows a page holds past the declared count are not read, and a smaller count reads fewer" {
  // The 32-bit reference table declares two rows; its page says it holds
  // 3988.
  let b = edge_base()
  let (columns, height) = read_sas7bdat_frame(b.bytes)
  assert_eq(height, 2)
  assert_eq(cells(columns, "a"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
  ])
  assert_eq(cells(columns, "b"), [
    @types.Scalar::String("x"),
    @types.Scalar::String("yy"),
  ])
  // The row count is the row-size subheader's second field.
  let count_at = jlong(field(b.row_size, "row_count_at")).to_int()
  let bytes = patched(b.bytes, count_at, le(1, 4))
  let (fewer, height) = read_sas7bdat_frame(bytes)
  assert_eq(height, 1)
  assert_eq(cells(fewer, "a"), [@types.Scalar::Float(1.0)])
  assert_eq(cells(fewer, "b"), [@types.Scalar::String("x")])
  // Zero: the columns stay.
  let bytes = patched(bytes, count_at, le(0, 4))
  let (none, height) = read_sas7bdat_frame(bytes)
  assert_eq(height, 0)
  assert_eq(none.length(), 2)
  assert_eq(column_of(none, "a").dtype(), @types.DataType::Float)
  assert_eq(column_of(none, "b").dtype(), @types.DataType::String)
}

///|
test "a row stored uncompressed as a subheader reads as a row, before the page's own rows" {
  // The 32-bit reference table's last pointer is empty in the file. Made
  // to name a copy of the first row, with the type byte that marks a row,
  // it reads as the first observation.
  let b = edge_base()
  let free = b.rows_at + 64
  let copy = Bytes::makei(b.row_length, i => b.bytes[b.rows_at + i])
  let bytes = patched(b.bytes, free, copy)
  let bytes = patched(
    bytes,
    b.last_at,
    le(free - b.page_at, 4) + le(b.row_length, 4) + le(0, 1) + le(1, 1),
  )
  let (columns, height) = read_sas7bdat_frame(bytes)
  assert_eq(height, 2)
  assert_eq(cells(columns, "a"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(1.0),
  ])
  assert_eq(cells(columns, "b"), [
    @types.Scalar::String("x"),
    @types.Scalar::String("x"),
  ])
}

///|
test "a layout declared twice, saying the same both times, reads" {
  let b = edge_base()
  let sub_at = (jlong(field(b.row_size, "sub_at")) - b.page_at.to_int64()).to_int()
  let length = jlong(field(b.row_size, "length")).to_int()
  let bytes = patched(
    b.bytes,
    b.last_at,
    le(sub_at, 4) + le(length, 4) + le(0, 1) + le(0, 1),
  )
  let (columns, height) = read_sas7bdat_frame(bytes)
  assert_eq(height, 2)
  assert_eq(cells(columns, "a"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
  ])
}

///|
test "a META2 page reads like a META page, and so does an AMD page" {
  // The 32-bit table's MIX page, flagged META2.
  let b = edge_base()
  let (columns, height) = read_sas7bdat_frame(
    patched(b.bytes, b.type_at, le(0x4200, 2)),
  )
  assert_eq(height, 2)
  assert_eq(cells(columns, "b"), [
    @types.Scalar::String("x"),
    @types.Scalar::String("yy"),
  ])
  // The BINARY-compressed 32-bit table's first page is META, holding its
  // rows as subheaders; made an AMD page, the rows read the same — and
  // made a META2 page, over which compressed rows are read too.
  let whole = fixture(".github/fixtures/sas7bdat/reference/rdc32_pyrs.sas7bdat")
  let (columns, height) = read_sas7bdat_frame(whole)
  assert_eq(height, 3)
  let pattern = cells(columns, "pattern")
  // A 32-bit file: the page's type field lies at byte 16 of the page,
  // which follows the 1024-byte header.
  let (amd, amd_height) = read_sas7bdat_frame(
    patched(whole, 1024 + 16, le(0x0400, 2)),
  )
  assert_eq(amd_height, 3)
  assert_eq(cells(amd, "pattern"), pattern)
  assert_eq(cells(amd, "n2"), [
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(0.0),
  ])
  let (meta2, meta2_height) = read_sas7bdat_frame(
    patched(whole, 1024 + 16, le(0x4000, 2)),
  )
  assert_eq(meta2_height, 3)
  assert_eq(cells(meta2, "pattern"), pattern)
}

///|
test "rows on DATA pages behind a META page, or a META2 page, read in order" {
  // Eight rows over two DATA pages of four, behind a META page.
  let (meta, height) = table("pages_syn")
  assert_eq(height, 8)
  assert_eq(columns_of_names(meta), ["a", "b", "c"])
  for k in 0..<4 {
    assert_eq(cells(meta, "a")[2 * k], @types.Scalar::Float(1.0))
    assert_eq(cells(meta, "b")[2 * k], @types.Scalar::String("x"))
    assert_eq(cells(meta, "c")[2 * k], Null)
    assert_eq(cells(meta, "a")[2 * k + 1], @types.Scalar::Float(2.0))
    assert_eq(cells(meta, "b")[2 * k + 1], @types.Scalar::String("yy"))
    assert_eq(cells(meta, "c")[2 * k + 1], @types.Scalar::Float(3.0))
  }
  // Two rows on one DATA page behind a META2 page, in a big-endian file.
  let (meta2, meta2_height) = table("meta2_syn")
  assert_eq(meta2_height, 2)
  assert_eq(columns_of_names(meta2), ["a", "b", "c"])
  assert_eq(cells(meta2, "a"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
  ])
  assert_eq(cells(meta2, "b"), [
    @types.Scalar::String("x"),
    @types.Scalar::String("yy"),
  ])
  assert_eq(cells(meta2, "c"), [Null, @types.Scalar::Float(3.0)])
}

///|
/// The names of a table's columns, in order.
fn columns_of_names(table : Array[(String, @series.Series)]) -> Array[String] {
  let names = []
  for (name, _series) in table {
    names.push(name)
  }
  names
}

///|
test "a second text block, on an AMD page, names the columns that refer to it" {
  let (columns, height) = table("amd_syn")
  assert_eq(height, 2)
  assert_eq(columns_of_names(columns), ["a", "b", "c"])
  assert_eq(cells(columns, "a"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
  ])
  assert_eq(cells(columns, "c"), [Null, @types.Scalar::Float(3.0)])
}

///|
test "rows compressed in a 64-bit file read the same under either method, in either byte order" {
  // Laid out from scratch, with streams shorter than their rows: each
  // copies the row's head as it is and fills the blank tail of a 24-byte
  // text cell.
  for stem in ["rle64_syn", "rdc64_syn"] {
    let (columns, height) = table(stem)
    assert_eq(height, 2)
    assert_eq(columns_of_names(columns), ["a", "b"])
    assert_eq(cells(columns, "a"), [
      @types.Scalar::Float(1.0),
      @types.Scalar::Float(2.0),
    ])
    assert_eq(cells(columns, "b"), [
      @types.Scalar::String("x"),
      @types.Scalar::String("yy"),
    ])
  }
}

///|
test "a page carrying the type bits this reader passes over is passed over whole, subheaders included" {
  // The 32-bit table's one page, given the bits: nothing on it is read,
  // not even the row-size subheader.
  let b = edge_base()
  let refusal = "sas7bdat: byte 1024: the pages hold no row-size subheader"
  assert_eq(parse_text(patched(b.bytes, b.type_at, le(0x8200, 2))), refusal)
  // A page of a kind the layout does not name (type 0x0300) is passed over
  // the same way.
  assert_eq(parse_text(patched(b.bytes, b.type_at, le(0x0300, 2))), refusal)
}

///|
test "the 28 missing spellings read as null, and so does a NaN that is not one of them; infinities and -0.0 are numbers" {
  let (columns, height) = table("missing_syn")
  assert_eq(height, 32)
  let missing = cells(columns, "m")
  // ., ._ and .A to .Z.
  for i in 0..<28 {
    assert_eq(missing[i], Null)
  }
  // A quiet NaN, +inf, -inf and -0.0.
  assert_eq(missing[28], Null)
  assert_eq(missing[29], @types.Scalar::Float(edge_infinity))
  assert_eq(missing[30], @types.Scalar::Float(-edge_infinity))
  assert_eq(missing[31], @types.Scalar::Float(-0.0))
  assert_true(
    missing[31].as_float().reinterpret_as_uint64() == 0x8000000000000000UL,
  )
  assert_eq(column_of(columns, "m").null_count(), 29)
  // The column beside it kept its numbers.
  assert_eq(cells(columns, "keep")[7], @types.Scalar::Float(7.0))
  assert_eq(cells(columns, "keep")[31], @types.Scalar::Float(31.0))
}

///|
test "a numeric column one byte wide reads as zero, and the wider ones spell their leading bytes" {
  let (columns, height) = table("minimal_le32_syn")
  assert_eq(height, 3)
  assert_eq(columns.length(), 9)
  for i in 0..<8 {
    let (name, series) = columns[i]
    assert_eq(name, "w\{i + 1}")
    assert_eq(series.dtype(), @types.DataType::Float)
    assert_eq(series.len(), 3)
    assert_eq(series.null_count(), 0)
  }
  // One byte spells none of a number's mantissa: zero.
  assert_eq(cells(columns, "w1"), [
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(0.0),
  ])
  // Two bytes: 1 + 1/16, 2^14, and -(1 + 15/16) x 2^16.
  assert_eq(cells(columns, "w2"), [
    @types.Scalar::Float(1.0625),
    @types.Scalar::Float(16384.0),
    @types.Scalar::Float(-126976.0),
  ])
  // Eight: the least above one a double spells.
  assert_true(
    cells(columns, "w8")[0].as_float().reinterpret_as_uint64() ==
    0x3FF0000000000001UL,
  )
  // The text column beside them: padded, blank, accented.
  assert_eq(cells(columns, "t"), [
    @types.Scalar::String("ab"),
    @types.Scalar::String(""),
    @types.Scalar::String("é x"),
  ])
  println("edges: numeric columns one to eight bytes wide read")
}

///|
test "the same narrow numbers read the same in every layout the format has" {
  // Four files laid out from scratch with the same columns three to eight
  // bytes wide: 32-bit and 64-bit, little-endian and big-endian.
  let (le32, height) = table("minimal_le32_syn")
  assert_eq(height, 3)
  let layouts : ReadOnlyArray[String] = [
    "minimal_be32_syn", "minimal_le64_syn", "minimal_be64_syn",
  ]
  for stem in layouts {
    let (columns, rows) = table(stem)
    assert_eq(rows, 3)
    assert_eq(columns.length(), 7)
    for i, (name, series) in columns {
      assert_eq(name, le32[i + 2].0)
      assert_eq(series.dtype(), le32[i + 2].1.dtype())
      assert_true(
        series.equal(le32[i + 2].1),
        msg="\{stem}: column \{name} differs",
      )
    }
  }
  // Three bytes: 1 + 1/4096, 66, and -(2 + 1/8 + 1/64).
  assert_eq(cells(le32, "w3"), [
    @types.Scalar::Float(1.000244140625),
    @types.Scalar::Float(66.0),
    @types.Scalar::Float(-2.12451171875),
  ])
  println(
    "edges: narrow numbers read the same in 32-bit and 64-bit, little-endian and big-endian files",
  )
}

///|
test "a day is a day count since the epoch, a time microseconds on the epoch day, a datetime microseconds since the epoch" {
  let (columns, _height) = table("formats_syn")
  // 1 and 20000 days after 1960-01-01; a missing cell; the epoch itself.
  assert_eq(cells(columns, "v0"), [
    @types.Scalar::Date(-3652L),
    @types.Scalar::Date(16347L),
    Null,
    @types.Scalar::Date(-3653L),
  ])
  // TIME, of the nine time formats the first: 3661.5 seconds since
  // midnight, then 12345.678.
  assert_eq(cells(columns, "v10"), [
    @types.Scalar::Timestamp(0L),
    @types.Scalar::Timestamp(3661500000L),
    Null,
    @types.Scalar::Timestamp(12345678000L),
  ])
  // One second, and 12345.678 seconds, after 1960-01-01.
  let epoch = -315619200000000L
  assert_eq(cells(columns, "v19"), [
    @types.Scalar::Timestamp(epoch + 1000000L),
    @types.Scalar::Timestamp(epoch + 12345678000L),
    Null,
    @types.Scalar::Timestamp(epoch),
  ])
  // The calendar's two boundaries: 745153 days is 28 February 4000, 745154
  // the day after it in the calendar's count, 1 March.
  assert_eq(cells(columns, "cal_date"), [
    @types.Scalar::Date(741500L),
    @types.Scalar::Date(741502L),
    @types.Scalar::Date(2202470L),
    @types.Scalar::Date(2202472L),
  ])
  let first = 745153L * 86400L
  let day = 86400000000L
  assert_eq(cells(columns, "cal_dt"), [
    @types.Scalar::Timestamp((first + 1L) * 1000000L + epoch),
    @types.Scalar::Timestamp((first + 86400L + 1L) * 1000000L + day + epoch),
    @types.Scalar::Timestamp((2206122L * 86400L + 1L) * 1000000L + day + epoch),
    @types.Scalar::Timestamp(
      (2206123L * 86400L + 1L) * 1000000L + 2L * day + epoch,
    ),
  ])
}

///|
test "a fractional unit leaves the column numbers, and a whole one beside it converts" {
  let (columns, height) = table("frac_syn")
  assert_eq(height, 2)
  for name in ["d", "t", "dt"] {
    assert_eq(column_of(columns, name).dtype(), @types.DataType::Float)
  }
  assert_eq(cells(columns, "d"), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(2.25),
  ])
  assert_eq(cells(columns, "t"), [
    @types.Scalar::Float(1.0e-9),
    @types.Scalar::Float(0.5),
  ])
  assert_eq(cells(columns, "dt"), [
    @types.Scalar::Float(0.5),
    @types.Scalar::Float(1.0e-9),
  ])
  // Half a second and one and a half are whole microseconds: they convert.
  let epoch = -315619200000000L
  assert_eq(column_of(columns, "h").dtype(), @types.DataType::Timestamp)
  assert_eq(cells(columns, "h"), [
    @types.Scalar::Timestamp(epoch + 500000L),
    @types.Scalar::Timestamp(epoch + 1500000L),
  ])
  assert_eq(column_of(columns, "w").dtype(), @types.DataType::Date)
  assert_eq(cells(columns, "w"), [
    @types.Scalar::Date(-3652L),
    @types.Scalar::Date(-3651L),
  ])
}

///|
test "text cells: the padding is cut, a blank cell is empty, and the missing spellings are text" {
  let (columns, height) = table("kinds_syn")
  assert_eq(height, 5)
  assert_eq(cells(columns, "s"), [
    @types.Scalar::String("abc"),
    @types.Scalar::String("é"),
    @types.Scalar::String("日本語"),
    @types.Scalar::String("a b"),
    @types.Scalar::String(""),
  ])
  assert_eq(cells(columns, "t"), [
    @types.Scalar::String("  pad"),
    @types.Scalar::String(" ."),
    @types.Scalar::String("."),
    @types.Scalar::String(".A"),
    @types.Scalar::String("._"),
  ])
  assert_eq(cells(columns, "u"), [
    @types.Scalar::String(".Z"),
    @types.Scalar::String(".a"),
    @types.Scalar::String("a."),
    @types.Scalar::String(""),
    @types.Scalar::String(""),
  ])
  assert_eq(column_of(columns, "u").null_count(), 0)
  // The numbers: integers, NaN, infinities, -0.0, the smallest and the
  // largest double.
  assert_eq(cells(columns, "i"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(-2.0),
    @types.Scalar::Float(9007199254740992.0),
    @types.Scalar::Float(-9007199254740992.0),
    @types.Scalar::Float(9007199254740992.0),
  ])
  assert_eq(cells(columns, "f")[0], @types.Scalar::Float(0.0))
  assert_eq(cells(columns, "f")[1], Null)
  assert_eq(cells(columns, "f")[2], @types.Scalar::Float(edge_infinity))
  assert_eq(cells(columns, "f")[3], @types.Scalar::Float(-edge_infinity))
  assert_eq(cells(columns, "g")[0], @types.Scalar::Float(-0.0))
  assert_true(
    cells(columns, "g")[0].as_float().reinterpret_as_uint64() ==
    0x8000000000000000UL,
  )
  assert_eq(cells(columns, "g")[1], @types.Scalar::Float(5.0e-324))
  assert_eq(
    cells(columns, "g")[2],
    @types.Scalar::Float(1.7976931348623157e308),
  )
  assert_eq(cells(columns, "g")[3], @types.Scalar::Float(0.1))
  assert_eq(column_of(columns, "f").null_count(), 1)
  assert_eq(column_of(columns, "f").has_nan(), false)
  assert_eq(cells(columns, "b"), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(0.0),
    @types.Scalar::Float(1.0),
  ])
}

///|
test "bytes read one byte to one character through the code page the header names, whatever they spell elsewhere" {
  // A file that says Latin-1 (code 29): UTF-8's two- and three-byte
  // characters come back one byte to one character, controls included, in
  // a name as in a cell; all 128 bytes from 0x80 on are that range's
  // characters.
  let (columns, _height) = table("latin1_syn")
  assert_eq(columns[1].0, "nàme")
  assert_eq(cells(columns, "nàme"), [
    @types.Scalar::String("Ã©"),
    @types.Scalar::String("æ\u{97}¥æ\u{9c}¬èª\u{9e}"),
    @types.Scalar::String("abc"),
  ])
  assert_eq(cells(columns, "t"), [
    @types.Scalar::String(" ."),
    @types.Scalar::String(".A"),
    @types.Scalar::String("."),
  ])
  let high = cells(columns, "high")
  match high[0] {
    @types.Scalar::String(text) => {
      let units = text.code_units()
      assert_eq(units.length(), 128)
      assert_eq(units[0], 0x80)
      assert_eq(units[1], 0x81)
      assert_eq(units[126], 0xFE)
      assert_eq(units[127], 0xFF)
    }
    other => fail("the first cell is \{other}, not text")
  }
  assert_eq(high[2], @types.Scalar::String(""))
  // windows-1252 (code 62): the euro sign, an e-acute and a y-diaeresis,
  // and a name with a high byte.
  let (windows, _height) = table("cp1252_syn")
  assert_eq(columns_of_names(windows), ["nomé", "t"])
  assert_eq(cells(windows, "t"), [
    @types.Scalar::String("€éÿ"),
    @types.Scalar::String("a"),
  ])
  assert_eq(cells(windows, "nomé"), [
    @types.Scalar::String("café"),
    @types.Scalar::String("ÿ"),
  ])
  // windows-1251 (code 61), where such bytes spell Cyrillic; and
  // ISO-8859-15 (code 40), where four of them spell the euro sign and
  // three letters Latin-1 lacks.
  let (cyrillic, _height) = table("cp1251_syn")
  assert_eq(columns_of_names(cyrillic), ["имя"])
  assert_eq(cells(cyrillic, "имя"), [
    @types.Scalar::String("Привет"),
    @types.Scalar::String("мир"),
  ])
  let (latin9, _height) = table("latin9_syn")
  assert_eq(cells(latin9, "t"), [@types.Scalar::String("€ŠšŽ")])
}

///|
test "a data set of no variable has a row length of zero, and is refused" {
  assert_eq(
    parse_text(
      fixture(".github/fixtures/sas7bdat/reference/no_columns_syn.sas7bdat"),
    ),
    "sas7bdat: byte 1132: the row length is 0",
  )
}

///|
test "a column is named as the file spells it, past 32 characters and when it spells nothing" {
  let (columns, height) = table("long_names_syn")
  assert_eq(height, 2)
  assert_eq(columns.length(), 4)
  assert_eq(columns[0].0, times("n", 33))
  assert_eq(columns[1].0, "short")
  assert_eq(columns[2].0, times("z", 40))
  assert_eq(columns[3].0, "")
  assert_eq(cells(columns, "")[1], @types.Scalar::Float(6.0))
  assert_eq(cells(columns, times("z", 40)), [
    @types.Scalar::String("ab"),
    @types.Scalar::String(""),
  ])
  println(
    "edges: names of 33 and 40 characters and an empty name read as spelled",
  )
}
