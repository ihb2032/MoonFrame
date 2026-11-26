// One sheet's cells as a frame's columns. A cell is read by what it holds
// — text, a boolean, or a number — and a number by its format as well:
// under a date or a time format it is the day or the instant its serial
// names. Each column then takes the narrowest dtype holding every value
// in it, the rule the CSV reader follows; a column holding both a
// date-formatted number and a plain one refuses, since which reading is
// right is not the sheet's to say.

///|
/// One cell of a sheet as the column verdicts read it.
priv enum ExcelCell {
  /// An empty cell, a cell carrying an error (`#DIV/0!`, `#N/A`, …), or a
  /// formula with no cached value.
  Missing
  Text(String)
  Boolean(Bool)
  /// A number no date or time format makes a date of.
  Number(Double)
  /// A day count since the epoch, from a date format with no time.
  Day(Int64)
  /// Microseconds since the epoch: an instant, or a time of day.
  Instant(Int64)
}

///|
/// What the number format of style `id` makes of a number: a builtin one
/// by its id, a custom one by its code.
fn excel_format(format : @xlsx.NumberFormat?) -> ExcelFormat {
  match format {
    None => Plain
    Some(@xlsx.NumberFormat::Builtin(id)) => excel_builtin_format(id)
    Some(@xlsx.NumberFormat::Custom(code)) => excel_custom_format(code)
  }
}

///|
/// The sheet's cells by row and by column, over the rows and the columns
/// that carry a value — a sheet with none answering no row. Under `dates`
/// a number is read by its format; without it, as the number it is stored
/// as.
fn excel_grid(
  workbook : @xlsx.Workbook,
  sheet : @xlsx.Worksheet,
  dates : Bool,
) -> Array[Array[ExcelCell]] raise @types.DataError {
  // The first and the last row carrying a value, and the last column.
  let mut top = -1
  let mut bottom = 0
  let mut width = 0
  for cell in sheet.cells {
    if cell.value != "" {
      if top < 0 || cell.row < top {
        top = cell.row
      }
      if cell.row > bottom {
        bottom = cell.row
      }
      if cell.col > width {
        width = cell.col
      }
    }
  }
  if top < 0 {
    return []
  }
  let grid : Array[Array[ExcelCell]] = Array::makei(bottom - top + 1, _ => {
    Array::make(width, Missing)
  })
  // What each style's number format makes of a number, read once.
  let formats = workbook.styles.map(style => excel_format(style.number_format))
  let date1904 = workbook.workbook_props.date_1904 is Some(true)
  let name = sheet.name
  for cell in sheet.cells {
    if cell.value == "" {
      continue
    }
    let place = excel_place(cell.row, cell.col)
    let value = excel_cell_value(workbook, name, cell.row, cell.col)
    grid[cell.row - top][cell.col - 1] = excel_read(
      value,
      sheet,
      cell.row,
      cell.col,
      formats,
      dates,
      date1904,
      place,
    )
  }
  grid
}

///|
/// The typed value of the cell at `row` and `col`, the library's refusal
/// being the entry's error.
fn excel_cell_value(
  workbook : @xlsx.Workbook,
  name : String,
  row : Int32,
  col : Int32,
) -> @xlsx.CellValue? raise @types.DataError {
  workbook.get_cell_value_raw_rc(name, row, col) catch {
    e => raise excel_error(e)
  }
}

///|
/// The style that formats the cell at `row` and `col`: the cell's own,
/// failing that its row's, then its column's.
fn excel_style(
  sheet : @xlsx.Worksheet,
  row : Int32,
  col : Int32,
) -> Int32 raise @types.DataError {
  sheet.effective_style_id_rc(row, col) catch {
    e => raise excel_error(e)
  }
}

///|
/// A cell's typed value as the column verdicts read it: a missing value,
/// an error, and an empty text are a missing cell; a number is read by
/// its format — the style that formats the cell at `row` and `col`,
/// looked up in `formats` — under `dates`, and as the number it is stored
/// as without.
fn excel_read(
  value : @xlsx.CellValue?,
  sheet : @xlsx.Worksheet,
  row : Int32,
  col : Int32,
  formats : Array[ExcelFormat],
  dates : Bool,
  date1904 : Bool,
  place : String,
) -> ExcelCell raise @types.DataError {
  match value {
    None => Missing
    Some(@xlsx.CellValue::String(text)) =>
      if text == "" {
        Missing
      } else {
        Text(text)
      }
    Some(@xlsx.CellValue::Bool(b)) => Boolean(b)
    // A cell carrying an error holds no value a frame column can.
    Some(@xlsx.CellValue::Error(_)) => Missing
    Some(@xlsx.CellValue::Numeric(serial)) =>
      if dates {
        let style = excel_style(sheet, row, col)
        excel_number(
          serial,
          formats.get(style).unwrap_or(Plain),
          date1904,
          place,
        )
      } else {
        Number(serial)
      }
  }
}

