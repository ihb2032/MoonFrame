// Blackbox tests of the Avro codec through the surface the io layer
// rides: the files a reference implementation wrote, read cell for cell
// under every block codec; the shapes the mapping refuses, each by
// name; the writer's round trip through the reader; and the malformed
// input corpus — every truncation and a seeded set of corrupted and
// garbage inputs read or refuse, and never abort.

///|
/// A fixture's bytes.
fn fixture(name : String) -> Bytes raise {
  let path = ".github/fixtures/avro/\{name}"
  @fs.read_file_to_bytes(path) catch {
    _ => fail("the fixture \{path} could not be read")
  }
}

///|
/// The refusal a read raised, failing the test when it read.
fn refused(
  bytes : Bytes,
  projection : Array[String]?,
) -> @types.DataError raise {
  let read : Result[(Array[(String, @series.Series)], Int32), @types.DataError] = Ok(
    read_avro_frame(bytes, projection),
  ) catch {
    e => Err(e)
  }
  match read {
    Ok(_) => fail("the read was expected to refuse")
    Err(e) => e
  }
}

///|
/// Whether a read refuses.
fn refuses(bytes : Bytes, projection : Array[String]?) -> Bool {
  let read : Result[(Array[(String, @series.Series)], Int32), @types.DataError] = Ok(
    read_avro_frame(bytes, projection),
  ) catch {
    e => Err(e)
  }
  read is Err(_)
}

///|
/// The records a read answered, failing the test when it refused.
fn records_in(bytes : Bytes, projection : Array[String]?) -> Int32 raise {
  let read : Result[(Array[(String, @series.Series)], Int32), @types.DataError] = Ok(
    read_avro_frame(bytes, projection),
  ) catch {
    e => Err(e)
  }
  match read {
    Ok((_, records)) => records
    Err(e) => fail("the read was expected to answer: \{e}")
  }
}

///|
/// The cells of column `name`, failing the test when it is not there.
fn column(
  frame : Array[(String, @series.Series)],
  name : String,
) -> Array[@types.Scalar] raise {
  for pair in frame {
    if pair.0 == name {
      return pair.1.to_scalars()
    }
  }
  fail("no column named \{name}")
}

///|
/// The dtype of column `name`.
fn dtype_of(
  frame : Array[(String, @series.Series)],
  name : String,
) -> @types.DataType raise {
  for pair in frame {
    if pair.0 == name {
      return pair.1.dtype()
    }
  }
  fail("no column named \{name}")
}

