// Blackbox tests for the Excel entries: the reader against workbooks
// other writers made (openpyxl, and LibreOffice for what openpyxl cannot
// spell — a formula's cached value), the writer against the reader, and
// the refusals of each. The fixtures are made by make_fixtures.py beside
// them; what each must read as is stated here.

///|
/// Where the vendored workbooks live, from the project root.
const EXCEL_FIXTURES : String = ".github/fixtures/excel"

///|
/// The instant an ISO spelling names, as the readers parse it.
fn xlsx_at(text : String) -> @types.Scalar {
  @types.Scalar::Timestamp(@types.parse_timestamp_micros_opt(text).unwrap())
}

///|
fn xlsx_scalars(
  name : String,
  cells : Array[@types.Scalar],
  dtype : @types.DataType,
) -> @series.Series raise @types.DataError {
  @series.Series::from_scalars(name, cells, dtype~)
}

///|
fn xlsx_strs(cells : Array[String]) -> Array[@types.Scalar] {
  cells.map(s => @types.Scalar::String(s))
}

///|
/// One column's cells.
fn xlsx_cells(
  frame : @frame.DataFrame,
  name : String,
) -> Array[@types.Scalar] raise @types.DataError {
  frame.get_column(name).to_scalars().copy()
}

///|
/// The error a read or a write that was expected to refuse raised; one
/// that goes through fails the test.
fn xlsx_refusal(
  run : () -> Unit raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[Unit, @types.DataError] = Ok(run()) catch { e => Err(e) }
  match outcome {
    Ok(_) => fail("the call was expected to refuse")
    Err(e) => e
  }
}

///|
/// A frame of every column shape a sheet holds, three rows with a null
/// in each — a string that spells a number and another that spells a
/// date among the text.
fn xlsx_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "i",
      [@types.Scalar::Int(1), @types.Scalar::Null, @types.Scalar::Int(-3)],
      @types.DataType::Int,
    ),
    xlsx_scalars(
      "f",
      [
        @types.Scalar::Float(1.5),
        @types.Scalar::Null,
        @types.Scalar::Float(-0.25),
      ],
      @types.DataType::Float,
    ),
    xlsx_scalars(
      "b",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Null,
      ],
      @types.DataType::Bool,
    ),
    xlsx_scalars(
      "s",
      [
        @types.Scalar::String("42"),
        @types.Scalar::String("2024-01-02"),
        @types.Scalar::Null,
      ],
      @types.DataType::String,
    ),
    xlsx_scalars(
      "d",
      [@types.Scalar::Date(19724), @types.Scalar::Null, @types.Scalar::Date(0)],
      @types.DataType::Date,
    ),
    xlsx_scalars(
      "t",
      [
        xlsx_at("2024-03-04T05:06:07.123456"),
        @types.Scalar::Null,
        xlsx_at("1969-12-31T23:59:59.999999"),
      ],
      @types.DataType::Timestamp,
    ),
  ])
}

// ── what another writer wrote ────────────────────────────────────────

