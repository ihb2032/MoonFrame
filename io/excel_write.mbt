// A frame as one workbook. The sheet holds a header row when the options
// ask for one and a row per frame row after it, each cell written as its
// dtype is held: an integer, a float, and a boolean as the number or the
// boolean the sheet keeps; a `Date` and a `Timestamp` as the serial of
// their day and instant under a date format, so a spreadsheet shows them
// as dates; and text as text, whatever it spells — a number's look-alike
// stays text, as it does in a CSV round trip.

///|
/// The rows a sheet holds, its header among them.
const EXCEL_MAX_ROWS : Int32 = 1048576

///|
/// The columns a sheet holds.
const EXCEL_MAX_COLUMNS : Int32 = 16384

///|
/// The number format a `Date` is written under: the builtin short date.
const EXCEL_DAY_FORMAT : Int32 = 14

///|
/// The number format a `Timestamp` is written under.
const EXCEL_INSTANT_FORMAT : String = "yyyy-mm-dd hh:mm:ss"

///|
/// The largest magnitude an integer can have and still be held exactly
/// by a sheet's number.
const EXCEL_EXACT_INTEGER : Int64 = 9007199254740992L

///|
/// The date formats of the workbook being written, by style id.
priv struct ExcelStyles {
  day : Int32
  instant : Int32
}

///|
/// One cell written to its place, by its dtype: nothing for a null, the
/// number or the boolean for the three the sheet keeps, the serial under
/// its format for a day or an instant, and text for the rest — a
/// duration, a decimal, a list, and a struct as their text forms, and a
/// float that is NaN or infinite as its text, no sheet cell holding one.
fn excel_write_cell(
  workbook : @xlsx.Workbook,
  sheet : String,
  row : Int32,
  col : Int32,
  cell : @types.Scalar,
  styles : ExcelStyles,
  column : String,
) -> Unit raise @types.DataError {
  let (serial, style) = match cell {
    Null => return
    Int(v) =>
      if v > EXCEL_EXACT_INTEGER || v < -EXCEL_EXACT_INTEGER {
        raise @types.DataError::Unsupported(
          "excel: column \"\{column}\" holds the integer \{v}, past the \{EXCEL_EXACT_INTEGER} a sheet's number holds exactly; cast the column to Float or String",
        )
      } else {
        ignore(
          excel_write(
            workbook,
            sheet,
            row,
            col,
            @xlsx.CellValue::Numeric(v.to_double()),
          ),
        )
        return
      }
    Duration(_) | Decimal(_) | List(_) | Struct(_) => {
      ignore(excel_write_text(workbook, sheet, row, col, cell.to_string()))
      return
    }
    Float(v) =>
      if v.is_nan() || v.is_inf() {
        ignore(excel_write_text(workbook, sheet, row, col, cell.to_string()))
        return
      } else {
        (v, -1)
      }
    Bool(b) => {
      ignore(excel_write(workbook, sheet, row, col, @xlsx.CellValue::Bool(b)))
      return
    }
    String(text) => {
      ignore(excel_write_text(workbook, sheet, row, col, text))
      return
    }
    Date(days) => (excel_day_serial(days, false, column), styles.day)
    Timestamp(micros) =>
      (excel_instant_serial(micros, false, column), styles.instant)
  }
  ignore(
    excel_write(workbook, sheet, row, col, @xlsx.CellValue::Numeric(serial)),
  )
  if style >= 0 {
    excel_style_cell(workbook, sheet, row, col, style)
  }
}

///|
/// Give a cell its style, the library's refusal being the entry's error.
fn excel_style_cell(
  workbook : @xlsx.Workbook,
  sheet : String,
  row : Int32,
  col : Int32,
  style : Int32,
) -> Unit raise @types.DataError {
  workbook.set_cell_style_rc(sheet, row, col, style) catch {
    e => raise excel_error(e)
  }
}

///|
/// The workbook's bytes, the library's refusal being the entry's error.
fn excel_book_bytes(workbook : @xlsx.Workbook) -> Bytes raise @types.DataError {
  @xlsx.write(workbook) catch {
    e => raise excel_error(e)
  }
}

///|
/// Write a typed value, the library's refusal being the entry's error.
fn excel_write(
  workbook : @xlsx.Workbook,
  sheet : String,
  row : Int32,
  col : Int32,
  value : @xlsx.CellValue,
) -> Unit raise @types.DataError {
  workbook.set_cell_value_rc(sheet, row, col, value) catch {
    e => raise excel_error(e)
  }
}

