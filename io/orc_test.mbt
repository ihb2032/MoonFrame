// Blackbox tests for the ORC interchange at the io layer — the reference
// writer's files through the entries, the projection, and the refusals a
// caller meets. (One-file-one-test exemption: none — this is the format's
// only test file at this layer; the codec's own tests sit in its package.)

///|
/// The bytes of a file of the reference corpus, already in memory.
fn orc_file(name : String) -> Bytes {
  @fs.read_file_to_bytes(".github/fixtures/orc/reference/\{name}") catch {
    _ => b""
  }
}

///|
/// Whether two columns hold the same cells, two NaNs counting as one cell:
/// a float column of the corpus carries one, and a value's own equality
/// does not hold for it.
fn orc_same(left : Array[@types.Scalar], right : Array[@types.Scalar]) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i, cell in left {
    if cell.to_string() != right[i].to_string() {
      return false
    }
  }
  true
}

///|
test "the reference writer's files read through the entries" {
  // One column a carried scalar type, nulls among the cells.
  let path = ".github/fixtures/orc/reference/pyorc_scalars.orc"
  let df = @io.read_orc(path)
  assert_eq(df.shape(), (12, 12))
  assert_eq(df.columns(), [
    "b", "tiny", "small", "int", "big", "flt", "dbl", "str", "ts", "dt", "dec", "wide",
  ])
  fn cell(name : String, at : Int32) -> @types.Scalar raise @types.DataError {
    df.get_column(name).to_scalars()[at]
  }
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(cell("b", 0), @types.Scalar::Bool(true))
  assert_eq(cell("b", 1), @types.Scalar::Bool(false))
  assert_eq(cell("b", 2), @types.Scalar::Null)
  assert_eq(df.get_column("tiny").dtype(), @types.DataType::Int)
  assert_eq(cell("small", 0), @types.Scalar::Int(1))
  assert_eq(cell("small", 4), @types.Scalar::Null)
  assert_eq(cell("big", 4), @types.Scalar::Int(4))
  // A 32-bit float reads as the double that holds it exactly.
  assert_eq(df.get_column("flt").dtype(), @types.DataType::Float)
  assert_eq(cell("flt", 0), @types.Scalar::Float(1.5))
  assert_eq(cell("flt", 1), @types.Scalar::Float(-2.25))
  assert_eq(cell("flt", 2), @types.Scalar::Null)
  assert_eq(cell("dbl", 3), @types.Scalar::Float(3.5))
  assert_eq(cell("str", 0), @types.Scalar::String("Nevada"))
  assert_eq(cell("str", 1), @types.Scalar::Null)
  assert_eq(cell("str", 2), @types.Scalar::String(""))
  assert_eq(cell("str", 4), @types.Scalar::String("ünïcödé"))
  assert_eq(df.get_column("ts").dtype(), @types.DataType::Timestamp)
  assert_eq(cell("ts", 0), @types.Scalar::Timestamp(1L))
  assert_eq(cell("ts", 1), @types.Scalar::Null)
  assert_eq(cell("ts", 2), @types.Scalar::Timestamp(1583054696789000L))
  assert_eq(cell("ts", 3), @types.Scalar::Timestamp(-1000L))
  assert_eq(df.get_column("dt").dtype(), @types.DataType::Date)
  assert_eq(cell("dt", 0), @types.Scalar::Null)
  assert_eq(cell("dt", 1), @types.Scalar::Date(0L))
  assert_eq(cell("dt", 4), @types.Scalar::Date(20000L))
  assert_eq(df.get_column("dec").dtype(), @types.DataType::Decimal)
  assert_eq(cell("dec", 0), @types.Scalar::Null)
  assert_eq(
    cell("dec", 1),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(125L, scale=2)),
  )
  assert_eq(
    cell("dec", 2),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(-750L, scale=2)),
  )
  assert_eq(
    cell("dec", 4),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(9999999999L, scale=2)),
  )
  assert_eq(df.get_column("wide").dtype(), @types.DataType::Decimal)
  assert_eq(cell("wide", 0), @types.Scalar::Null)
  assert_eq(
    cell("wide", 2),
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(-1L, scale=2)),
  )
  // Lists and structs, a null and an empty list at every level.
  let nested = @io.read_orc(".github/fixtures/orc/reference/pyorc_nested.orc")
  assert_eq(nested.shape(), (8, 6))
  assert_eq(nested.columns(), ["li", "ls", "ll", "lst", "st", "deep"])
  assert_eq(
    nested.get_column("li").dtype(),
    @types.DataType::List(@types.DataType::Int),
  )
  let lists = nested.get_column("li").to_scalars()
  assert_eq(
    lists[0],
    @types.Scalar::List(
      @types.ListValue::ListValue([
        @types.Scalar::Int(1),
        @types.Scalar::Int(2),
        @types.Scalar::Int(3),
      ]),
    ),
  )
  assert_eq(lists[1], @types.Scalar::Null)
  assert_eq(lists[2], @types.Scalar::List(@types.ListValue::ListValue([])))
  let record = @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::String),
      @types.Field::Field(
        "c",
        @types.DataType::Struct(
          @types.Schema::Schema([
            @types.Field::Field("d", @types.DataType::Float),
            @types.Field::Field("e", @types.DataType::Bool),
          ]),
        ),
      ),
    ]),
  )
  assert_eq(nested.get_column("st").dtype(), record)
  assert_eq(
    nested.get_column("st").to_scalars()[2],
    @types.Scalar::Struct(
      @types.StructValue::StructValue([
        @types.FieldValue::FieldValue("a", @types.Scalar::Null),
        @types.FieldValue::FieldValue("b", @types.Scalar::Null),
        @types.FieldValue::FieldValue("c", @types.Scalar::Null),
      ]),
    ),
  )
  // Each compression kind reads the same table.
  let plain = @io.read_orc(
    ".github/fixtures/orc/reference/pyorc_small_uncompressed.orc",
  )
  assert_eq(plain.shape(), (5, 2))
  assert_eq(plain.columns(), ["a", "s"])
  for kind in ["zlib", "snappy", "lz4", "zstd"] {
    let coded = @io.read_orc(
      ".github/fixtures/orc/reference/pyorc_small_\{kind}.orc",
    )
    assert_eq(coded.shape(), plain.shape())
    for column in plain.columns() {
      assert_eq(
        coded.get_column(column).to_scalars(),
        plain.get_column(column).to_scalars(),
      )
    }
  }
  // So does the format's earlier version.
  let earlier = @io.read_orc(
    ".github/fixtures/orc/reference/pyorc_scalars_v011.orc",
  )
  assert_eq(earlier.columns(), df.columns())
  for column in df.columns() {
    assert_true(
      orc_same(
        earlier.get_column(column).to_scalars(),
        df.get_column(column).to_scalars(),
      ),
    )
  }
  // The bytes already in memory parse to the same frame.
  let bytes = orc_file("pyorc_scalars.orc")
  let parsed = @io.parse_orc(bytes)
  for column in df.columns() {
    assert_true(
      orc_same(
        parsed.get_column(column).to_scalars(),
        df.get_column(column).to_scalars(),
      ),
    )
  }
  // A projection keeps the fields it names, in the file's order; one naming
  // nothing the file carries keeps the rows.
  let kept = @io.parse_orc(bytes, projection=["str", "b"])
  assert_eq(kept.shape(), (12, 2))
  assert_eq(kept.columns(), ["b", "str"])
  assert_eq(
    kept.get_column("str").to_scalars()[0],
    @types.Scalar::String("Nevada"),
  )
  assert_eq(@io.parse_orc(bytes, projection=["no_such_field"]).shape(), (12, 0))
  // A file carrying a column this reader does not carry reads under a
  // projection that does not name it.
  let every = orc_file("orc_TestOrcFile.test1.orc")
  let carried = @io.parse_orc(every, projection=["string1", "long1"])
  assert_eq(carried.shape(), (2, 2))
  assert_eq(carried.columns(), ["long1", "string1"])
  assert_eq(carried.get_column("long1").to_scalars(), [
    @types.Scalar::Int(9223372036854775807L),
    @types.Scalar::Int(9223372036854775807L),
  ])
  assert_eq(carried.get_column("string1").to_scalars(), [
    @types.Scalar::String("hi"),
    @types.Scalar::String("bye"),
  ])
}

