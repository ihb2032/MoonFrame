// Blackbox tests of the Excel entry over the layouts it opens by a file's
// bytes: a macro-enabled workbook, an OpenDocument spreadsheet and an
// Excel 97–2003 workbook. The last two carry the table
// `openpyxl_types.xlsx` carries, so each reads as that workbook does. The
// fixtures are made by make_fixtures.py beside them, and what each must
// read as is stated here.

///|
/// Assert that `got` is the table every layout carries: a text with its
/// Unicode, a whole number as an integer, a float, a boolean, a day, an
/// instant and a time of day on the epoch's day, with a null in each of
/// the first four.
fn assert_layout_table(got : @frame.DataFrame) -> Unit raise {
  assert_eq(got.shape(), (3, 7))
  assert_eq(got.columns(), ["name", "count", "ratio", "ok", "day", "at", "time"])
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
}

///|
/// Assert that `path`'s layout takes the options every layout does: a
/// sheet by name, a sheet of no value at all as the empty frame, a sheet
/// that is not there refused with the workbook's sheets named, and every
/// row data without a header.
fn assert_layout_options(path : String) -> Unit raise {
  let second = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(sheet="Second"),
  )
  assert_eq(second.shape(), (1, 2))
  assert_eq(second.columns(), ["only", "value"])
  assert_eq(second.get_column("only").dtype(), @types.DataType::Int)
  assert_eq(xlsx_cells(second, "only"), [@types.Scalar::Int(5)])
  assert_eq(xlsx_cells(second, "value"), [@types.Scalar::Null])
  let empty = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(sheet="Third"),
  )
  assert_eq(empty.shape(), (0, 0))
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(
        @io.read_excel(
          path,
          options=ExcelReadOptions::ExcelReadOptions(sheet="Fourth"),
        ),
      )
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains(
      "no sheet named \"Fourth\"; its sheets are \"Data\", \"Second\", \"Third\"",
    ),
  )
  let flat = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(has_header=false),
  )
  assert_eq(flat.shape(), (4, 7))
  assert_eq(flat.columns(), [
    "column1", "column2", "column3", "column4", "column5", "column6", "column7",
  ])
  assert_eq(
    xlsx_cells(flat, "column1"),
    xlsx_strs(["name", "alpha", "北京", "gamma"]),
  )
  assert_eq(xlsx_cells(flat, "column2"), [
    @types.Scalar::String("count"),
    @types.Scalar::String("42"),
    @types.Scalar::Null,
    @types.Scalar::String("7"),
  ])
}

///|
/// Assert that every truncation of a file's bytes either reads or refuses:
/// an abort fails the test before its summary.
fn assert_layout_truncations(path : String) -> Unit raise {
  let whole = @fs.read_file_to_bytes(path)
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
test "a macro-enabled workbook reads as the workbook it was made from" {
  let workbook = "\{EXCEL_FIXTURES}/openpyxl_types.xlsx"
  let enabled = "\{EXCEL_FIXTURES}/openpyxl_macro.xlsm"
  let wanted = @io.read_excel(workbook)
  assert_eq(@io.read_excel(enabled), wanted)
  assert_eq(@io.excel_sheets(enabled), @io.excel_sheets(workbook))
  assert_eq(@io.parse_excel(@fs.read_file_to_bytes(enabled)), wanted)
}

///|
test "an OpenDocument spreadsheet reads by its cells' own types" {
  let path = "\{EXCEL_FIXTURES}/odfpy_types.ods"
  let got = @io.read_excel(path)
  assert_layout_table(got)
  assert_eq(@io.excel_sheets(path), ["Data", "Second", "Third"])
  assert_layout_options(path)
  assert_eq(@io.parse_excel(@fs.read_file_to_bytes(path)), got)
}

///|
test "an Excel 97–2003 workbook reads its numbers by their format" {
  let path = "\{EXCEL_FIXTURES}/xlwt_types.xls"
  let got = @io.read_excel(path)
  assert_layout_table(got)
  assert_eq(@io.excel_sheets(path), ["Data", "Second", "Third"])
  assert_layout_options(path)
  assert_eq(@io.parse_excel(@fs.read_file_to_bytes(path)), got)
  // With dates off a date is the serial it is stored as, counted from
  // 1900, and a time of day the fraction of a day it is.
  let numbers = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(dates=false),
  )
  assert_eq(numbers.get_column("day").dtype(), @types.DataType::Int)
  assert_eq(xlsx_cells(numbers, "day"), [
    @types.Scalar::Int(45293),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(numbers.get_column("at").dtype(), @types.DataType::Float)
  assert_eq(numbers.get_column("time").dtype(), @types.DataType::Float)
  assert_eq(xlsx_cells(numbers, "time"), [
    @types.Scalar::Float(45_000.0 / 86_400.0),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
}

///|
test "both date systems are honoured in an Excel 97–2003 workbook" {
  let path = "\{EXCEL_FIXTURES}/xlwt_types_1904.xls"
  assert_layout_table(@io.read_excel(path))
  assert_layout_options(path)
}

///|
test "a package of another document, and every truncation, refuse or read" {
  // An OpenDocument text document: the package of a spreadsheet with
  // another document in it. The workbook library names the refusal.
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.read_excel("\{EXCEL_FIXTURES}/odfpy_text.odt"))
    })
    is @types.DataError::ParseError(_),
  )
  assert_true(
    xlsx_refusal(fn() -> Unit raise @types.DataError {
      ignore(@io.excel_sheets("\{EXCEL_FIXTURES}/odfpy_text.odt"))
    })
    is @types.DataError::ParseError(_),
  )
  assert_layout_truncations("\{EXCEL_FIXTURES}/odfpy_types.ods")
  assert_layout_truncations("\{EXCEL_FIXTURES}/xlwt_types.xls")
  assert_layout_truncations("\{EXCEL_FIXTURES}/xlwt_types_1904.xls")
  assert_layout_truncations("\{EXCEL_FIXTURES}/openpyxl_macro.xlsm")
  assert_layout_truncations("\{EXCEL_FIXTURES}/xlwt_cells.xls")
}