///|
fn list(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn color(r : Int64, g : Int64, b : @types.Scalar) -> @types.Scalar {
  @types.Scalar::Struct(
    @types.StructValue::StructValue([
      @types.FieldValue::FieldValue("r", @types.Scalar::Int(r)),
      @types.FieldValue::FieldValue("g", @types.Scalar::Int(g)),
      @types.FieldValue::FieldValue("b", b),
    ]),
  )
}

///|
/// An instant `micros` into the day that is `days` after the epoch.
fn instant(days : Int64, micros : Int64) -> @types.Scalar {
  @types.Scalar::Timestamp(days * 86_400_000_000L + micros)
}

///|
fn decimal(text : String) -> @types.Scalar {
  @types.Scalar::Decimal(
    @types.Dec128::parse_opt(text).unwrap_or(@types.Dec128::nan()),
  )
}

///|
/// The columns of the reference table, in the file's order.
fn table_columns() -> Array[String] {
  [
    "name", "age", "id", "height", "score", "active", "tags", "color", "again", "kind",
    "birth", "seen_millis", "seen_micros", "at_millis", "at_micros", "amount",
  ]
}

///|
test "every block codec the reader decodes reads the reference table" {
  for
    file in [
      "fastavro_types_null.avro", "fastavro_types_deflate.avro", "fastavro_types_snappy.avro",
      "fastavro_types_zstandard.avro",
    ] {
    let (frame, records) = read_avro_frame(fixture(file), None)
    assert_eq(records, 3)
    assert_eq(frame.map(pair => pair.0), table_columns())
    assert_eq(column(frame, "name"), [
      @types.Scalar::String("Zoë"),
      @types.Scalar::Null,
      @types.Scalar::String("日本語 – naïve 🌍"),
    ])
    assert_eq(dtype_of(frame, "name"), @types.DataType::String)
    assert_eq(column(frame, "age"), [
      @types.Scalar::Int(30L),
      @types.Scalar::Int(-1L),
      @types.Scalar::Int(2147483647L),
    ])
    assert_eq(column(frame, "id"), [
      @types.Scalar::Int(9007199254740993L),
      @types.Scalar::Int(-9223372036854775808L),
      @types.Scalar::Int(9223372036854775807L),
    ])
    assert_eq(dtype_of(frame, "id"), @types.DataType::Int)
    // A 32-bit float widens to the Double that holds it exactly.
    assert_eq(column(frame, "height"), [
      @types.Scalar::Float(1.75),
      @types.Scalar::Float(-0.0),
      @types.Scalar::Float(3.14159),
    ])
    assert_eq(column(frame, "score"), [
      @types.Scalar::Float(0.5),
      @types.Scalar::Float(1.5),
      @types.Scalar::Null,
    ])
    assert_eq(dtype_of(frame, "score"), @types.DataType::Float)
    assert_eq(column(frame, "active"), [
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
      @types.Scalar::Null,
    ])
    assert_eq(dtype_of(frame, "active"), @types.DataType::Bool)
    assert_eq(column(frame, "tags"), [
      list([@types.Scalar::String("a"), @types.Scalar::String("b")]),
      list([]),
      list([
        @types.Scalar::String("x"),
        @types.Scalar::Null,
        @types.Scalar::String(""),
      ]),
    ])
    assert_eq(
      dtype_of(frame, "tags"),
      @types.DataType::List(@types.DataType::String),
    )
    assert_eq(column(frame, "color"), [
      color(1L, 2L, @types.Scalar::Int(3L)),
      @types.Scalar::Null,
      color(-1L, 0L, @types.Scalar::Null),
    ])
    assert_eq(
      dtype_of(frame, "color"),
      @types.DataType::Struct(
        @types.Schema::Schema([
          @types.Field::Field("r", @types.DataType::Int),
          @types.Field::Field("g", @types.DataType::Int),
          @types.Field::Field("b", @types.DataType::Int),
        ]),
      ),
    )
    // A named type referred to by its name alone reads like its
    // definition.
    assert_eq(column(frame, "again"), [
      color(1L, 2L, @types.Scalar::Null),
      @types.Scalar::Null,
      color(7L, 8L, @types.Scalar::Int(9L)),
    ])
    assert_eq(dtype_of(frame, "again"), dtype_of(frame, "color"))
    // An enum reads as its symbol.
    assert_eq(column(frame, "kind"), [
      @types.Scalar::String("a"),
      @types.Scalar::String("c"),
      @types.Scalar::Null,
    ])
    assert_eq(column(frame, "birth"), [
      @types.Scalar::Date(19782L),
      @types.Scalar::Date(-3653L),
      @types.Scalar::Null,
    ])
    assert_eq(dtype_of(frame, "birth"), @types.DataType::Date)
    assert_eq(column(frame, "seen_millis"), [
      instant(19860L, 29_350_123_000L),
      @types.Scalar::Timestamp(0L),
      @types.Scalar::Null,
    ])
    // 9999-12-31T23:59:59.999999, the last instant the reference writes.
    assert_eq(column(frame, "seen_micros"), [
      instant(19860L, 29_350_123_456L),
      @types.Scalar::Null,
      @types.Scalar::Timestamp(253402300799999999L),
    ])
    assert_eq(dtype_of(frame, "seen_micros"), @types.DataType::Timestamp)
    // A time of day reads as the instant on the epoch day.
    assert_eq(column(frame, "at_millis"), [
      instant(0L, 47_655_123_000L),
      @types.Scalar::Timestamp(0L),
      @types.Scalar::Null,
    ])
    assert_eq(column(frame, "at_micros"), [
      instant(0L, 47_655_123_456L),
      instant(0L, 86_399_999_999L),
      @types.Scalar::Null,
    ])
    assert_eq(column(frame, "amount"), [
      decimal("-12345.6789"),
      decimal("0.0001"),
      decimal("99999999.9999"),
    ])
    assert_eq(dtype_of(frame, "amount"), @types.DataType::Decimal)
  }
}

///|
test "a block codec the reader does not decode refuses by name" {
  assert_eq(
    refused(fixture("fastavro_types_bzip2.avro"), None),
    @types.DataError::Unsupported("Avro: a block codec named \"bzip2\""),
  )
}

///|
test "the other logical types read as the types they name" {
  let (frame, records) = read_avro_frame(fixture("fastavro_logical.avro"), None)
  assert_eq(records, 2)
  assert_eq(frame.map(pair => pair.0), [
    "uuid", "fixed_amount", "local_millis", "unknown_logical", "int_outside",
  ])
  assert_eq(column(frame, "uuid"), [
    @types.Scalar::String("123e4567-e89b-12d3-a456-426614174000"),
    @types.Scalar::Null,
  ])
  // A decimal over a fixed type reads like one over bytes.
  assert_eq(column(frame, "fixed_amount"), [
    decimal("-12345.67"),
    decimal("0.01"),
  ])
  assert_eq(dtype_of(frame, "fixed_amount"), @types.DataType::Decimal)
  // A local timestamp carries no zone; its count reads as the same
  // instant, which is what the library's timestamp is.
  assert_eq(column(frame, "local_millis"), [
    instant(19860L, 29_350_123_000L),
    @types.Scalar::Null,
  ])
  // A logical type the format does not define leaves the count plain.
  assert_eq(column(frame, "unknown_logical"), [
    @types.Scalar::Int(7L),
    @types.Scalar::Null,
  ])
  assert_eq(dtype_of(frame, "unknown_logical"), @types.DataType::Int)
  assert_eq(column(frame, "int_outside"), [
    @types.Scalar::Int(3L),
    @types.Scalar::Int(9L),
  ])
}

///|
test "the shapes the mapping does not carry refuse, naming the field" {
  let cases : ReadOnlyArray[(String, String)] = [
    (
      "fastavro_refused_bytes.avro", "Avro: a bytes field \"blob\": the mapping has no binary column",
    ),
    (
      "fastavro_refused_map.avro", "Avro: a map field \"counts\": the mapping has no map column",
    ),
    (
      "fastavro_refused_union.avro", "Avro: a union field \"either\" of 3 branches: a column carries a null and one type",
    ),
    (
      "fastavro_refused_duration.avro", "Avro: a duration field \"span\": the months, days and milliseconds it holds are no single span",
    ),
    (
      "fastavro_refused_nanos.avro", "Avro: a nanosecond timestamp field \"at\": a timestamp here holds microseconds, and the nanoseconds would be rounded away",
    ),
    (
      "fastavro_refused_record_no_fields.avro", "Avro: a record field \"nothing\" with no field",
    ),
  ]
  for (file, message) in cases {
    assert_eq(
      refused(fixture(file), None),
      @types.DataError::Unsupported(message),
    )
    // A projection that leaves the refused field out never meets it: the
    // field is stepped over, whatever its type.
    let (frame, records) = read_avro_frame(fixture(file), Some(["kept"]))
    assert_eq(records, 2)
    assert_eq(frame.map(pair => pair.0), ["kept"])
    assert_eq(column(frame, "kept"), [
      @types.Scalar::Int(17L),
      @types.Scalar::Null,
    ])
  }
}

///|
test "a file of many blocks reads whole, and a projection reads its columns" {
  let bytes = fixture("fastavro_multiblock.avro")
  let (frame, records) = read_avro_frame(bytes, None)
  assert_eq(records, 1002)
  assert_eq(column(frame, "id").length(), 1002)
  assert_eq(column(frame, "id")[0], @types.Scalar::Int(9007199254740993L))
  assert_eq(column(frame, "id")[1001], @types.Scalar::Int(9223372036854775807L))
  assert_eq(column(frame, "name")[1000], @types.Scalar::Null)
  // Two of sixteen columns, in the file's order; the rest stepped over.
  let (projected, kept) = read_avro_frame(bytes, Some(["age", "name"]))
  assert_eq(kept, 1002)
  assert_eq(projected.map(pair => pair.0), ["name", "age"])
  assert_eq(column(projected, "name").length(), 1002)
  assert_eq(column(projected, "age")[1], @types.Scalar::Int(-1L))
  // Every column alone reads as it does among all the others.
  for name in table_columns() {
    let (alone, _) = read_avro_frame(bytes, Some([name]))
    assert_eq(column(alone, name), column(frame, name))
    assert_eq(dtype_of(alone, name), dtype_of(frame, name))
  }
  // A name the file does not carry builds no column, and the rows stay.
  let (none, rows) = read_avro_frame(bytes, Some(["nope"]))
  assert_eq(rows, 1002)
  assert_eq(none.length(), 0)
}

///|
/// A frame of every dtype the writer carries, with a null in each column.
fn written_frame() -> Array[@series.Series] raise {
  let struct_dtype = @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("k", @types.DataType::Int),
      @types.Field::Field("v", @types.DataType::String),
    ]),
  )
  [
    @series.Series::from_scalars(
      "n",
      [@types.Scalar::Int(1L), @types.Scalar::Null, @types.Scalar::Int(-5L)],
      dtype=@types.DataType::Int,
    ),
    @series.Series::from_scalars(
      "f",
      [
        @types.Scalar::Float(0.1),
        @types.Scalar::Null,
        @types.Scalar::Float(-0.0),
      ],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "b",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_scalars(
      "s",
      [
        @types.Scalar::String("Zoë"),
        @types.Scalar::Null,
        @types.Scalar::String(""),
      ],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "d",
      [
        @types.Scalar::Date(0L),
        @types.Scalar::Null,
        @types.Scalar::Date(19782L),
      ],
      dtype=@types.DataType::Date,
    ),
    @series.Series::from_scalars(
      "t",
      [
        @types.Scalar::Timestamp(1715933350123456L),
        @types.Scalar::Null,
        @types.Scalar::Timestamp(-1L),
      ],
      dtype=@types.DataType::Timestamp,
    ),
    @series.Series::from_scalars(
      "m",
      [decimal("12.5"), @types.Scalar::Null, decimal("-0.0001")],
      dtype=@types.DataType::Decimal,
    ),
    @series.Series::from_scalars(
      "l",
      [
        list([@types.Scalar::Int(1L), @types.Scalar::Null]),
        @types.Scalar::Null,
        list([]),
      ],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
    @series.Series::from_scalars(
      "r",
      [
        @types.Scalar::Struct(
          @types.StructValue::StructValue([
            @types.FieldValue::FieldValue("k", @types.Scalar::Int(1L)),
            @types.FieldValue::FieldValue("v", @types.Scalar::String("x")),
          ]),
        ),
        @types.Scalar::Null,
        @types.Scalar::Struct(
          @types.StructValue::StructValue([
            @types.FieldValue::FieldValue("k", @types.Scalar::Null),
            @types.FieldValue::FieldValue("v", @types.Scalar::Null),
          ]),
        ),
      ],
      dtype=struct_dtype,
    ),
  ]
}

///|
fn names_of(columns : Array[@series.Series]) -> Array[String] {
  columns.map(column => column.name())
}

///|
test "the writer's file reads back through the reader under every codec" {
  let columns = written_frame()
  for codec in [Codec::Null, Codec::Deflate, Codec::Snappy, Codec::Zstd] {
    let bytes = write_avro_bytes(columns, names_of(columns), codec)
    let (frame, records) = read_avro_frame(bytes, None)
    assert_eq(records, 3)
    assert_eq(frame.map(pair => pair.0), names_of(columns))
    for pair in frame {
      let wanted = columns.filter(c => c.name() == pair.0)[0]
      assert_eq(pair.1.to_scalars(), wanted.to_scalars())
      assert_eq(pair.1.dtype(), wanted.dtype())
    }
  }
}

///|
/// The reference table as columns of the dtypes the writer carries — the
/// cells the reference implementation wrote into its own files, minus
/// the two time-of-day columns, which have no dtype here to write from.
fn reference_frame() -> Array[@series.Series] raise {
  let shape = @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("r", @types.DataType::Int),
      @types.Field::Field("g", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::Int),
    ]),
  )
  let ints = (name : String, a : Int64, b : Int64, c : Int64) => {
    @series.Series::from_scalars(
      name,
      [@types.Scalar::Int(a), @types.Scalar::Int(b), @types.Scalar::Int(c)],
      dtype=@types.DataType::Int,
    )
  }
  [
    @series.Series::from_scalars(
      "name",
      [
        @types.Scalar::String("Zoë"),
        @types.Scalar::Null,
        @types.Scalar::String("日本語 – naïve 🌍"),
      ],
      dtype=@types.DataType::String,
    ),
    ints("age", 30L, -1L, 2147483647L),
    ints("id", 9007199254740993L, -9223372036854775808L, 9223372036854775807L),
    @series.Series::from_scalars(
      "height",
      [
        @types.Scalar::Float(1.75),
        @types.Scalar::Float(-0.0),
        @types.Scalar::Float(3.14159),
      ],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "score",
      [
        @types.Scalar::Float(0.5),
        @types.Scalar::Float(1.5),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "active",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_scalars(
      "tags",
      [
        list([@types.Scalar::String("a"), @types.Scalar::String("b")]),
        list([]),
        list([
          @types.Scalar::String("x"),
          @types.Scalar::Null,
          @types.Scalar::String(""),
        ]),
      ],
      dtype=@types.DataType::List(@types.DataType::String),
    ),
    @series.Series::from_scalars(
      "color",
      [
        color(1L, 2L, @types.Scalar::Int(3L)),
        @types.Scalar::Null,
        color(-1L, 0L, @types.Scalar::Null),
      ],
      dtype=shape,
    ),
    @series.Series::from_scalars(
      "again",
      [
        color(1L, 2L, @types.Scalar::Null),
        @types.Scalar::Null,
        color(7L, 8L, @types.Scalar::Int(9L)),
      ],
      dtype=shape,
    ),
    @series.Series::from_scalars(
      "kind",
      [
        @types.Scalar::String("a"),
        @types.Scalar::String("c"),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "birth",
      [
        @types.Scalar::Date(19782L),
        @types.Scalar::Date(-3653L),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Date,
    ),
    @series.Series::from_scalars(
      "seen_micros",
      [
        @types.Scalar::Timestamp(1715933350123456L),
        @types.Scalar::Null,
        @types.Scalar::Timestamp(253402300799999999L),
      ],
      dtype=@types.DataType::Timestamp,
    ),
    @series.Series::from_scalars(
      "amount",
      [decimal("-12345.6789"), decimal("0.0001"), decimal("99999999.9999")],
      dtype=@types.DataType::Decimal,
    ),
  ]
}

///|
test "the writer's files of the reference table land where the reference can read them" {
  // One file per codec under `_build/avro_written`, holding the cells the
  // reference implementation wrote into its own. The fixture generator's
  // `verify` mode opens them with that implementation and compares — the
  // cross-check of the writer, run by hand after a change to it.
  let columns = reference_frame()
  if !@fs.path_exists("_build/avro_written") {
    @fs.create_dir("_build/avro_written")
  }
  for codec in [Codec::Null, Codec::Deflate, Codec::Snappy, Codec::Zstd] {
    let bytes = write_avro_bytes(columns, names_of(columns), codec)
    let name = match codec {
      Null => "null"
      Deflate => "deflate"
      Snappy => "snappy"
      Zstd => "zstandard"
    }
    @fs.write_bytes_to_file("_build/avro_written/\{name}.avro", bytes)
    // And the same table reads back through the reader.
    let (frame, records) = read_avro_frame(bytes, None)
    assert_eq(records, 3)
    for pair in frame {
      let wanted = columns.filter(c => c.name() == pair.0)[0]
      assert_eq(pair.1.to_scalars(), wanted.to_scalars())
    }
  }
}

///|
test "the same frame writes the same file" {
  let columns = written_frame()
  assert_eq(
    write_avro_bytes(columns, names_of(columns), Codec::Deflate),
    write_avro_bytes(columns, names_of(columns), Codec::Deflate),
  )
}

///|
test "a frame past one block's rows reads back whole" {
  let rows : Array[@types.Scalar] = []
  for i in 0..<10001 {
    rows.push(@types.Scalar::Int(i.to_int64()))
  }
  let long = [
    @series.Series::from_scalars("v", rows, dtype=@types.DataType::Int),
  ]
  let (frame, records) = read_avro_frame(
    write_avro_bytes(long, ["v"], Codec::Null),
    None,
  )
  assert_eq(records, 10001)
  assert_eq(column(frame, "v")[10000], @types.Scalar::Int(10000L))
}

///|
test "a frame with no row writes no block, and reads back its columns" {
  let none : Array[@series.Series] = []
  let (frame, records) = read_avro_frame(
    write_avro_bytes(none, [], Codec::Null),
    None,
  )
  assert_eq(records, 0)
  assert_eq(frame.length(), 0)
  // Columns with no row keep their dtypes.
  let columns = [
    @series.Series::from_scalars("v", [], dtype=@types.DataType::Int),
    @series.Series::from_scalars("s", [], dtype=@types.DataType::String),
  ]
  let (empty, rows) = read_avro_frame(
    write_avro_bytes(columns, ["v", "s"], Codec::Zstd),
    None,
  )
  assert_eq(rows, 0)
  assert_eq(empty.map(pair => pair.0), ["v", "s"])
  assert_eq(dtype_of(empty, "v"), @types.DataType::Int)
  // Rows with no column: the height rides the file's blocks.
  let (no_columns, seven) = read_avro_frame(
    write_avro_bytes(none, [], Codec::Null, height=7),
    None,
  )
  assert_eq(seven, 7)
  assert_eq(no_columns.length(), 0)
}

///|
/// The refusal a write raised, failing the test when it wrote.
fn refused_write(
  columns : Array[@series.Series],
  names : Array[String],
) -> @types.DataError raise {
  let written : Result[Bytes, @types.DataError] = Ok(
    write_avro_bytes(columns, names, Codec::Null),
  ) catch {
    e => Err(e)
  }
  match written {
    Ok(_) => fail("the write was expected to refuse")
    Err(e) => e
  }
}

///|
/// One `Int` column named `name`, of one row.
fn one(name : String) -> Array[@series.Series] raise {
  [
    @series.Series::from_scalars(
      name,
      [@types.Scalar::Int(1L)],
      dtype=@types.DataType::Int,
    ),
  ]
}

///|
test "the writer refuses what it cannot name or carry" {
  // Names that disagree with the columns'.
  assert_eq(
    refused_write(one("a"), ["b"]),
    @types.DataError::InvalidOperation(
      "the Avro writer's name 0 (b) disagrees with its column's own (a)",
    ),
  )
  assert_eq(
    refused_write(one("a"), ["a", "c"]),
    @types.DataError::InvalidOperation(
      "the Avro writer was handed 2 names for 1 columns",
    ),
  )
  // A name the schema does not allow.
  for bad in ["gdp/cap", "2020", "a b", "x-1"] {
    assert_eq(
      refused_write(one(bad), [bad]),
      @types.DataError::InvalidOperation(
        "column \"\{bad}\": the name \"\{bad}\" is not one an Avro schema allows (letters, digits and _, starting with a letter or _)",
      ),
    )
  }
  // A column of a dtype the schema has no type for.
  let span = @series.Series::from_scalars(
    "span",
    [@types.Scalar::Duration(5L)],
    dtype=@types.DataType::Duration,
  )
  assert_eq(
    refused_write([span], ["span"]),
    @types.DataError::Unsupported(
      "Avro: a column \"span\" of dtype Duration: the schema's logical types name no span",
    ),
  )
  // Columns of different lengths.
  let two = @series.Series::from_scalars(
    "b",
    [@types.Scalar::Int(1L), @types.Scalar::Int(2L)],
    dtype=@types.DataType::Int,
  )
  assert_eq(
    refused_write(one("a") + [two], ["a", "b"]),
    @types.DataError::LengthMismatch(1, 2),
  )
  // A field of a struct column whose name the schema does not allow.
  let bad_struct = @series.Series::from_scalars(
    "r",
    [
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          @types.FieldValue::FieldValue("not a name", @types.Scalar::Int(1L)),
        ]),
      ),
    ],
    dtype=@types.DataType::Struct(
      @types.Schema::Schema([
        @types.Field::Field("not a name", @types.DataType::Int),
      ]),
    ),
  )
  assert_eq(
    refused_write([bad_struct], ["r"]),
    @types.DataError::InvalidOperation(
      "column \"r.not a name\": the name \"not a name\" is not one an Avro schema allows (letters, digits and _, starting with a letter or _)",
    ),
  )
}