///|
/// The most characters a sheet's cell holds.
const EXCEL_MAX_TEXT : Int32 = 32767

///|
/// Write text as a text cell. A text a cell cannot hold refuses: the
/// workbook library writes one of any length, and no sheet opens the
/// workbook that holds it.
fn excel_write_text(
  workbook : @xlsx.Workbook,
  sheet : String,
  row : Int32,
  col : Int32,
  text : String,
) -> Unit raise @types.DataError {
  if text.length() > EXCEL_MAX_TEXT {
    raise @types.DataError::InvalidOperation(
      "excel: the cell at row \{row}, column \{col} holds a text of \{text.length()} characters, past the \{EXCEL_MAX_TEXT} a sheet's cell holds",
    )
  }
  workbook.set_cell_rc(sheet, row, col, text) catch {
    e => raise excel_error(e)
  }
}

///|
/// The frame as a workbook's bytes: a sheet named as the options say,
/// holding the frame's columns in its order — under a header row when
/// the options ask for one.
fn excel_workbook_bytes(
  df : @frame.DataFrame,
  options : ExcelWriteOptions,
) -> Bytes raise @types.DataError {
  let columns = df.column_series()
  let rows = df.nrows() + (if options.has_header { 1 } else { 0 })
  if rows > EXCEL_MAX_ROWS {
    raise @types.DataError::InvalidOperation(
      "excel: a frame of \{rows} rows with its header is past the \{EXCEL_MAX_ROWS} a sheet holds",
    )
  }
  if columns.length() > EXCEL_MAX_COLUMNS {
    raise @types.DataError::InvalidOperation(
      "excel: a frame of \{columns.length()} columns is past the \{EXCEL_MAX_COLUMNS} a sheet holds",
    )
  }
  let workbook = @xlsx.Workbook::new()
  let sheet = options.sheet
  ignore(workbook.add_sheet(sheet) catch { e => raise excel_error(e) })
  let styles = ExcelStyles::{
    day: workbook.new_style(
      @xlsx.Style::builtin_number_format(EXCEL_DAY_FORMAT),
    ),
    instant: workbook.new_style(
      @xlsx.Style::number_format(EXCEL_INSTANT_FORMAT),
    ),
  }
  // The first row of the frame's own rows: under the header, or the
  // sheet's first when there is none.
  let first = if options.has_header { 2 } else { 1 }
  for c, column in columns {
    if options.has_header {
      excel_write_text(workbook, sheet, 1, c + 1, column.name())
    }
    let cells = column.to_scalars()
    for r in 0..<cells.length() {
      excel_write_cell(
        workbook,
        sheet,
        first + r,
        c + 1,
        cells[r],
        styles,
        column.name(),
      )
    }
  }
  excel_book_bytes(workbook)
}

///|
/// Write a frame as one Excel workbook: a sheet named `options.sheet`,
/// holding the frame's column names as a header row when `options.has_header`
/// is on and a row per frame row after it, in the 1900 date system.
///
/// Each cell is written as its dtype is held. An `Int`, a `Float`, and a
/// `Bool` are the number or the boolean the sheet keeps — an integer past
/// 2^53 refuses, a sheet's number holding it only approximately, and a
/// float that is NaN or infinite is written as its text. A `Date` is the
/// serial of its day under a short-date format and a `Timestamp` the
/// serial of its instant under a date-and-time format, to the microsecond
/// the format's number holds; a day before 1900-01-01 or past 9999-12-31
/// refuses, the calendar having no cell for it. Text is a text cell
/// whatever it spells, and a `Duration`, a `Decimal`, a list, and a struct
/// are written as their text forms — a decimal as its text keeps every
/// digit, where a sheet's number is a double. A null is an empty cell.
/// A frame of more rows than a sheet holds, its header counted, or of
/// more columns, refuses before anything is written.
///
/// Raises `IoError` for the file write, `InvalidOperation` for a frame
/// or a sheet name the sheet cannot hold, `Unsupported` for an integer
/// or a day past what a cell holds, and `ParseError` when the workbook
/// cannot be built.
pub fn write_excel(
  df : @frame.DataFrame,
  path : String,
  options? : ExcelWriteOptions,
) -> Unit raise @types.DataError {
  let chosen = match options {
    Some(given) => given
    None => ExcelWriteOptions::ExcelWriteOptions()
  }
  let bytes = excel_workbook_bytes(df, chosen)
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}