///|
test "read_excel reads what another writer wrote" {
  let path = "\{EXCEL_FIXTURES}/openpyxl_types.xlsx"
  let got = @io.read_excel(path)
  assert_eq(got.shape(), (3, 9))
  assert_eq(got.columns(), [
    "name", "count", "ratio", "ok", "day", "at", "time", "err", "spare",
  ])
  // Text keeps its Unicode; a number is an integer when every value is
  // whole, and a float otherwise.
  assert_eq(got.get_column("name").dtype(), @types.DataType::String)
  assert_eq(xlsx_cells(got, "name"), xlsx_strs(["alpha", "北京", "gamma"]))
  assert_eq(got.get_column("count").dtype(), @types.DataType::Int)
  assert_eq(xlsx_cells(got, "count"), [
    @types.Scalar::Int(42),
    @types.Scalar::Null,
    @types.Scalar::Int(7),
  ])
  assert_eq(got.get_column("ratio").dtype(), @types.DataType::Float)
  assert_eq(xlsx_cells(got, "ratio"), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(-0.25),
    @types.Scalar::Float(3.0),
  ])
  assert_eq(got.get_column("ok").dtype(), @types.DataType::Bool)
  assert_eq(xlsx_cells(got, "ok"), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  // A date under a date format, an instant under a date-and-time format,
  // and a time of day on the epoch's day.
  assert_eq(got.get_column("day").dtype(), @types.DataType::Date)
  assert_eq(xlsx_cells(got, "day"), [
    @types.Scalar::Date(19724),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(got.get_column("at").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "at"), [
    xlsx_at("2024-03-04T05:06:07"),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(got.get_column("time").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "time"), [
    @types.Scalar::Timestamp(45_000_000_000L),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // A cell carrying an error holds no value: it reads null, and the
  // column is typed by the cells that do.
  assert_eq(got.get_column("err").dtype(), @types.DataType::Int)
  assert_eq(xlsx_cells(got, "err"), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Int(9),
  ])
  // A column of nothing but empty cells.
  assert_eq(got.get_column("spare").dtype(), @types.DataType::String)
  assert_eq(xlsx_cells(got, "spare"), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // The bytes in memory read the same as the file.
  assert_eq(@io.parse_excel(@fs.read_file_to_bytes(path)), got)
}

///|
test "a sheet is chosen by name, and the first one by default" {
  let path = "\{EXCEL_FIXTURES}/openpyxl_types.xlsx"
  assert_eq(@io.excel_sheets(path), ["Data", "Second"])
  assert_eq(@io.read_excel(path).shape(), (3, 9))
  let second = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(sheet="Second"),
  )
  assert_eq(second.shape(), (0, 1))
  assert_eq(second.columns(), ["only"])
  // A sheet the workbook does not carry refuses, naming the ones it does.
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(
        @io.read_excel(
          path,
          options=ExcelReadOptions::ExcelReadOptions(sheet="Third"),
        ),
      )
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("no sheet named \"Third\"; its sheets are \"Data\", \"Second\""),
  )
  // A sheet of no value at all is the empty frame.
  let bare = "_build/xlsx_bare.xlsx"
  @io.write_excel(@frame.DataFrame::DataFrame([]), bare)
  assert_eq(@io.read_excel(bare).shape(), (0, 0))
  assert_eq(@io.excel_sheets(bare), ["Sheet1"])
}

///|
test "without a header every row is data" {
  let path = "\{EXCEL_FIXTURES}/openpyxl_types.xlsx"
  let flat = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(has_header=false),
  )
  assert_eq(flat.shape(), (4, 9))
  assert_eq(flat.columns(), [
    "column1", "column2", "column3", "column4", "column5", "column6", "column7",
    "column8", "column9",
  ])
  // The header row's text widens every column it lands in.
  assert_eq(flat.get_column("column1").dtype(), @types.DataType::String)
  assert_eq(
    xlsx_cells(flat, "column1"),
    xlsx_strs(["name", "alpha", "北京", "gamma"]),
  )
  assert_eq(flat.get_column("column2").dtype(), @types.DataType::String)
  assert_eq(xlsx_cells(flat, "column2"), [
    @types.Scalar::String("count"),
    @types.Scalar::String("42"),
    @types.Scalar::Null,
    @types.Scalar::String("7"),
  ])
  // A column the header left empty keeps its cells' own typing.
  assert_eq(flat.get_column("column9").dtype(), @types.DataType::String)
  assert_eq(xlsx_cells(flat, "column9"), [
    @types.Scalar::String("spare"),
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
}

///|
test "both date systems are honoured" {
  let got = @io.read_excel("\{EXCEL_FIXTURES}/openpyxl_1904.xlsx")
  assert_eq(got.shape(), (2, 2))
  assert_eq(got.get_column("day").dtype(), @types.DataType::Date)
  // 1904-01-01 is the 1904 system's day 0.
  assert_eq(xlsx_cells(got, "day"), [
    @types.Scalar::Date(19724),
    @types.Scalar::Date(-24107),
  ])
  assert_eq(xlsx_cells(got, "at"), [
    xlsx_at("2024-03-04T05:06:07"),
    xlsx_at("1904-01-01T00:00:00"),
  ])
}

///|
test "a number is a date, a time, a span, or a number by its format" {
  let got = @io.read_excel("\{EXCEL_FIXTURES}/openpyxl_formats.xlsx")
  assert_eq(got.shape(), (1, 12))
  // A custom date in a Chinese spelling, with a time of day the format
  // does not show kept as the instant it names.
  assert_eq(got.get_column("cjk").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "cjk"), [xlsx_at("2024-07-03T12:00:00")])
  // Quoted words with the date letters in them format a plain number.
  assert_eq(got.get_column("quoted").dtype(), @types.DataType::Float)
  assert_eq(xlsx_cells(got, "quoted"), [@types.Scalar::Float(45476.5)])
  assert_eq(got.get_column("unit").dtype(), @types.DataType::Int)
  assert_eq(xlsx_cells(got, "unit"), [@types.Scalar::Int(7)])
  // A meridian's M is no month: the format shows a time of day.
  assert_eq(got.get_column("meridian").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "meridian"), [
    @types.Scalar::Timestamp(43_200_000_000L),
  ])
  // A bracketed time unit shows an elapsed time: the whole serial, as a
  // span from the epoch.
  assert_eq(got.get_column("elapsed").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "elapsed"), [
    @types.Scalar::Timestamp(108_000_000_000L),
  ])
  // A locale's builtin, a scientific format, and a percent: numbers.
  assert_eq(got.get_column("accounting").dtype(), @types.DataType::Float)
  assert_eq(xlsx_cells(got, "accounting"), [@types.Scalar::Float(1234.5)])
  assert_eq(xlsx_cells(got, "scientific"), [@types.Scalar::Float(1234.5)])
  assert_eq(got.get_column("percent").dtype(), @types.DataType::Float)
  assert_eq(xlsx_cells(got, "percent"), [@types.Scalar::Float(0.5)])
  // The writer's own date, time, and date-and-time formats, and the
  // builtin short date by its id.
  assert_eq(got.get_column("day").dtype(), @types.DataType::Date)
  assert_eq(xlsx_cells(got, "day"), [@types.Scalar::Date(19724)])
  assert_eq(got.get_column("time").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "time"), [@types.Scalar::Timestamp(45_296_000_000L)])
  assert_eq(got.get_column("instant").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(got, "instant"), [xlsx_at("2024-03-04T05:06:07")])
  assert_eq(got.get_column("builtin_day").dtype(), @types.DataType::Date)
  assert_eq(xlsx_cells(got, "builtin_day"), [@types.Scalar::Date(19907)])
}

