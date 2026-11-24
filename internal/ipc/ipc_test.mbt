// Blackbox tests of the Arrow IPC codec through the surface the io layer
// rides: the sink's batching and its refusals, a reader's place in a
// payload, and the malformed-input corpus — every truncation and every
// single-byte corruption of a payload reads or refuses, and never aborts.

///|
/// A one-code-unit string holding an isolated UTF-16 surrogate half: a
/// literal cannot spell it, so the code unit is assembled directly.
fn lone_surrogate(code_unit : Int32) -> String {
  let b = StringBuilder()
  b.write_char(Int32::unsafe_to_char(code_unit))
  b.to_string()
}

///|
fn ints(
  name : String,
  cells : Array[Int64],
) -> @series.Series raise @types.DataError {
  @series.Series::from_scalars(
    name,
    cells.map(i => @types.Scalar::Int(i)),
    dtype=@types.DataType::Int,
  )
}

///|
fn lv(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn decimals(
  name : String,
  cells : Array[String],
) -> @series.Series raise @types.DataError {
  @series.Series::from_scalars(
    name,
    cells.map(text => {
      @types.Scalar::Decimal(@types.Dec128::parse_opt(text).unwrap())
    }),
    dtype=@types.DataType::Decimal,
  )
}

///|
/// Run a write that must refuse, and check that it refuses with the
/// `InvalidOperation` expected.
fn assert_refusal(
  expected : String,
  run : () -> Unit raise @types.DataError,
) -> Unit raise {
  let outcome : Result[Unit, @types.DataError] = Ok(run()) catch { e => Err(e) }
  match outcome {
    Ok(_) => fail("the write was expected to refuse: \{expected}")
    Err(InvalidOperation(message)) => assert_eq(message, expected)
    Err(e) =>
      fail("the write was expected to refuse with InvalidOperation, got \{e}")
  }
}

///|
/// A frame of every kind the writer lays out: a fixed-width integer, a
/// float, a string, and a list — with nulls in each.
fn kinds() -> Array[@series.Series] raise @types.DataError {
  let lists = @types.DataType::List(@types.DataType::Int)
  [
    ints("i", [1L, -3L]),
    @series.Series::from_scalars(
      "f",
      [@types.Scalar::Float(1.5), @types.Scalar::Null],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "s",
      [@types.Scalar::String("héllo"), @types.Scalar::Null],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "l",
      [lv([@types.Scalar::Int(7), @types.Scalar::Null]), lv([])],
      dtype=lists,
    ),
  ]
}

///|
test "a sink writes one record batch per push, and a reader hands them back in order" {
  for file in [true, false] {
    let sink = @ipc.IpcSink::sink(None, file~)
    sink.push([ints("a", [1, 2])])
    sink.push([ints("a", [])])
    sink.push([ints("a", [3, 4, 5])])
    let reader = @ipc.open_ipc(sink.finish(), None)
    assert_eq(reader.batch_count(), 3)
    assert_eq(reader.batch_rows(0), 2)
    assert_eq(reader.batch_rows(1), 0)
    assert_eq(reader.batch_rows(2), 3)
    assert_eq(reader.batch_rows(3), 0)
    assert_eq(reader.total_rows(), 5L)
    assert_eq(reader.take_batch()[0].to_scalars().copy(), [
      @types.Scalar::Int(1),
      @types.Scalar::Int(2),
    ])
    assert_eq(reader.take_batch()[0].len(), 0)
    assert_eq(reader.take_batch()[0].to_scalars().copy(), [
      @types.Scalar::Int(3),
      @types.Scalar::Int(4),
      @types.Scalar::Int(5),
    ])
    // Past the last batch the reader refuses; it has no batch to give.
    let past = Ok(ignore(reader.take_batch())) catch { e => Err(e) }
    assert_true(
      past
      is Err(
        @types.DataError::InvalidOperation(
          "Arrow IPC: no record batch is left to read",
        ),
      ),
    )
  }
}

///|
test "a skipped batch is stepped over without being decoded" {
  let sink = @ipc.IpcSink::sink(None, file=false)
  sink.push([ints("a", [1])])
  sink.push([ints("a", [2])])
  sink.push([ints("a", [3])])
  let reader = @ipc.open_ipc(sink.finish(), None)
  reader.skip_batch()
  reader.skip_batch()
  assert_eq(reader.take_batch()[0].to_scalars().copy(), [@types.Scalar::Int(3)])
}

///|
test "a reader's empty columns carry the chosen columns' names and dtypes" {
  let columns = kinds()
  let bytes = @ipc.write_ipc_bytes(columns, None, file=false)
  let every = @ipc.open_ipc(bytes, None)
  let empty = every.empty_columns()
  assert_eq(empty.map(column => column.name()), ["i", "f", "s", "l"])
  assert_eq(empty.map(column => column.len()), [0, 0, 0, 0])
  assert_eq(empty[3].dtype(), @types.DataType::List(@types.DataType::Int))
  // A projection leaves the other columns out of the empty ones too.
  let some = @ipc.open_ipc(bytes, Some(["l", "none"]))
  assert_eq(some.empty_columns().map(column => column.name()), ["l"])
  assert_eq(some.total_rows(), 2L)
}

///|
test "a sink's first batch decides the schema, and a later batch must agree with it" {
  let count = @ipc.IpcSink::sink(None, file=false)
  count.push([ints("a", [1]), ints("b", [2])])
  count.push([ints("a", [3]), ints("b", [4])])
  assert_refusal(
    "cannot write Arrow IPC: a later batch carries 1 columns where the first carried 2",
    fn() -> Unit raise @types.DataError { count.push([ints("a", [3])]) },
  )
  let name = @ipc.IpcSink::sink(None, file=false)
  name.push([ints("a", [1])])
  assert_refusal(
    "cannot write Arrow IPC: a later batch names its column 1 \"b\" where the first batch named it \"a\"",
    fn() -> Unit raise @types.DataError { name.push([ints("b", [2])]) },
  )
  let dtype = @ipc.IpcSink::sink(None, file=false)
  dtype.push([ints("a", [1])])
  assert_refusal(
    "cannot write Arrow IPC: a later batch carries column \"a\" as Float where the first batch carried it as Int",
    fn() -> Unit raise @types.DataError {
      dtype.push([
        @series.Series::from_scalars(
          "a",
          [@types.Scalar::Float(2.0)],
          dtype=@types.DataType::Float,
        ),
      ])
    },
  )
  // None of the refused pushes landed: each payload reads only the
  // batches pushed before its refusal.
  assert_eq(@ipc.open_ipc(count.finish(), None).batch_count(), 2)
  assert_eq(@ipc.open_ipc(name.finish(), None).batch_count(), 1)
  assert_eq(@ipc.open_ipc(dtype.finish(), None).batch_count(), 1)
}

///|
test "a decimal column's window is the first batch's, and a later batch's cells must sit inside it" {
  let sink = @ipc.IpcSink::sink(None, file=false)
  sink.push([decimals("d", ["1.50", "2.25"])])
  // A cell counting one more fraction digit, and one lifting a digit
  // higher, each leave the precision-3 window the first batch decided at
  // scale 2.
  assert_refusal(
    "cannot write Arrow IPC: column \"d\": a later batch's decimal cells need a 4-digit window at scale 3, outside the precision-3 window the first batch decided at scale 2",
    fn() -> Unit raise @types.DataError {
      sink.push([decimals("d", ["0.001"])])
    },
  )
  assert_refusal(
    "cannot write Arrow IPC: column \"d\": a later batch's decimal cells need a 6-digit window at scale 2, outside the precision-3 window the first batch decided at scale 2",
    fn() -> Unit raise @types.DataError {
      sink.push([decimals("d", ["1234.50"])])
    },
  )
  // A cell inside the window is written, lifted to the column's scale.
  sink.push([decimals("d", ["7", "-0.25"])])
  let (columns, _) = @ipc.read_ipc_frame(sink.finish(), None)
  assert_eq(columns[0].1.to_scalars().copy(), [
    @types.Scalar::Decimal(@types.Dec128::parse_opt("1.50").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("2.25").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("7.00").unwrap()),
    @types.Scalar::Decimal(@types.Dec128::parse_opt("-0.25").unwrap()),
  ])
}

///|
test "a decimal cell with no fixed-point spelling refuses the write" {
  let nan = @series.Series::from_scalars(
    "d",
    [@types.Scalar::Decimal(@types.Dec128::nan())],
    dtype=@types.DataType::Decimal,
  )
  assert_refusal(
    "cannot write Arrow IPC: column \"d\": a NaN or infinite decimal cell, which has no fixed-point interchange spelling",
    fn() -> Unit raise @types.DataError {
      ignore(@ipc.write_ipc_bytes([nan], None, file=false))
    },
  )
  // The widest a column may lift to is 38 digits; an exponent past it
  // has no window.
  let wide = decimals("d", ["1E+38"])
  assert_refusal(
    "cannot write Arrow IPC: column \"d\": its cells leave the decimal interchange's 38-digit window",
    fn() -> Unit raise @types.DataError {
      ignore(@ipc.write_ipc_bytes([wide], None, file=false))
    },
  )
}

///|
test "text with an unpaired surrogate refuses the write: a column name, a struct field name, a cell" {
  let column = @ipc.IpcSink::sink(None, file=false)
  assert_refusal(
    "cannot write Arrow IPC: a column name containing an unpaired UTF-16 surrogate, whose UTF-8 spelling would not round-trip",
    fn() -> Unit raise @types.DataError {
      column.push([ints(lone_surrogate(0xD800), [1])])
    },
  )
  let field = lone_surrogate(0xDC00)
  let record = @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field(field, @types.DataType::Int)]),
  )
  let structs = @series.Series::from_scalars(
    "s",
    [
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          @types.FieldValue::FieldValue(field, @types.Scalar::Int(1)),
        ]),
      ),
    ],
    dtype=record,
  )
  assert_refusal(
    "cannot write Arrow IPC: a struct field name of column \"s\" containing an unpaired UTF-16 surrogate, whose UTF-8 spelling would not round-trip",
    fn() -> Unit raise @types.DataError {
      ignore(@ipc.write_ipc_bytes([structs], None, file=false))
    },
  )
  let cell = @series.Series::from_scalars(
    "t",
    [@types.Scalar::String(lone_surrogate(0xD800))],
    dtype=@types.DataType::String,
  )
  assert_refusal(
    "cannot write Arrow IPC: a string cell of column \"t\" containing an unpaired UTF-16 surrogate, whose UTF-8 spelling would not round-trip",
    fn() -> Unit raise @types.DataError {
      ignore(@ipc.write_ipc_bytes([cell], None, file=false))
    },
  )
}

