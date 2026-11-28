// Blackbox tests for the fixed-width interchange at the io layer — the
// inferred and the named layouts, the header's rules, the lines a read
// skips, the column typing, the refusals a caller meets, and the options'
// copies. Each table is spelled inline: the inference itself is the codec's
// to pin, over its own corpus.

///|
/// The classic table: three columns of one space-delimited field each.
fn fwf_classic() -> String {
  "A        B        C\n1        2        3\n4        5        6\n"
}

///|
/// The error a call raises; a frame answered instead fails the test.
fn fwf_raised(
  read : () -> @frame.DataFrame raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(ignore(read())) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the text read as a frame")
    Err(e) => e
  }
}

///|
test "an inferred layout reads each line as a row and the first as the header" {
  let df = @io.parse_fwf(fwf_classic())
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.columns(), ["A", "B", "C"])
  assert_eq(df.get_column("A").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("A").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(4),
  ])
  assert_eq(df.get_column("C").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(6),
  ])
  // The options built by default are the options applied by default.
  assert_eq(
    @io.parse_fwf(fwf_classic(), options=FwfReadOptions::FwfReadOptions()),
    df,
  )
}

///|
test "a header wider than its cells and cells of ragged widths read by the widest" {
  let df = @io.parse_fwf("column1    column2\na          1.5\nlong name  2\n")
  assert_eq(df.columns(), ["column1", "column2"])
  assert_eq(df.get_column("column1").dtype(), @types.DataType::String)
  assert_eq(df.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("long name"),
  ])
  // A fraction in one cell makes the whole column a float, as in CSV.
  assert_eq(df.get_column("column2").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(2.0),
  ])
}

///|
test "leading indentation names no field, and the whitespace around a cell is not its text" {
  let df = @io.parse_fwf("    id   name\n    1    Ann\n    2    Bo\n")
  assert_eq(df.columns(), ["id", "name"])
  assert_eq(df.get_column("id").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(df.get_column("name").to_scalars(), [
    @types.Scalar::String("Ann"),
    @types.Scalar::String("Bo"),
  ])
}

///|
test "a blank line is skipped, and an empty cell is null" {
  let df = @io.parse_fwf("x  y  z\n\n1  2  3\n   \n4     6\n")
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.get_column("x").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(4),
  ])
  assert_eq(df.get_column("y").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Null,
  ])
}

///|
test "a Windows terminator and a byte-order mark are not part of the cells" {
  let df = @io.parse_fwf("\u{FEFF}a  b\r\n1  2\r\n")
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.get_column("b").to_scalars(), [@types.Scalar::Int(2)])
  // A last line with no terminator after it is a line.
  let last = @io.parse_fwf("a  b\n1  2")
  assert_eq(last.shape(), (1, 2))
}

///|
test "a non-ASCII header and cells are counted in characters, not in bytes or units" {
  let df = @io.parse_fwf(
    "名前      年齢\nたなか    30\nすずき    41\n",
  )
  assert_eq(df.columns(), ["名前", "年齢"])
  assert_eq(df.get_column("名前").to_scalars(), [
    @types.Scalar::String("たなか"),
    @types.Scalar::String("すずき"),
  ])
  assert_eq(df.get_column("年齢").to_scalars(), [
    @types.Scalar::Int(30),
    @types.Scalar::Int(41),
  ])
}

///|
test "each column takes the narrowest dtype holding it, by the CSV reader's rule" {
  let df = @io.parse_fwf(
    "i        f        b        s           d\n1        1.5      true     2020-01-01  a\n2        -2.25     false    2020-02-01  b\n",
  )
  assert_eq(df.columns(), ["i", "f", "b", "s", "d"])
  assert_eq(df.column_series().map(column => column.dtype()), [
    @types.DataType::Int,
    @types.DataType::Float,
    @types.DataType::Bool,
    @types.DataType::String,
    @types.DataType::String,
  ])
  assert_eq(df.get_column("b").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
}

///|
test "widths name the fields end to end, and without a header every line is data" {
  let df = @io.parse_fwf(
    fwf_classic(),
    options=FwfReadOptions::FwfReadOptions(widths=[1, 10, 10], has_header=false),
  )
  assert_eq(df.shape(), (3, 3))
  assert_eq(df.columns(), ["column1", "column2", "column3"])
  assert_eq(df.get_column("column1").to_scalars(), [
    @types.Scalar::String("A"),
    @types.Scalar::String("1"),
    @types.Scalar::String("4"),
  ])
}

///|
test "colspecs name the fields by position, and a field a line does not reach is null" {
  let df = @io.parse_fwf(
    fwf_classic(),
    options=FwfReadOptions::FwfReadOptions(colspecs=[(0, 1), (9, 10), (18, 19)]),
  )
  assert_eq(df.columns(), ["A", "B", "C"])
  assert_eq(df.get_column("B").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(5),
  ])
  let short = @io.parse_fwf(
    "a   b\n1\n",
    options=FwfReadOptions::FwfReadOptions(colspecs=[(0, 1), (4, 5)]),
  )
  assert_eq(short.shape(), (1, 2))
  assert_eq(short.get_column("b").to_scalars(), [@types.Scalar::Null])
}