///|
test "a formula reads its cached value, and is null without one" {
  // openpyxl writes a formula with no cached value.
  let uncached = @io.read_excel("\{EXCEL_FIXTURES}/openpyxl_formulas.xlsx")
  assert_eq(uncached.shape(), (1, 2))
  assert_eq(uncached.columns(), ["10", "2024-01-02"])
  assert_eq(xlsx_cells(uncached, "10"), [@types.Scalar::Int(20)])
  assert_eq(xlsx_cells(uncached, "2024-01-02"), [@types.Scalar::Bool(true)])
  // LibreOffice computed them: a number, a text, an error (null), and
  // the formula's number again — the first of them widening the column
  // to text.
  let cached = @io.read_excel("\{EXCEL_FIXTURES}/libreoffice_formulas.xlsx")
  assert_eq(cached.shape(), (5, 2))
  assert_eq(cached.get_column("10").dtype(), @types.DataType::String)
  assert_eq(xlsx_cells(cached, "10"), [
    @types.Scalar::String("20"),
    @types.Scalar::String("30"),
    @types.Scalar::String("10 units"),
    @types.Scalar::Null,
    @types.Scalar::String("30"),
  ])
  assert_eq(cached.get_column("2024-01-02").dtype(), @types.DataType::Bool)
  assert_eq(xlsx_cells(cached, "2024-01-02"), [
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
}

///|
test "a column mixing date-formatted and plain numbers refuses, unless dates are off" {
  let path = "\{EXCEL_FIXTURES}/openpyxl_formats.xlsx"
  let options = ExcelReadOptions::ExcelReadOptions(sheet="Mixed")
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.read_excel(path, options~))
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("column \"v\" holds date-formatted numbers beside plain ones"),
  )
  // With dates off every such number is the number it is stored as.
  let numbers = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(sheet="Mixed", dates=false),
  )
  assert_eq(numbers.shape(), (2, 1))
  assert_eq(xlsx_cells(numbers, "v"), [
    @types.Scalar::Int(45476),
    @types.Scalar::Int(45476),
  ])
  // The whole Formats sheet, with its dates read as numbers.
  let flat = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(sheet="Formats", dates=false),
  )
  assert_eq(flat.get_column("cjk").dtype(), @types.DataType::Float)
  assert_eq(xlsx_cells(flat, "cjk"), [@types.Scalar::Float(45476.5)])
  // A date is the serial it is stored as.
  assert_eq(xlsx_cells(flat, "day"), [@types.Scalar::Int(45293)])
  assert_eq(flat.get_column("time").dtype(), @types.DataType::Float)
}