///|
test "the writer refuses the cells the format cannot hold" {
  // A decimal column whose integer digits and scale together pass the 38
  // an Avro decimal carries.
  let wide = @series.Series::from_scalars(
    "m",
    [decimal("10000"), decimal("1e-34")],
    dtype=@types.DataType::Decimal,
  )
  assert_eq(
    refused_write([wide], ["m"]),
    @types.DataError::InvalidOperation(
      "column \"m\" holds a decimal needing 39 digits, past the 38 an Avro decimal carries",
    ),
  )
  // A date past the int it rides.
  let far = @series.Series::from_scalars(
    "d",
    [@types.Scalar::Date(3000000000L)],
    dtype=@types.DataType::Date,
  )
  assert_eq(
    refused_write([far], ["d"]),
    @types.DataError::InvalidOperation(
      "column \"d\" holds a day count 3000000000, outside the int a date rides",
    ),
  )
  // A string holding a lone surrogate.
  let b = StringBuilder()
  b.write_char(Int32::unsafe_to_char(0xD800))
  let lone = @series.Series::from_scalars(
    "s",
    [@types.Scalar::String(b.to_string())],
    dtype=@types.DataType::String,
  )
  assert_eq(
    refused_write([lone], ["s"]),
    @types.DataError::InvalidOperation(
      "cannot write an Avro string cell containing an unpaired UTF-16 surrogate: the UTF-8 encoding would not round-trip",
    ),
  )
}

