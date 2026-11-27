// Blackbox tests of the reading contract, one test per point of it, each
// on the reference file that carries the case. The sweep over every file
// already compares every cell with what
// the reference reader got; these name the rules, so a change in one of
// them fails a test that says which.

///|
/// A reference file through the codec.
fn reference(
  file : String,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  read_stata_frame(fixture(".github/fixtures/stata/reference/\{file}"))
}

///|
/// One column of a reference file.
fn reference_column(
  file : String,
  name : String,
) -> @series.Series raise @types.DataError {
  let (columns, _) = reference(file)
  for (column, series) in columns {
    if column == name {
      return series
    }
  }
  raise problem("\{file} carries no column \"\{name}\"")
}

///|
/// A column's dtype and cells, as one value to compare.
fn shape(series : @series.Series) -> (@types.DataType, Array[@types.Scalar]) {
  (series.dtype(), series.to_scalars())
}

///|
test "releases 113 to 119 read, in both byte orders where a writer produced them" {
  let index = jarray(
    fixture_json(".github/fixtures/stata/reference/index.json"),
  )
  let seen : Map[Int32, Array[String]] = Map([])
  for entry in index {
    let release = jint(field(entry, "release"))
    let order = jstring(field(entry, "byteorder"))
    match seen.get(release) {
      None => seen[release] = [order]
      Some(orders) => if !orders.contains(order) { orders.push(order) }
    }
  }
  for release in 113..<=119 {
    match seen.get(release) {
      None => fail("no reference file of release \{release}")
      Some(orders) => assert_true(orders.length() > 0)
    }
  }
  // The reference writers produced both byte orders of these four.
  for release in [114, 117, 118, 119] {
    let orders = seen.get(release).unwrap()
    if orders.length() != 2 {
      fail(
        "release \{release}: the corpus holds \{orders.length()} byte order(s) of it",
      )
    }
  }
}

///|
test "every missing code in every numeric storage reads as a null cell" {
  let files : ReadOnlyArray[String] = [
    "codes_pandas_v114_le.dta", "codes_pandas_v114_be.dta", "codes_pandas_v118_le.dta",
    "codes_pandas_v118_be.dta", "codes_pyreadstat_v113.dta", "codes_pyreadstat_v115.dta",
    "codes_pyreadstat_v117.dta", "codes_pyreadstat_v118.dta", "codes_pyreadstat_v119.dta",
  ]
  for file in files {
    let (columns, height) = reference(file)
    assert_eq(height, 27)
    assert_true(columns.length() > 0)
    for (_, series) in columns {
      // `.`, `.a` to `.z`: 27 rows, every cell missing.
      assert_eq(series.len(), 27)
      assert_eq(series.null_count(), 27)
    }
  }
  // The integer storages stay Int columns and the floating ones Float.
  assert_eq(
    reference_column("codes_pandas_v118_le.dta", "tbyte").dtype(),
    @types.DataType::Int,
  )
  assert_eq(
    reference_column("codes_pandas_v118_le.dta", "tdouble").dtype(),
    @types.DataType::Float,
  )
}

///|
test "a value outside the valid range that is no code reads as null too" {
  // byte -128, int -32768, long -2147483648, and in float and double the
  // infinities and a NaN of no code: the reference reader answers null
  // for each.
  let (columns, _) = reference("reserved_pandas_v118_le.dta")
  // Column by column: tbyte, tint, tlong, tfloat, tdouble.
  let second : ReadOnlyArray[@types.Scalar] = [
    @types.Scalar::Int(0L),
    @types.Scalar::Int(0L),
    @types.Scalar::Int(0L),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ]
  for i, (_, series) in columns {
    assert_eq(series.to_scalars(), [@types.Scalar::Null, second[i]])
  }
}

///|
test "a labelled column reads as the numbers it stores" {
  assert_eq(
    shape(reference_column("pandas_v118_le.dta", "labelled")),
    (
      @types.DataType::Int,
      [
        @types.Scalar::Int(1L),
        @types.Scalar::Int(2L),
        @types.Scalar::Int(1L),
        @types.Scalar::Int(3L),
        @types.Scalar::Int(2L),
        @types.Scalar::Int(1L),
      ],
    ),
  )
  assert_eq(
    shape(reference_column("pyreadstat_v118.dta", "labelled")),
    (
      @types.DataType::Int,
      [
        @types.Scalar::Int(1L),
        @types.Scalar::Int(2L),
        @types.Scalar::Int(1L),
        @types.Scalar::Int(3L),
        @types.Scalar::Int(2L),
        @types.Scalar::Int(1L),
      ],
    ),
  )
}

///|
test "a %td column reads as Date from an integer storage and from a whole double" {
  // Days since 1960-01-01 in the file, moved onto days since 1970-01-01.
  assert_eq(
    shape(reference_column("pyreadstat_v118.dta", "dlong")),
    (
      @types.DataType::Date,
      [
        @types.Scalar::Date(-3653L),
        @types.Scalar::Date(-3652L),
        @types.Scalar::Date(-3288L),
        @types.Scalar::Date(16406L),
        @types.Scalar::Date(-3653L),
        @types.Scalar::Date(-3654L),
      ],
    ),
  )
  // The reference writer stores a datetime as a whole double.
  assert_eq(reference_column("pandas_v118_le.dta", "date").to_scalars(), [
    @types.Scalar::Date(-3653L),
    @types.Scalar::Date(0L),
    @types.Scalar::Date(19782L),
    @types.Scalar::Date(-25567L),
    @types.Scalar::Date(10957L),
    @types.Scalar::Date(-3653L),
  ])
}