///|
test "two header cells of one name refuse" {
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(
        @io.read_excel(
          "\{EXCEL_FIXTURES}/openpyxl_formats.xlsx",
          options=ExcelReadOptions::ExcelReadOptions(sheet="Names"),
        ),
      )
    })
    is @types.DataError::DuplicateColumn("dup"),
  )
}

///|
test "a sheet that starts away from A1, and a merged cell" {
  let got = @io.read_excel(
    "\{EXCEL_FIXTURES}/openpyxl_formats.xlsx",
    options=ExcelReadOptions::ExcelReadOptions(sheet="Offset"),
  )
  // The first row carrying a value names the columns; the column before
  // the data keeps the empty name its header cell has.
  assert_eq(got.shape(), (1, 4))
  assert_eq(got.columns(), ["", "b", "c", "d"])
  assert_eq(xlsx_cells(got, ""), [@types.Scalar::Null])
  assert_eq(got.get_column("b").dtype(), @types.DataType::Int)
  assert_eq(xlsx_cells(got, "b"), [@types.Scalar::Int(1)])
  // A merged cell's value sits in its top-left cell alone.
  assert_eq(xlsx_cells(got, "c"), [@types.Scalar::String("merged")])
  assert_eq(xlsx_cells(got, "d"), [@types.Scalar::Null])
}

// ── the writer against the reader ────────────────────────────────────

///|
test "write_excel and read_excel round-trip every dtype a sheet holds" {
  let path = "_build/xlsx_roundtrip.xlsx"
  @io.write_excel(xlsx_frame(), path)
  assert_eq(@io.read_excel(path), xlsx_frame())
  // The options name the sheet and leave the header out.
  let named = "_build/xlsx_named.xlsx"
  @io.write_excel(
    xlsx_frame(),
    named,
    options=ExcelWriteOptions::ExcelWriteOptions(sheet="Records"),
  )
  assert_eq(@io.excel_sheets(named), ["Records"])
  assert_eq(
    @io.read_excel(
      named,
      options=ExcelReadOptions::ExcelReadOptions(sheet="Records"),
    ),
    xlsx_frame(),
  )
  // A sheet the reader would not choose by name.
  let plain = "_build/xlsx_plain.xlsx"
  @io.write_excel(
    xlsx_frame(),
    plain,
    options=ExcelWriteOptions::ExcelWriteOptions(has_header=false),
  )
  // Read as if it had a header, the first row's cells name the columns.
  assert_eq(@io.read_excel(plain).shape(), (2, 6))
  assert_eq(@io.read_excel(plain).columns(), [
    "1", "1.5", "true", "42", "2024-01-02", "2024-03-04T05:06:07.123456",
  ])
  let flat = @io.read_excel(
    plain,
    options=ExcelReadOptions::ExcelReadOptions(has_header=false),
  )
  assert_eq(flat.shape(), (3, 6))
  assert_eq(flat.columns(), [
    "column1", "column2", "column3", "column4", "column5", "column6",
  ])
  assert_eq(xlsx_cells(flat, "column5"), [
    @types.Scalar::Date(19724),
    @types.Scalar::Null,
    @types.Scalar::Date(0),
  ])
  assert_eq(xlsx_cells(flat, "column4"), [
    @types.Scalar::String("42"),
    @types.Scalar::String("2024-01-02"),
    @types.Scalar::Null,
  ])
}