///|
test "a sink nothing was pushed to finishes a payload of an empty schema" {
  for file in [true, false] {
    let bytes = @ipc.IpcSink::sink(None, file~).finish()
    let reader = @ipc.open_ipc(bytes, None)
    assert_eq(reader.batch_count(), 0)
    assert_eq(reader.total_rows(), 0L)
    assert_eq(reader.empty_columns().length(), 0)
    let (columns, rows) = @ipc.read_ipc_frame(bytes, None)
    assert_eq(columns.length(), 0)
    assert_eq(rows, 0L)
  }
}

// ── the malformed-input corpus ────────────────────────────────────────

///|
/// Read a payload whole, every column and a projection. Every way it can
/// refuse is the reader's own to raise; an abort here fails the test.
fn read_whole(bytes : Bytes) -> Unit {
  for projection in [None, Some(["s", "l", "f3"])] {
    let outcome : Result[_, @types.DataError] = Ok(
      @ipc.read_ipc_frame(bytes, projection),
    ) catch {
      e => Err(e)
    }
    ignore(outcome)
  }
}

///|
/// The payloads the corpus is run over: every codec, both framings.
fn corpus() -> Array[Bytes] raise @types.DataError {
  let columns = kinds()
  [
    @ipc.write_ipc_bytes(columns, None, file=false),
    @ipc.write_ipc_bytes(columns, None, file=true),
    @ipc.write_ipc_bytes(columns, Some(Lz4Frame), file=false),
    @ipc.write_ipc_bytes(columns, Some(Zstd), file=true),
  ]
}