///|
test "a %td column of fractional cells stays a number" {
  let series = reference_column("pyreadstat_v118.dta", "ddbl")
  assert_eq(series.dtype(), @types.DataType::Float)
  assert_eq(series.to_scalars()[1], @types.Scalar::Float(1.0))
}

///|
test "a %tc or %tC column reads as Timestamp from an integer storage and from a whole double" {
  // Milliseconds since 1960-01-01 in the file, moved onto microseconds
  // since 1970-01-01.
  let epoch = -315_619_200_000_000L
  assert_eq(reference_column("pyreadstat_v118.dta", "tcl").to_scalars(), [
    @types.Scalar::Timestamp(epoch),
    @types.Scalar::Timestamp(epoch + 1_000L),
    @types.Scalar::Timestamp(epoch + 86_399_000L),
    @types.Scalar::Timestamp(epoch + 172_800_000L),
    @types.Scalar::Timestamp(epoch + 5_000L),
    @types.Scalar::Timestamp(epoch - 1_000L),
  ])
  assert_eq(
    reference_column("pyreadstat_v118.dta", "tcl").dtype(),
    @types.DataType::Timestamp,
  )
  // The reference writer stores a datetime as a whole double.
  let stamp = reference_column("pandas_v118_le.dta", "stamp")
  assert_eq(stamp.dtype(), @types.DataType::Timestamp)
  assert_eq(
    stamp.to_scalars()[2],
    @types.Scalar::Timestamp(1_709_210_096_789_000L),
  )
  assert_eq(
    stamp.to_scalars()[3],
    @types.Scalar::Timestamp(-2_208_902_400_001_000L),
  )
}

///|
test "a %tc or %tC column of fractional cells stays a number" {
  let tcd = reference_column("pyreadstat_v118.dta", "tcd")
  assert_eq(tcd.dtype(), @types.DataType::Float)
  assert_eq(tcd.to_scalars()[1], @types.Scalar::Float(1.5))
  let tcc = reference_column("pyreadstat_v118.dta", "tcc")
  assert_eq(tcc.dtype(), @types.DataType::Float)
  assert_eq(tcc.to_scalars()[4], @types.Scalar::Float(2.5))
}

///|
test "the other date families, and the old %d, leave their columns numeric" {
  for name in ["tm", "tq", "tw", "th", "ty", "dold"] {
    let series = reference_column("pyreadstat_v118.dta", name)
    assert_eq(series.dtype(), @types.DataType::Int)
    assert_eq(series.to_scalars()[0], @types.Scalar::Int(0L))
  }
  let other = reference_column("pyreadstat_v118.dta", "other")
  assert_eq(other.dtype(), @types.DataType::Float)
  assert_eq(other.to_scalars()[0], @types.Scalar::Float(1.25))
}

///|
test "text reads in the release's encoding, and bytes that are not UTF-8 fall back to Latin-1" {
  let latin = "Zoë ñ Ünïcode"
  // Releases before 118 are Latin-1: both reference writers agree.
  for file in ["pandas_v114_le.dta", "pandas_v117_be.dta"] {
    assert_eq(
      reference_column(file, "strf").to_scalars()[0],
      @types.Scalar::String(latin),
    )
  }
  // 118 and 119 are UTF-8.
  let utf8 = "café 日本語 😀 ñ"
  for file in ["pandas_v118_le.dta", "pandas_v119_be.dta"] {
    assert_eq(
      reference_column(file, "strf").to_scalars()[0],
      @types.Scalar::String(utf8),
    )
    assert_eq(
      reference_column(file, "strl").to_scalars()[4],
      @types.Scalar::String(utf8),
    )
  }
  // Latin-1 bytes in a release-118 file, and in a release-117 strL: the
  // reference reader's own answers.
  assert_eq(
    reference_column("synthetic_v118_latin1_in_utf8.dta", "strf").to_scalars()[0],
    @types.Scalar::String("Zoë"),
  )
  assert_eq(
    reference_column("synthetic_v117_latin1_in_strl.dta", "strl").to_scalars()[4],
    @types.Scalar::String("plaïn"),
  )
}

///|
test "an empty string is an empty cell, never a missing one" {
  let strf = reference_column("pandas_v118_le.dta", "strf")
  assert_eq(strf.to_scalars()[1], @types.Scalar::String(""))
  assert_eq(strf.null_count(), 0)
  let strl = reference_column("pandas_v118_le.dta", "strl")
  assert_eq(strl.to_scalars()[2], @types.Scalar::String(""))
  assert_eq(strl.null_count(), 0)
  // The same through the codec's own writer: a missing string cell
  // comes back empty, and present.
  let written = write_stata_bytes([@series.Series::from_strings("s", ["", "x"])])
  let (back, _) = read_stata_frame(written)
  assert_eq(back[0].1.to_scalars(), [
    @types.Scalar::String(""),
    @types.Scalar::String("x"),
  ])
}