///|
test "an error cell, a built-in format, and a number that is not finite in an Excel 97–2003 workbook" {
  // An error cell holds no value: it reads null, as in an Excel workbook.
  let path = "\{EXCEL_FIXTURES}/xlwt_cells.xls"
  let errors = @io.read_excel(path)
  assert_eq(errors.shape(), (3, 3))
  assert_eq(errors.get_column("err").dtype(), @types.DataType::String)
  assert_eq(xlsx_cells(errors, "err"), [
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::String("kept"),
  ])
  // A built-in format, which the writer maps to the format's id by its
  // own spelling of it.
  let builtin = @io.read_excel(
    path,
    options=ExcelReadOptions::ExcelReadOptions(sheet="Builtin"),
  )
  assert_eq(builtin.get_column("day").dtype(), @types.DataType::Date)
  assert_eq(xlsx_cells(builtin, "day"), [@types.Scalar::Date(19724)])
  assert_eq(builtin.get_column("time").dtype(), @types.DataType::Timestamp)
  assert_eq(xlsx_cells(builtin, "time"), [
    @types.Scalar::Timestamp(45_000_000_000L),
  ])
  assert_eq(xlsx_cells(builtin, "num"), [@types.Scalar::Int(3)])
  // A number that is not finite is a value the column holds, as a CSV
  // reader's is. The workbooks of the codec's own corpus hold the rest of
  // what a cell can spell.
  let numbers = @io.read_excel(
    ".github/fixtures/xls/reference/xlwt_numbers.xls",
    options=ExcelReadOptions::ExcelReadOptions(has_header=false),
  )
  assert_eq(numbers.shape(), (4, 8))
  for name in numbers.columns() {
    assert_eq(numbers.get_column(name).dtype(), @types.DataType::Float)
  }
  assert_eq(xlsx_cells(numbers, "column5"), [
    @types.Scalar::Float(65536.0),
    @types.Scalar::Float(-9007199254740992.0),
    @types.Scalar::Float(1.0E-10),
    @types.Scalar::Float(@double.infinity),
  ])
  let seventh = xlsx_cells(numbers, "column7")
  assert_eq(seventh[0], @types.Scalar::Float(-536870912.0))
  assert_eq(seventh[1], @types.Scalar::Float(1.5))
  assert_eq(seventh[2], @types.Scalar::Float(1.0E100))
  // A NaN is not equal to itself, so it is matched, not compared.
  assert_true(
    seventh[3] is @types.Scalar::Float(not_a_number) && not_a_number.is_nan(),
  )
}