///|
/// The official samples the corpus is run over: the framings and the
/// codecs, written by other writers than this one.
fn samples() -> Array[Bytes] {
  let out : Array[Bytes] = []
  for
    path in [
      ".github/fixtures/arrow-ipc/0.14.1/generated_nested.stream",
      // Not vendored in that directory: a sample the corpus skips.
       ".github/fixtures/arrow-ipc/0.14.1/generated_null_trivial.stream", ".github/fixtures/arrow-ipc/1.0.0-littleendian/generated_dictionary.arrow_file",
      ".github/fixtures/arrow-ipc/2.0.0-compression/generated_lz4.stream", ".github/fixtures/arrow-ipc/2.0.0-compression/generated_zstd.stream",
      ".github/fixtures/arrow-ipc/2.0.0-compression/generated_uncompressible_zstd.stream",
      ".github/fixtures/arrow-ipc/4.0.0-shareddict/generated_shared_dict.stream",
    ] {
    let read : Result[Bytes, @types.DataError] = Ok(
      @fs.read_file_to_bytes(path),
    ) catch {
      @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
    }
    match read {
      Ok(bytes) => out.push(bytes)
      Err(_) => ()
    }
  }
  out
}

///|
test "every truncation of a payload reads or refuses, and never aborts" {
  for bytes in corpus() {
    for length in 0..<=bytes.length() {
      read_whole(bytes[:length].to_owned())
    }
  }
  for bytes in samples() {
    for length in 0..<=bytes.length() {
      read_whole(bytes[:length].to_owned())
    }
  }
}