///|
test "a long string resolves through the table: shared, empty, and past 2045 bytes" {
  let strl = reference_column("pandas_v118_le.dta", "strl")
  let cells = strl.to_scalars()
  assert_eq(cells[0], @types.Scalar::String("short"))
  assert_eq(cells[2], @types.Scalar::String(""))
  // One text held by two cells, longer than a fixed-width string allows.
  assert_eq(cells[1], cells[3])
  if cells[1] is String(text) {
    assert_true(@utf8.encode(text).length() > 2045)
    assert_eq(text[:4].to_owned(), "lore")
  } else {
    fail("the long cell is no string")
  }
  assert_eq(cells[4], @types.Scalar::String("café 日本語 😀 ñ"))
  // The limits beside it: a fixed-width string of exactly 2045 bytes and
  // one of a single byte, a long string of 2046 bytes, and a fixed-width
  // cell cut at an embedded NUL.
  let limits = reference("limits_pandas_v118_le.dta").0
  for (name, series) in limits {
    match name {
      "str2045" =>
        assert_eq(
          series.to_scalars()[0],
          @types.Scalar::String(String::make(2045, 'x')),
        )
      "str2044" => assert_eq(series.to_scalars()[1], @types.Scalar::String("z"))
      "str1" => assert_eq(series.to_scalars()[1], @types.Scalar::String("a"))
      "strl2046" => assert_eq(series.to_scalars()[1], @types.Scalar::String(""))
      "nulcut" => assert_eq(series.to_scalars()[0], @types.Scalar::String("ab"))
      _ => ()
    }
  }
}

///|
test "a name at the format's limit, and names outside ASCII in release 118" {
  let (limits, _) = reference("limits_pandas_v118_le.dta")
  assert_eq(limits[6].0, "a1234567890123456789012345678901")
  assert_eq(limits[6].0.length(), 32)
  assert_eq(limits[5].0, "x_1")
  let (names, _) = reference("names_pandas_v118_le.dta")
  let spelled = names.map(pair => pair.0)
  assert_eq(spelled, ["café", "变量", "_x1"])
}

///|
test "an empty table reads as what it is" {
  // No variable, no observation, in every tagged release and in 113.
  for
    file in [
      "empty_pyreadstat_v113.dta", "empty_pyreadstat_v115.dta", "empty_pyreadstat_v117.dta",
      "empty_pyreadstat_v118.dta", "empty_pyreadstat_v119.dta",
    ] {
    let (columns, height) = reference(file)
    assert_eq(columns.length(), 0)
    assert_eq(height, 0)
  }
  // Variables, no observation.
  for
    file in [
      "norows_pandas_v114_le.dta", "norows_pandas_v118_le.dta", "norows_pyreadstat_v115.dta",
    ] {
    let (columns, height) = reference(file)
    assert_eq(height, 0)
    assert_true(columns.length() > 0)
    for (_, series) in columns {
      assert_eq(series.len(), 0)
    }
  }
  // Observations, no variable: the count is the file's own.
  let (none, five) = reference("synthetic_v118_obs_no_var.dta")
  assert_eq(none.length(), 0)
  assert_eq(five, 5)
}

///|
test "release 116 reads through the binary header, as the release between 115 and 117 lays it out" {
  // The bytes are the 115 file's with the release byte changed; no
  // reference reader opens 116, so the cells are that file's sidecar.
  let (columns, height) = reference("synthetic_v116_from_pyreadstat_v115.dta")
  assert_eq(height, 6)
  assert_eq(columns.length(), 16)
  let (its_115, _) = reference("pyreadstat_v115.dta")
  for i, (name, series) in columns {
    assert_eq(name, its_115[i].0)
    assert_eq(series.dtype(), its_115[i].1.dtype())
    assert_eq(series.to_scalars(), its_115[i].1.to_scalars())
  }
}

///|
test "a projection keeps the variables it names, in the file's order, and the count stays the file's" {
  let whole = strl_file()
  // Out of file order, and with a name the file does not carry.
  let (kept, height) = read_stata_frame(whole, projection=[
    "brief", "nope", "notes",
  ])
  assert_eq(kept.map(pair => pair.0), ["notes", "brief"])
  assert_eq(height, 3)
  // A variable the projection leaves out is never read into a cell: a
  // long-string record of the binary kind refuses when its column is
  // read, and not when the column is left out.
  let kind_at = locate(whole, b"GSO", 0) + 15
  let binary = patched(whole, kind_at, 129)
  let (brief, rows) = read_stata_frame(binary, projection=["brief"])
  assert_eq(brief.map(pair => pair.0), ["brief"])
  assert_eq(rows, 3)
  assert_eq(brief[0].1.to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
  // Nothing named builds no column, and the count is still the file's.
  let (none, still) = read_stata_frame(whole, projection=["nope"])
  assert_eq(none.length(), 0)
  assert_eq(still, 3)
}