///|
/// The error an entry raises; a frame answered instead fails the test.
fn orc_raised(
  read : () -> @frame.DataFrame raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(ignore(read())) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the file read as a frame")
    Err(e) => e
  }
}

///|
test "the ORC entries raise the errors a caller meets" {
  // A path that cannot be read is the read's IoError.
  let missing = orc_raised(() => @io.read_orc("_build/no_such_orc.orc"))
  assert_true(missing is @types.DataError::IoError(_))
  // Bytes that spell the magic neither at their end nor at their head, and
  // a file cut short inside a compression block's header.
  assert_eq(
    orc_raised(() => @io.parse_orc(b"not an orc file at all")),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "orc: byte 0: not an ORC file: neither the end of the PostScript nor the head spells the magic",
      ),
    ),
  )
  assert_eq(
    orc_raised(() => @io.parse_orc(orc_file("broken_block_header_cut.orc"))),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "orc: byte 440: the Footer: a block header cut short",
      ),
    ),
  )
  // A column of a type this reader does not carry, by its name.
  assert_eq(
    orc_raised(() => @io.parse_orc(orc_file("orc_TestOrcFile.test1.orc"))),
    @types.DataError::Unsupported(
      "orc: column \"bytes1\" is BINARY, which has no dtype here",
    ),
  )
  // A compression kind and a format version this reader does not read.
  assert_eq(
    orc_raised(() => @io.parse_orc(orc_file("synthetic_lzo.orc"))),
    @types.DataError::Unsupported(
      "orc: the LZO compression kind, which this reader does not decode",
    ),
  )
  assert_eq(
    orc_raised(() => @io.parse_orc(orc_file("orc_version1999.orc"))),
    @types.DataError::Unsupported(
      "orc: a file of format version 19.99, which this reader does not read",
    ),
  )
  // A timestamp a microsecond count cannot carry.
  assert_eq(
    orc_raised(() => @io.parse_orc(orc_file("pyorc_timestamp_nanos.orc"))),
    @types.DataError::Unsupported(
      "orc: column \"t\" holds a timestamp with a nanosecond remainder, 1 ns in its second, which a microsecond timestamp cannot carry",
    ),
  )
  // Two top-level fields of one name come back both; the frame refuses them.
  assert_eq(
    orc_raised(() => @io.parse_orc(orc_file("pyorc_dupnames.orc"))),
    @types.DataError::DuplicateColumn("a"),
  )
}