///|
/// A deterministic 64-bit generator: xorshift64*.
struct Random {
  mut state : UInt64
}

///|
fn Random::next(self : Random) -> UInt64 {
  self.state = self.state ^ (self.state << 13)
  self.state = self.state ^ (self.state >> 7)
  self.state = self.state ^ (self.state << 17)
  self.state * 0x2545F4914F6CDD1DUL
}

///|
/// The valid bytes with one byte XORed.
fn corrupted(bytes : Bytes, at : Int32, flip : Byte) -> Bytes {
  let out = bytes.to_array()
  out[at] = out[at] ^ flip
  Bytes::from_array(out)
}

///|
test "every truncation of the reference files reads as a prefix or refuses" {
  // A file carries no record count, and its blocks are framed one by one:
  // a cut that lands on a block's end — the header's own end included —
  // leaves a shorter file that is whole, and every other cut refuses. So
  // a truncated file never reads as every record of the whole one.
  let files : ReadOnlyArray[(String, Array[String]?)] = [
    ("fastavro_types_null.avro", None),
    ("fastavro_types_deflate.avro", None),
    ("fastavro_types_snappy.avro", None),
    ("fastavro_types_zstandard.avro", None),
    ("fastavro_logical.avro", None),
    ("fastavro_refused_bytes.avro", Some(["kept"])),
    ("fastavro_refused_map.avro", Some(["kept"])),
    ("fastavro_refused_union.avro", Some(["kept"])),
    ("fastavro_refused_duration.avro", Some(["kept"])),
    ("fastavro_refused_nanos.avro", Some(["kept"])),
    ("fastavro_refused_record_no_fields.avro", Some(["kept"])),
  ]
  for (file, projection) in files {
    let whole = fixture(file)
    let total = records_in(whole, projection)
    let mut shorter = 0
    for length in 0..<whole.length() {
      let cut = whole.exact_view(end=length).to_owned()
      if !refuses(cut, projection) {
        let kept = records_in(cut, projection)
        if kept >= total {
          fail("\{file} cut at \{length} bytes read as \{kept} records")
        }
        shorter = shorter + 1
      }
    }
    // The header on its own is a whole file of no record.
    assert_true(shorter > 0)
  }
}