///|
test "every single-byte corruption of a payload reads or refuses, and never aborts" {
  // A byte flipped in each of the bits a length, an offset, or a tag can
  // be read by.
  let masks : Array[Int32] = [0xFF, 0x01, 0x7F, 0x80, 0x10, 0x55]
  for bytes in corpus() {
    for at in 0..<bytes.length() {
      for mask in masks {
        read_whole(
          Bytes::makei(bytes.length(), i => {
            if i == at {
              (bytes[i].to_int() ^ mask).to_byte()
            } else {
              bytes[i]
            }
          }),
        )
      }
    }
  }
  for bytes in samples() {
    for at in 0..<bytes.length() {
      for mask in masks {
        read_whole(
          Bytes::makei(bytes.length(), i => {
            if i == at {
              (bytes[i].to_int() ^ mask).to_byte()
            } else {
              bytes[i]
            }
          }),
        )
      }
    }
  }
}

///|
/// A payload whose buffers compress — two thousand rows of a few repeating
/// texts over a ramp of integers — under each codec: the frames the codecs
/// meet here are frames, not the bytes stored as they are.
fn compressible_corpus() -> Array[Bytes] raise @types.DataError {
  let columns = compressible_columns()
  [
    @ipc.write_ipc_bytes(columns, Some(Lz4Frame), file=false),
    @ipc.write_ipc_bytes(columns, Some(Zstd), file=true),
  ]
}

///|
fn compressible_columns() -> Array[@series.Series] raise @types.DataError {
  let names : ReadOnlyArray[String] = ["alpha", "bravo", "charlie", "delta"]
  let texts : Array[String] = []
  let ramp : Array[Int64] = []
  for i in 0..<2000 {
    texts.push(names[i % names.length()])
    ramp.push(i.to_int64() / 7L)
  }
  [@series.Series::from_strings("s", texts), ints("i", ramp)]
}

///|
test "a compressed payload under heavier corruption reads or refuses, and never aborts" {
  // Several bytes overwritten at once, over a deterministic walk: the
  // codecs behind the buffers meet frames no writer produces — a header
  // disagreeing with its body, a block cut short, a checksum off.
  let plain = @ipc.write_ipc_bytes(compressible_columns(), None, file=false)
  let mut state = 0x2545F491U
  for bytes in compressible_corpus() {
    // The buffers really are frames: the payload is the shorter for them.
    assert_true(bytes.length() * 4 < plain.length() * 3)
    for length in 0..<bytes.length() {
      read_whole(bytes[:length].to_owned())
    }
    for _ in 0..<3000 {
      let mutated : Array[Byte] = []
      for byte in bytes.iter() {
        mutated.push(byte)
      }
      state = state * 1664525U + 1013904223U
      let flips = 1 + (state >> 28).reinterpret_as_int()
      for _ in 0..<flips {
        state = state * 1664525U + 1013904223U
        let at = (state & 0x7FFFFFFFU).reinterpret_as_int() % bytes.length()
        mutated[at] = ((state >> 8) & 0xFFU).reinterpret_as_int().to_byte()
      }
      read_whole(Bytes::from_array(mutated))
    }
  }
}
