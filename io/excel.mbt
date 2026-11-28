// The spreadsheet interchange: a sheet read into a frame from the three
// workbook layouts a file's bytes tell apart, and written as the first of
// them. An Excel workbook — `.xlsx`, and the macro-enabled `.xlsm` — is
// read over the workbook library in moonbitlang/mbtexcel, whose the ZIP
// container, the XML parts, the shared strings and the styles are; an
// OpenDocument spreadsheet (`.ods`) over the codec in `internal/ods`; and
// an Excel 97–2003 workbook (`.xls`) over the codec in `internal/xls`.
// What a sheet's cells become in a frame is decided here, for the three
// alike: a column takes the narrowest dtype holding every value in it, the
// rule the CSV reader follows, with the one fact a sheet carries and text
// does not — a cell's own type where the layout stores one, and otherwise
// its number's format, which says whether it is a date or an instant.

///|
/// Options that control how a spreadsheet is read into a `DataFrame`.
///
/// - `sheet` — the sheet to read, by name; `""`, the default, is the
///   workbook's first sheet. `excel_sheets` names them.
/// - `has_header` — when `true` (the default), the first row carrying a
///   value supplies the column names; when `false`, every row is data and
///   the columns are named `"column1"`, `"column2"`, … in the sheet's
///   order.
/// - `dates` — when `true` (the default), a number under a date or a time
///   format reads as a `Date` or a `Timestamp`; when `false`, it is the
///   number it is stored as. A cell whose date the file itself types — an
///   OpenDocument spreadsheet's — is that date whatever `dates` is.
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
/// A file's bytes, an unreadable file being the I/O error it is.
fn excel_bytes(path : String) -> Bytes raise @types.DataError {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// The names of a workbook's sheets, in the workbook's order — an Excel
/// workbook's, an OpenDocument spreadsheet's or an Excel 97–2003
/// workbook's, whichever the file opens as.
pub fn excel_sheets(path : String) -> Array[String] raise @types.DataError {
  excel_sheet_names(excel_bytes(path))
}

///|
/// Read one sheet of a spreadsheet into a frame — the first sheet, or the
/// one `options.sheet` names; `excel_sheets` lists them. The layout is the
/// one the file's bytes name: an Excel workbook (`.xlsx`, or the
/// macro-enabled `.xlsm`), an OpenDocument spreadsheet (`.ods`), or an
/// Excel 97–2003 workbook (`.xls`), whichever the file opens as. The
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
/// `dates` off reads every such number as the number it is stored as. An
/// OpenDocument spreadsheet types its cells itself, so there a date, an
/// instant and a time of day read as themselves and `dates` does not
/// apply.
///
/// What a frame column cannot hold is null: an empty cell, a cell
/// carrying an error (`#DIV/0!`, `#N/A`, …), and a formula whose cached
/// value is missing; a formula's cached value is what reads, never the
/// formula. A number that is not finite — an infinity or a NaN an Excel
/// 97–2003 sheet stores — reads as the `Float` it is. A merged cell's
/// value sits in its top-left cell alone, and the others read null. A
/// column holding date-formatted numbers beside plain ones refuses,
/// naming the column.
///
/// Raises `IoError` for the file read, `ParseError` for a file that is
/// not a spreadsheet the reader can open, `Unsupported` for an encrypted
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
/// Parse a spreadsheet's bytes into a frame — `read_excel`'s binary
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
  excel_workbook_frame(bytes, chosen)
}
