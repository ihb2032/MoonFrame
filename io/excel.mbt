// The Excel workbook interchange — .xlsx read and written over the
// workbook library in moonbitlang/mbtexcel: the ZIP container, the XML
// parts, the shared strings, and the styles are that package's, and what
// a sheet's cells become in a frame is decided here. A column takes the
// narrowest dtype holding every value in it, the rule the CSV reader
// follows, with the one fact a sheet carries and text does not: a
// number's format, which says whether it is a date or an instant.

///|
/// Options that control how an Excel workbook is read into a `DataFrame`.
///
/// - `sheet` — the sheet to read, by name; `""`, the default, is the
///   workbook's first sheet. `excel_sheets` names them.
/// - `has_header` — when `true` (the default), the first row carrying a
///   value supplies the column names; when `false`, every row is data and
///   the columns are named `"column1"`, `"column2"`, … in the sheet's
///   order.
/// - `dates` — when `true` (the default), a number under a date or a time
///   format reads as a `Date` or a `Timestamp`; when `false`, it is the
///   number it is stored as.
pub struct ExcelReadOptions {
  sheet : String
  has_header : Bool
  dates : Bool
}

///|
/// The read options with their defaults: the first sheet, a header, and
/// dates read.
pub fn ExcelReadOptions::ExcelReadOptions(
  sheet~ : String = "",
  has_header~ : Bool = true,
  dates~ : Bool = true,
) -> Self {
  { sheet, has_header, dates, }
}

///|
/// Options that control how a `DataFrame` is written as an Excel workbook.
///
/// - `sheet` — the sheet's name, `"Sheet1"` by default.
/// - `has_header` — when `true` (the default), the frame's column names
///   are the sheet's first row.
pub struct ExcelWriteOptions {
  sheet : String
  has_header : Bool
}

///|
/// The write options with their defaults: one sheet named `"Sheet1"`,
/// with a header row.
pub fn ExcelWriteOptions::ExcelWriteOptions(
  sheet~ : String = "Sheet1",
  has_header~ : Bool = true,
) -> Self {
  { sheet, has_header, }
}

///|
/// The workbook library's refusal, as the error the Excel entries raise:
/// a workbook the mapping does not carry — an encrypted one — is
/// `Unsupported`, a write the sheet cannot hold is `InvalidOperation`,
/// and a file that is not a workbook the library can open is a
/// `ParseError`.
fn excel_error(e : @xlsx.XlsxError) -> @types.DataError {
  match e {
    EncryptedPackage =>
      @types.DataError::Unsupported(
        "excel: the workbook is encrypted, which these entries do not open",
      )
    InvalidSheetName(_)
    | SheetAlreadyExists(_)
    | CellTextTooLong(_)
    | InvalidExcelDate(_) =>
      @types.DataError::InvalidOperation("excel: \{@debug.to_string(e)}")
    _ =>
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message("excel: \{@debug.to_string(e)}"),
      )
  }
}

///|
/// A workbook opened from its bytes.
fn excel_workbook(bytes : Bytes) -> @xlsx.Workbook raise @types.DataError {
  @xlsx.read(bytes) catch {
    e => raise excel_error(e)
  }
}

///|
/// The sheet `name` names — the first one when the name is empty — or
/// the refusal that names the workbook's sheets.
fn excel_sheet(
  workbook : @xlsx.Workbook,
  name : String,
) -> @xlsx.Worksheet raise @types.DataError {
  let sheets = workbook.sheets()
  if name == "" {
    if sheets.length() == 0 {
      raise @types.DataError::InvalidOperation(
        "excel: the workbook carries no sheet",
      )
    }
    return sheets[0]
  }
  for sheet in sheets {
    if sheet.name == name {
      return sheet
    }
  }
  let names : Array[String] = []
  for sheet in sheets {
    names.push("\"\{sheet.name}\"")
  }
  raise @types.DataError::InvalidOperation(
    "excel: the workbook carries no sheet named \"\{name}\"; its sheets are \{names.join(", ")}",
  )
}

///|
/// A file's bytes, an unreadable file being the I/O error it is.
fn excel_bytes(path : String) -> Bytes raise @types.DataError {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// The names of a workbook's sheets, in the workbook's order.
pub fn excel_sheets(path : String) -> Array[String] raise @types.DataError {
  let workbook = excel_workbook(excel_bytes(path))
  workbook.sheets().map(sheet => sheet.name)
}

///|
/// Read one sheet of an Excel workbook into a frame — the first sheet,
/// or the one `options.sheet` names; `excel_sheets` lists them. The
/// first row carrying a value names the columns unless `has_header` is
/// off, and each column takes the narrowest dtype holding every value in
/// it: text a `String`, a boolean a `Bool`, whole numbers an `Int`, any
/// other number a `Float`.
///
/// A number under a date format reads as a `Date` — as a `Timestamp`
/// when the format shows a time of day, or the number carries one — and
/// under a time format as the time of day on 1970-01-01, there being no
/// other day a time alone names. The format is read off its code: the
/// date and time formats every locale shares (the builtin ids 14 to 22
/// and 45 to 47, and a custom code by its letters), since the formats a
/// locale re-spells are a date in one workbook and an accounting format
/// in another — those read as numbers. Both date systems are honoured.
/// `dates` off reads every such number as the number it is stored as.
///
/// What a frame column cannot hold is null: an empty cell, a cell
/// carrying an error (`#DIV/0!`, `#N/A`, …), and a formula whose cached
/// value is missing; a formula's cached value is what reads, never the
/// formula. A merged cell's value sits in its top-left cell alone, and
/// the others read null. A column holding date-formatted numbers beside
/// plain ones refuses, naming the column.
///
/// Raises `IoError` for the file read, `ParseError` for a file that is
/// not a workbook the reader can open, `Unsupported` for an encrypted
/// one, `InvalidOperation` for a sheet the workbook does not carry and
/// for the mixed column, and `DuplicateColumn(name)` for two header
/// cells of one name.
pub fn read_excel(
  path : String,
  options? : ExcelReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  parse_excel(excel_bytes(path), options?)
}

///|
/// Parse an Excel workbook's bytes into a frame — `read_excel`'s binary
/// counterpart, for bytes already in memory. The same contract as
/// `read_excel`'s.
pub fn parse_excel(
  bytes : Bytes,
  options? : ExcelReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  let chosen = match options {
    Some(given) => given
    None => ExcelReadOptions::ExcelReadOptions()
  }
  let workbook = excel_workbook(bytes)
  excel_frame(workbook, excel_sheet(workbook, chosen.sheet), chosen)
}