///|
/// The text of a cell, as a header's name and a `String` column's cell:
/// the value forms the other dtypes render by.
fn excel_text(cell : ExcelCell) -> String {
  match cell {
    Missing => ""
    Text(text) => text
    Boolean(b) => if b { "true" } else { "false" }
    Number(v) => v.to_string()
    Day(days) => @types.Scalar::Date(days).to_string()
    Instant(micros) => @types.Scalar::Timestamp(micros).to_string()
  }
}

///|
/// The cell as a column of `dtype` holds it: a missing cell is null, and
/// a shape the dtype cannot hold is null too — the verdicts never send
/// one there.
fn excel_scalar(cell : ExcelCell, dtype : @types.DataType) -> @types.Scalar {
  match dtype {
    String =>
      match cell {
        Missing => Null
        Text(_) | Boolean(_) | Number(_) | Day(_) | Instant(_) =>
          String(excel_text(cell))
      }
    Bool =>
      match cell {
        Missing => Null
        Boolean(b) => Bool(b)
        Text(_) | Number(_) | Day(_) | Instant(_) => Null
      }
    Int | Float =>
      match cell {
        Missing => Null
        Number(v) =>
          if dtype is @types.DataType::Int {
            Int(v.to_int64())
          } else {
            Float(v)
          }
        Text(_) | Boolean(_) | Day(_) | Instant(_) => Null
      }
    Date =>
      match cell {
        Missing => Null
        Day(days) => Date(days)
        Instant(micros) => Date(@types.timestamp_micros_to_day(micros).0)
        Text(_) | Boolean(_) | Number(_) => Null
      }
    Timestamp =>
      match cell {
        Missing => Null
        Instant(micros) => Timestamp(micros)
        Day(days) => Timestamp(days * EXCEL_DAY_MICROS)
        Text(_) | Boolean(_) | Number(_) => Null
      }
    Null | Decimal | Duration | List(_) | Struct(_) => Null
  }
}

///|
/// One column of the sheet: every cell from row `from` on, under the
/// narrowest dtype holding all of them. Text makes a `String` column, as
/// a boolean beside a number does; a date beside a plain number refuses,
/// since the sheet does not say which reading is right.
fn excel_column(
  name : String,
  rows : Array[Array[ExcelCell]],
  from : Int32,
  c : Int32,
) -> @series.Series raise @types.DataError {
  let mut text = false
  let mut boolean = false
  let mut number = false
  let mut integral = true
  let mut day = false
  let mut instant = false
  for r in from..<rows.length() {
    match rows[r][c] {
      Missing => ()
      Text(_) => text = true
      Boolean(_) => boolean = true
      Number(v) => {
        number = true
        // An integer is a whole number the double holds exactly.
        if integral && (v != v.floor() || v.abs() > 9007199254740992.0) {
          integral = false
        }
      }
      Day(_) => day = true
      Instant(_) => instant = true
    }
  }
  if (day || instant) && number {
    raise @types.DataError::InvalidOperation(
      "excel: column \"\{name}\" holds date-formatted numbers beside plain ones, and the sheet does not say which reading is right; format the column alike, or read with dates set to false",
    )
  }
  let dtype : @types.DataType = if text || (boolean && number) {
    String
  } else if instant {
    Timestamp
  } else if day {
    Date
  } else if boolean {
    Bool
  } else if number && integral {
    Int
  } else if number {
    Float
  } else {
    // A column of nothing to type it by: the all-null column's dtype.
    String
  }
  let cells : Array[@types.Scalar] = []
  for r in from..<rows.length() {
    cells.push(excel_scalar(rows[r][c], dtype))
  }
  @series.Series::from_scalars(name, cells, dtype~)
}

///|
/// The sheet as a frame: the first row carrying a value names the
/// columns when the options ask for a header, and `"column1"`,
/// `"column2"`, … do otherwise; every row after it is a frame row. A
/// sheet with no value at all is the `0×0` frame.
fn excel_frame(
  workbook : @xlsx.Workbook,
  sheet : @xlsx.Worksheet,
  options : ExcelReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  let rows = excel_grid(workbook, sheet, options.dates)
  if rows.is_empty() {
    return @frame.DataFrame::from_parts([], 0)
  }
  let from = if options.has_header { 1 } else { 0 }
  let columns : Array[@series.Series] = []
  for c in 0..<rows[0].length() {
    let name = if options.has_header {
      excel_text(rows[0][c])
    } else {
      "column\{c + 1}"
    }
    columns.push(excel_column(name, rows, from, c))
  }
  @frame.DataFrame::from_parts(columns, rows.length() - from)
}