///|
test "corruption and garbage read or refuse, and never abort" {
  let valid = fixture("fastavro_types_null.avro")
  // Seeded corruption: a copy reads as some file or refuses, and most
  // refuse — a flipped byte lands in a count, a length or the schema.
  let random = Random::{ state: 0x9E3779B97F4A7C15UL, }
  let mut flipped_refused = 0
  for _ in 0..<200 {
    let at = (random.next() % valid.length().to_uint64()).reinterpret_as_int64()
    let copy = corrupted(
      valid,
      at.to_int(),
      (random.next() % 255UL + 1UL).to_byte(),
    )
    if refuses(copy, None) {
      flipped_refused = flipped_refused + 1
    }
  }
  assert_true(flipped_refused > 100)
  // Random bytes are never a file.
  let mut junk_refused = 0
  for _ in 0..<200 {
    let length = (random.next() % 600UL).reinterpret_as_int64()
    let junk : Array[Byte] = []
    for _ in 0L..<length {
      junk.push((random.next() & 0xFFUL).to_byte())
    }
    if refuses(Bytes::from_array(junk), None) {
      junk_refused = junk_refused + 1
    }
  }
  assert_eq(junk_refused, 200)
  // Nothing at all.
  assert_eq(
    refused(b"", None),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "malformed Avro: bytes that do not open with the Avro magic",
      ),
    ),
  )
}
