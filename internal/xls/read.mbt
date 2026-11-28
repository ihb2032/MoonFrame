// The reader's entry: the workbook stream read out of its compound file,
// the workbook globals, and — for the one sheet asked for — its cells;
// and the types a sheet's cells answer as. The cells are raw: which dtype
// a column takes, and what a number under a date format means, is left to
// the caller, who has each number and its style's number format.

///|
/// One sheet's cells as the file holds them: the workbook's date system,
/// and every cell that is not empty. A grid is answered by `XlsBook::grid`
/// and read through its accessors.
pub struct XlsGrid {
  priv from_1904 : Bool
  priv held : Array[XlsCell]
}

///|
/// Whether the workbook counts dates from 1904-01-01 rather than from
/// 1899-12-30: what a number under a date format is to be read against.
pub fn XlsGrid::date_1904(self : XlsGrid) -> Bool {
  self.from_1904
}

///|
/// Every cell the sheet holds that is not empty, in row-then-column
/// order: a text, a boolean, a number or an error. A styled empty cell
/// (a BLANK or MULBLANK record) and a formula whose cached value is a
/// blank string are not among them. A fresh array is answered, so a
/// caller cannot reach into the grid and change it.
pub fn XlsGrid::cells(self : XlsGrid) -> Array[XlsCell] {
  self.held.copy()
}

///|
/// One cell of a sheet: where it lies and what it holds. Answered by
/// `XlsBook::grid` and read through its accessors.
pub struct XlsCell {
  priv rowx : Int32
  priv colx : Int32
  priv held : XlsValue
}

///|
/// The cell's row, zero-based.
pub fn XlsCell::row(self : XlsCell) -> Int32 {
  self.rowx
}

///|
/// The cell's column, zero-based.
pub fn XlsCell::col(self : XlsCell) -> Int32 {
  self.colx
}

///|
/// The cell's value.
pub fn XlsCell::value(self : XlsCell) -> XlsValue {
  self.held
}

///|
/// What a cell holds.
pub(all) enum XlsValue {
  Text(String)
  Boolean(Bool)
  /// A stored number and its style's number format.
  Number(Double, XlsFormat)
  /// An error cell (`#DIV/0!`, `#N/A`, …), by the text the sheet shows.
  Error(String)
}

///|
/// A number format: a built-in one by its id, or a custom one by its code.
pub(all) enum XlsFormat {
  Builtin(Int32)
  Custom(String)
}

///|
/// A workbook opened from its bytes: its compound file read, and its
/// workbook globals — the sheet list, the shared strings, the formats —
/// parsed once. The sheets are named through `sheets`, and one sheet's
/// cells are read through `grid`.
pub struct XlsBook {
  priv stream : Bytes
  priv globals : Globals
}

///|
/// The workbook's sheets, in workbook order, by name.
///
/// Every worksheet is listed, hidden ones included, named as its
/// BOUNDSHEET record spells it. A chart sheet, a macro sheet and a module
/// hold no cells, and are passed over, as the format's readers do.
pub fn XlsBook::sheets(self : XlsBook) -> Array[String] {
  self.globals.sheets.map(sheet => sheet.name)
}

///|
/// The cells of one sheet, `sheet` being its position in workbook order,
/// the first sheet when none is given.
///
/// Each cell answers as:
///
/// - `Text`: the cell's string, as the records spell it — a shared string
///   or the cell's own;
/// - `Boolean`: a boolean cell;
/// - `Number`: a numeric cell's stored number, with the number format of
///   its style — a built-in format by its id, under 164; a custom one by
///   its code — so that the caller can read a date or a time by it;
/// - `Error`: an error cell, by the text the sheet shows.
///
/// A styled empty cell is not in the grid. A formula is never evaluated:
/// its cached value answers — a number, a text, a boolean or an error —
/// and a formula whose cached value is a blank string leaves no cell. A
/// cell written twice keeps its last record.
///
/// Raises `InvalidOperation` for a `sheet` outside the workbook, naming
/// the position and the count. Raises `Unsupported` for a sheet substream
/// whose BOF record declares another BIFF version than 8. Raises
/// `ParseError`, naming the byte, for a sheet whose BOF record is not
/// where the workbook globals placed it, for a record cut short or
/// shorter than its kind needs, for a cell outside the sheet, for a style,
/// a shared string or a number format the workbook does not hold, for a
/// string the records do not hold or that is not well-formed UTF-16, for
/// an error code or a cached value the format does not name, for a
/// formula's string not followed by a STRING record, and for a sheet that
/// ends before its EOF record.
pub fn XlsBook::grid(
  self : XlsBook,
  sheet~ : Int32 = 0,
) -> XlsGrid raise @types.DataError {
  let index = sheet
  let count = self.globals.sheets.length()
  if index < 0 || index >= count {
    raise no("sheet \{index}: the workbook holds \{count} sheets")
  }
  let held = read_sheet(self.stream, self.globals, index)
  XlsGrid::{ from_1904: self.globals.date_1904, held, }
}

///|
/// Open an `.xls` workbook: its compound file read, and its workbook
/// globals parsed.
///
/// Raises `Unsupported` when the bytes are not an `.xls` workbook — no
/// compound file's signature opens them, or the compound file holds no
/// stream named Workbook or Book — for a compound file whose byte order,
/// version, sector size or mini sector size this reader does not read,
/// for an encrypted workbook (a FILEPASS record), and for a BOF record of
/// another BIFF version than 8. Raises `ParseError`, naming the byte,
/// when the compound file or the workbook globals are malformed: a header
/// or a record the file cuts short, a directory entry whose name length
/// no name has, a table or a chain naming a sector the file does not
/// hold, a chain that loops or ends before the sectors a stream needs, a
/// stream larger than the file, a stream that does not open with a BOF
/// record of the workbook globals, a sheet placed outside the workbook
/// stream, and a shared string table whose records do not hold the
/// strings its count names.
pub fn xls_open(bytes : Bytes) -> XlsBook raise @types.DataError {
  let stream = workbook_stream(bytes)
  { stream, globals: parse_globals(stream), }
}