///|
test "names name the columns in place of the header's" {
  let df = @io.parse_fwf(
    fwf_classic(),
    options=FwfReadOptions::FwfReadOptions(names=["p", "q", "r"]),
  )
  assert_eq(df.columns(), ["p", "q", "r"])
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.get_column("r").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(6),
  ])
}

///|
test "skiprows passes over the head of the file before the header and the inference" {
  let df = @io.parse_fwf(
    fwf_classic(),
    options=FwfReadOptions::FwfReadOptions(skiprows=1),
  )
  assert_eq(df.columns(), ["1", "2", "3"])
  assert_eq(df.shape(), (1, 3))
  assert_eq(df.get_column("2").to_scalars(), [@types.Scalar::Int(5)])
}

///|
test "a text with nothing to read answers the 0x0 frame" {
  let empty = @io.parse_fwf("")
  assert_eq(empty.shape(), (0, 0))
  let blanks = @io.parse_fwf("\n   \n\t\n")
  assert_eq(blanks.shape(), (0, 0))
  // A header alone names its columns over no row.
  let header = @io.parse_fwf("a  b\n")
  assert_eq(header.shape(), (0, 2))
  assert_eq(header.columns(), ["a", "b"])
  // So does a named layout over a text with no line.
  let named = @io.parse_fwf(
    "",
    options=FwfReadOptions::FwfReadOptions(widths=[2, 2]),
  )
  assert_eq(named.shape(), (0, 0))
}

///|
test "read_fwf reads a file, a gzip one included" {
  let path = "_build/io_fwf_classic.txt"
  @io.write_text(path, fwf_classic())
  let df = @io.read_fwf(path)
  assert_eq(df.shape(), (2, 3))
  assert_eq(df.columns(), ["A", "B", "C"])
  let gz = "_build/io_fwf_classic.txt.gz"
  @io.write_text(gz, fwf_classic())
  assert_eq(@io.read_fwf(gz).get_column("A").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(4),
  ])
  let skipped = @io.read_fwf(
    path,
    options=FwfReadOptions::FwfReadOptions(skiprows=2),
  )
  assert_eq(skipped.shape(), (0, 3))
  assert_eq(skipped.columns(), ["4", "5", "6"])
}

///|
test "the fixed-width entries raise the errors a caller meets" {
  // A path that cannot be read is the read's IoError.
  let missing = fwf_raised(() => @io.read_fwf("_build/no_such_fwf.txt"))
  assert_true(missing is @types.DataError::IoError(_))
  // Two layouts named at once.
  assert_eq(
    fwf_raised(() => {
      @io.parse_fwf(
        fwf_classic(),
        options=FwfReadOptions::FwfReadOptions(widths=[1], colspecs=[(0, 1)]),
      )
    }),
    @types.DataError::InvalidOperation(
      "fwf: widths and colspecs both name a layout; name one",
    ),
  )
  // A negative width, and positions that start before the line.
  assert_eq(
    fwf_raised(() => {
      @io.parse_fwf(
        fwf_classic(),
        options=FwfReadOptions::FwfReadOptions(widths=[-1]),
      )
    }),
    @types.DataError::InvalidOperation(
      "fwf: the width of field 1 is -1, below zero",
    ),
  )
  assert_eq(
    fwf_raised(() => {
      @io.parse_fwf(
        fwf_classic(),
        options=FwfReadOptions::FwfReadOptions(colspecs=[(-1, 1)]),
      )
    }),
    @types.DataError::InvalidOperation(
      "fwf: field 1 starts at -1, before the line's first character",
    ),
  )
  // A header naming one column twice.
  assert_eq(
    fwf_raised(() => @io.parse_fwf("a  a\n1  2\n")),
    @types.DataError::DuplicateColumn("a"),
  )
}

///|
test "FwfReadOptions answers its arrays as copies" {
  let widths = [1, 2]
  let colspecs = [(0, 1)]
  let names = ["p"]
  let options = FwfReadOptions::FwfReadOptions(
    widths~,
    colspecs~,
    names~,
    infer_nrows=7,
    has_header=false,
    skiprows=3,
  )
  widths[0] = 9
  widths.push(5)
  colspecs[0] = (5, 6)
  names.clear()
  assert_eq(options.widths(), [1, 2])
  assert_eq(options.colspecs(), [(0, 1)])
  assert_eq(options.names(), ["p"])
  // The accessors answer copies: a mutation of one does not reach the options.
  options.widths()[1] = 8
  assert_eq(options.widths(), [1, 2])
  let defaults = FwfReadOptions::FwfReadOptions()
  assert_eq(defaults.widths(), [])
  assert_eq(defaults.colspecs(), [])
  assert_eq(defaults.names(), [])
}