///|
test "dates round-trip through the calendar's edges" {
  // The 1900 calendar's phantom day: the 28th reads as the 28th, and the
  // day after it as the 1st of March.
  let days = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "d",
      [
        @types.Scalar::Date(-25567),
        @types.Scalar::Date(-25509),
        @types.Scalar::Date(-25508),
        @types.Scalar::Date(0),
        @types.Scalar::Date(2932896),
      ],
      @types.DataType::Date,
    ),
    xlsx_scalars(
      "t",
      [
        xlsx_at("1900-02-28T00:00:00.000000"),
        xlsx_at("1900-03-01T00:00:00.000001"),
        xlsx_at("1969-12-31T23:59:59.999999"),
        xlsx_at("2024-02-29T23:59:59.999999"),
        xlsx_at("2148-12-31T12:34:56.789012"),
      ],
      @types.DataType::Timestamp,
    ),
  ])
  let path = "_build/xlsx_calendar.xlsx"
  @io.write_excel(days, path)
  let back = @io.read_excel(path)
  assert_eq(back.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(back.get_column("t").dtype(), @types.DataType::Timestamp)
  assert_eq(back, days)
}

///|
test "what a sheet's cell cannot hold is written as its text, or refused" {
  let list = @types.DataType::List(@types.DataType::Int)
  let record = @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field("a", @types.DataType::Int)]),
  )
  let decimal = @types.Scalar::Decimal(
    @types.Dec128::parse_opt("1234.500000000000000000000000000001").unwrap(),
  )
  let duration = @types.Scalar::Duration(1500000)
  let nested = @types.Scalar::List(
    @types.ListValue::ListValue([@types.Scalar::Int(1)]),
  )
  let structure = @types.Scalar::Struct(
    @types.StructValue::StructValue([
      @types.FieldValue::FieldValue("a", @types.Scalar::Int(1)),
    ]),
  )
  let text = @frame.DataFrame::DataFrame([
    xlsx_scalars("dec", [decimal], @types.DataType::Decimal),
    xlsx_scalars("dur", [duration], @types.DataType::Duration),
    xlsx_scalars("l", [nested], list),
    xlsx_scalars("s", [structure], record),
  ])
  // A float no sheet cell holds: NaN, and both infinities.
  let nonfinite = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "nan",
      [
        @types.Scalar::Float(0.0 / 0.0),
        @types.Scalar::Float(1.0 / 0.0),
        @types.Scalar::Float(-1.0 / 0.0),
      ],
      @types.DataType::Float,
    ),
  ])
  let path = "_build/xlsx_text.xlsx"
  @io.write_excel(text, path)
  let back = @io.read_excel(path)
  // Text keeps every digit of a decimal, where a sheet's number is a
  // double, and the nested values as their text forms.
  for name in ["dec", "dur", "l", "s"] {
    assert_eq(back.get_column(name).dtype(), @types.DataType::String)
    assert_eq(
      xlsx_cells(back, name),
      xlsx_strs(
        text.get_column(name).to_scalars().copy().map(c => c.to_string()),
      ),
    )
  }
  let unheld = "_build/xlsx_nonfinite.xlsx"
  @io.write_excel(nonfinite, unheld)
  let unheld_back = @io.read_excel(unheld)
  assert_eq(unheld_back.get_column("nan").dtype(), @types.DataType::String)
  assert_eq(
    xlsx_cells(unheld_back, "nan"),
    xlsx_strs(["NaN", "Infinity", "-Infinity"]),
  )
  // A text longer than a cell holds refuses the write.
  let long = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "s",
      [@types.Scalar::String(String::make(32768, 'x'))],
      @types.DataType::String,
    ),
  ])
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(long, path)
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains(
      "the cell at row 2, column 1 holds a text of 32768 characters, past the 32767 a sheet's cell holds",
    ),
  )
  // A character no XML part can hold refuses the workbook itself.
  let control = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "s",
      [@types.Scalar::String("a\u{0001}b")],
      @types.DataType::String,
    ),
  ])
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(control, path)
    })
    is @types.DataError::ParseError(@types.ParseErrorDetail::Message(m)) &&
    m.contains("InvalidXml"),
  )
  // An integer past 2^53 has no exact cell; neither has a day outside
  // the calendar.
  let huge = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "i",
      [@types.Scalar::Int(9007199254740993L)],
      @types.DataType::Int,
    ),
  ])
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(huge, path)
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("the integer 9007199254740993, past the 9007199254740992"),
  )
  let early = @frame.DataFrame::DataFrame([
    xlsx_scalars("d", [@types.Scalar::Date(-25568)], @types.DataType::Date),
  ])
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(early, path)
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("column \"d\" holds a day before 1900-01-01"),
  )
  let late = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "t",
      [xlsx_at("10000-01-01T00:00:00")],
      @types.DataType::Timestamp,
    ),
  ])
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(late, path)
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("column \"t\" holds a day past 9999-12-31"),
  )
}

