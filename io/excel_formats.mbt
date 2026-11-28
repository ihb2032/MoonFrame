// The workbook layouts behind the Excel entries: the workbook library's
// (.xlsx and its macro-enabled twin), an OpenDocument spreadsheet (.ods)
// over the codec in `internal/ods`, and an Excel 97–2003 workbook (.xls)
// over the codec in `internal/xls`. The file's bytes tell them apart — an
// OpenDocument package by its `mimetype` entry, an Excel 97–2003 workbook by
// the compound file's signature, everything else the workbook library's to
// open or refuse. Each layout's cells become the grid the frame builder
// reads, so the header, the column names and the column typing are one code
// for the three.

///|
/// The compound file's signature, which an Excel 97–2003 workbook opens
/// with.
const COMPOUND_SIGNATURE : Bytes = b"\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1"

///|
/// The `mimetype` an OpenDocument spreadsheet package names.
const SPREADSHEET_MIME : String = "application/vnd.oasis.opendocument.spreadsheet"

///|
/// Whether `bytes` open with the compound file's signature.
fn opens_compound(bytes : Bytes) -> Bool {
  if bytes.length() < COMPOUND_SIGNATURE.length() {
    return false
  }
  bytes[0:COMPOUND_SIGNATURE.length()] == COMPOUND_SIGNATURE
}

///|
/// Whether `bytes` are an OpenDocument spreadsheet package: a ZIP whose
/// `mimetype` entry names the spreadsheet document. A package that is not
/// a ZIP answers false — the workbook library names the refusal.
fn opens_spreadsheet_package(bytes : Bytes) -> Bool {
  let opened : Result[@zip.Archive, @zip.ZipError] = Ok(@zip.read(bytes)) catch {
    e => Err(e)
  }
  let archive = match opened {
    Ok(archive) => archive
    Err(_) => return false
  }
  match archive.get("mimetype") {
    Some(mime) => (@utf8.decode(mime) catch { _ => "" }) == SPREADSHEET_MIME
    None => false
  }
}

///|
/// A workbook's sheet names, in the workbook's order, whichever layout it
/// opens as. The codec's own refusal is the entry's error.
fn excel_sheet_names(bytes : Bytes) -> Array[String] raise @types.DataError {
  if opens_spreadsheet_package(bytes) {
    return @ods.ods_open(bytes).sheets()
  }
  if opens_compound(bytes) {
    return @xls.xls_open(bytes).sheets()
  }
  excel_workbook(bytes).sheets().map(sheet => sheet.name)
}

///|
/// The sheet `name` names among `names` — the first when the name is empty
/// — by its position, or the refusal that names the workbook's sheets.
fn excel_sheet_position(
  names : Array[String],
  name : String,
) -> Int32 raise @types.DataError {
  if name == "" {
    if names.length() == 0 {
      raise @types.DataError::InvalidOperation(
        "excel: the workbook carries no sheet",
      )
    }
    return 0
  }
  for i, sheet in names {
    if sheet == name {
      return i
    }
  }
  let quoted : Array[String] = []
  for sheet in names {
    quoted.push("\"\{sheet}\"")
  }
  raise @types.DataError::InvalidOperation(
    "excel: the workbook carries no sheet named \"\{name}\"; its sheets are \{quoted.join(", ")}",
  )
}

///|
/// The workbook's sheet as a frame, whichever layout the bytes open as.
/// Each layout is opened once: its sheets name the one `options.sheet`
/// asks for, and the same open workbook gives its cells, as the frame
/// builder reads them.
fn excel_workbook_frame(
  bytes : Bytes,
  options : ExcelReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  if opens_spreadsheet_package(bytes) {
    let book = @ods.ods_open(bytes)
    let position = excel_sheet_position(book.sheets(), options.sheet)
    return excel_grid_frame(ods_grid(book.grid(sheet=position)), options)
  }
  if opens_compound(bytes) {
    let book = @xls.xls_open(bytes)
    let position = excel_sheet_position(book.sheets(), options.sheet)
    return excel_grid_frame(
      xls_grid(book.grid(sheet=position), options),
      options,
    )
  }
  let workbook = excel_workbook(bytes)
  let names = workbook.sheets().map(sheet => sheet.name)
  let position = excel_sheet_position(names, options.sheet)
  excel_grid_frame(excel_grid(workbook, position, options.dates), options)
}

///|
/// An OpenDocument sheet's cells as the frame builder's grid: a text, a
/// number, a boolean, a day and an instant are themselves, a time of day
/// the instant on the epoch day (the library having no other day a time
/// alone names), and an empty text a missing cell. A date is typed in the
/// file, so `dates` does not apply to it.
fn ods_grid(sheet : @ods.OdsGrid) -> Array[Array[ExcelCell]] {
  let placed : Array[(Int32, Int32, ExcelCell)] = []
  for cell in sheet.cells() {
    let value : ExcelCell = match cell.value() {
      @ods.OdsValue::Text(text) => if text == "" { Missing } else { Text(text) }
      @ods.OdsValue::Number(number) => Number(number)
      @ods.OdsValue::Boolean(flag) => Boolean(flag)
      @ods.OdsValue::Day(days) => Day(days)
      @ods.OdsValue::Instant(micros) => Instant(micros)
      @ods.OdsValue::Time(micros) => Instant(micros)
    }
    placed.push((cell.row(), cell.col(), value))
  }
  excel_placed_grid(placed)
}

///|
/// An Excel 97–2003 sheet's cells as the frame builder's grid: a number is
/// read by its style's format under `dates` — the rule the workbook
/// library's numbers are read by — and as the number it is stored as
/// without; a text is itself, a boolean too; an error cell, and an empty
/// text, are a missing cell. Both date systems are the workbook's own.
fn xls_grid(
  grid : @xls.XlsGrid,
  options : ExcelReadOptions,
) -> Array[Array[ExcelCell]] raise @types.DataError {
  let date1904 = grid.date_1904()
  let placed : Array[(Int32, Int32, ExcelCell)] = []
  for cell in grid.cells() {
    let (row, col) = (cell.row(), cell.col())
    let place = excel_place(row + 1, col + 1)
    let value : ExcelCell = match cell.value() {
      @xls.XlsValue::Text(text) => if text == "" { Missing } else { Text(text) }
      @xls.XlsValue::Boolean(flag) => Boolean(flag)
      @xls.XlsValue::Error(_) => Missing
      @xls.XlsValue::Number(number, format) =>
        if options.dates {
          excel_number(number, xls_format(format), date1904, place)
        } else {
          Number(number)
        }
    }
    placed.push((row, col, value))
  }
  excel_placed_grid(placed)
}

///|
/// An Excel 97–2003 style's number format as the date rules read one: a
/// built-in format by its id, a custom one by its code.
fn xls_format(format : @xls.XlsFormat) -> ExcelFormat {
  match format {
    @xls.XlsFormat::Builtin(id) => excel_builtin_format(id)
    @xls.XlsFormat::Custom(code) => excel_custom_format(code)
  }
}