///|
test "a frame past a sheet's limits refuses before anything is written" {
  let path = "_build/xlsx_too_large.xlsx"
  let wide = @frame.DataFrame::DataFrame(
    Array::makei(16385, i => @series.Series::from_ints("c\{i}", [])),
  )
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(wide, path)
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("a frame of 16385 columns is past the 16384 a sheet holds"),
  )
  // The header row counts among the rows.
  let tall = @frame.DataFrame::DataFrame([
    xlsx_scalars(
      "i",
      Array::make(1048576, @types.Scalar::Int(0)),
      @types.DataType::Int,
    ),
  ])
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(tall, path)
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains(
      "a frame of 1048577 rows with its header is past the 1048576 a sheet holds",
    ),
  )
  // Without the header the same frame fits, and is not written here.
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(
        tall,
        path,
        options=ExcelWriteOptions::ExcelWriteOptions(sheet=""),
      )
    })
    is @types.DataError::InvalidOperation(_),
  )
}

///|
test "a sheet name the sheet cannot hold refuses" {
  let df = @frame.DataFrame::DataFrame([])
  for name in ["", "abcdefghijklmnopqrstuvwxyzyxwvuts", "a/b"] {
    assert_true(
      xlsx_refusal(fn() -> Unit raise @types.DataError {
        @io.write_excel(
          df,
          "_build/xlsx_bad_name.xlsx",
          options=ExcelWriteOptions::ExcelWriteOptions(sheet=name),
        )
      })
      is @types.DataError::InvalidOperation(m) &&
      m.has_prefix("excel: "),
    )
  }
}

// ── what does not open ───────────────────────────────────────────────

///|
test "a missing file, a file that is no workbook, and a truncated one refuse" {
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.read_excel("_build/xlsx_absent.xlsx"))
    })
    is @types.DataError::IoError(_),
  )
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.excel_sheets("_build/xlsx_absent.xlsx"))
    })
    is @types.DataError::IoError(_),
  )
  let text = "_build/xlsx_text_file.xlsx"
  @fs.write_string_to_file(text, "name,count\nalpha,42\n")
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.read_excel(text))
    })
    is @types.DataError::ParseError(_),
  )
  // Nothing in the empty bytes opens a workbook either.
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.parse_excel(b""))
    })
    is @types.DataError::ParseError(_),
  )
  // Every truncation of a workbook reads or refuses; an abort here
  // fails the test.
  let whole = @fs.read_file_to_bytes("\{EXCEL_FIXTURES}/openpyxl_formulas.xlsx")
  for length in 0..<=whole.length() {
    let outcome : Result[@frame.DataFrame, @types.DataError] = Ok(
      @io.parse_excel(whole[:length].to_owned()),
    ) catch {
      e => Err(e)
    }
    ignore(outcome)
  }
}

///|
test "an unwritable path raises the io error" {
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      @io.write_excel(xlsx_frame(), "_build/no-such-dir/x.xlsx")
    })
    is @types.DataError::IoError(_),
  )
}
