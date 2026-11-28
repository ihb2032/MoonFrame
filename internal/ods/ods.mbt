// A reader for OpenDocument spreadsheet packages: a ZIP archive whose
// content.xml holds the sheets as table:table elements. It answers each
// sheet's name and the position and typed value of every cell that is not
// empty; the header, the column names and the dtypes are left to the
// caller.

///|
/// One cell's value, by the `office:value-type` the cell carries.
pub(all) enum OdsValue {
  /// A string cell: the text of its paragraphs and nested elements, as
  /// composed.
  Text(String)
  /// A float, a percentage or a currency amount: the number the file stores
  /// (a percentage as the fraction it is, 0.15 for 15 %).
  Number(Double)
  /// A boolean cell: true when the cell's whole text is `TRUE`, false
  /// otherwise.
  Boolean(Bool)
  /// A date with no time of day: days since 1970-01-01.
  Day(Int64)
  /// A date with a time of day: microseconds since 1970-01-01T00:00:00.
  Instant(Int64)
  /// A time of day: microseconds since midnight.
  Time(Int64)
}

///|
/// One non-empty cell of a sheet: where it is, and what it holds.
pub struct OdsCell {
  priv row : Int32
  priv col : Int32
  priv value : OdsValue
}

///|
/// The row the cell is on, counting from 0.
pub fn OdsCell::row(self : OdsCell) -> Int32 {
  self.row
}

///|
/// The column the cell is in, counting from 0.
pub fn OdsCell::col(self : OdsCell) -> Int32 {
  self.col
}

///|
/// The cell's value.
pub fn OdsCell::value(self : OdsCell) -> OdsValue {
  self.value
}

///|
/// One sheet of a workbook: its name and the cells it holds.
pub struct OdsGrid {
  priv name : String
  priv cells : Array[OdsCell]
}

///|
/// The sheet's name, as its `table:name` attribute spells it — the empty
/// string where the table carries none.
fn OdsGrid::name(self : OdsGrid) -> String {
  self.name
}

///|
/// Every cell the sheet holds that is not empty, in row-then-column order:
/// by row, and by column within a row. The array is a fresh copy each time
/// it is asked, so what a caller does with one answer leaves the grid as it
/// was.
pub fn OdsGrid::cells(self : OdsGrid) -> Array[OdsCell] {
  self.cells.copy()
}

///|
/// A workbook opened from its bytes: its package judged, its content.xml
/// decoded and walked once, and every sheet it holds. The sheets are named
/// through `sheets`, and one sheet's cells are read through `grid`.
pub struct OdsBook {
  priv sheets : Array[OdsGrid]
}

///|
/// The workbook's sheets' names, in document order — the empty string
/// where a table carries none. An empty array answers a workbook whose
/// content.xml holds no table.
pub fn OdsBook::sheets(self : OdsBook) -> Array[String] {
  self.sheets.map(sheet => sheet.name())
}

///|
/// One sheet's cells: the sheet at `sheet`, its position in document order
/// counting from 0 — the first when it is absent.
///
/// The grid answers every cell that is not empty, at the row and column the
/// sheet's rows, its cells and their repeat counts give it. The empty cells
/// at the end of a row are dropped, and so is a row holding no value unless
/// a row holding one follows it.
///
/// Raises `InvalidOperation` when `sheet` is negative or past the last
/// sheet, naming the position and the count.
pub fn OdsBook::grid(
  self : OdsBook,
  sheet~ : Int32 = 0,
) -> OdsGrid raise @types.DataError {
  let at = sheet
  if at < 0 || at >= self.sheets.length() {
    let count = self.sheets.length()
    let plural = if count == 1 { "" } else { "s" }
    raise @types.DataError::InvalidOperation(
      "ods: sheet \{at} is out of range: the workbook holds \{count} sheet\{plural}",
    )
  }
  self.sheets[at]
}

///|
/// Open an OpenDocument spreadsheet package.
///
/// `bytes` is an OpenDocument spreadsheet package: a ZIP archive whose
/// `mimetype` entry names the spreadsheet type or, with no such entry, one
/// whose content.xml has the `office:document-content` element as its root.
/// Every sheet is read, once, whatever sheet is asked for afterwards.
///
/// Raises `Unsupported` — each by name — for a package that is not an
/// OpenDocument spreadsheet, for an encrypted entry, for a declared
/// encoding other than UTF-8, and for a value type this reader does not
/// carry. Raises `ParseError` for a broken archive (naming the entry at
/// fault), for a content.xml that is not well-formed or is cut short, for
/// an attribute that does not spell the number, count, date or time it
/// should, and for a repeat count that would make a sheet hold more cells
/// than a budget tied to the package's size; where a byte is to blame, the
/// message names it.
pub fn ods_open(bytes : Bytes) -> OdsBook raise @types.DataError {
  { sheets: read_book(bytes), }
}

///|
/// The workbook a package holds: the package opened and judged, its
/// content.xml decoded and walked.
fn read_book(bytes : Bytes) -> Array[OdsGrid] raise @types.DataError {
  let archive = open_package(bytes)
  let judged_by_root = judge_mimetype(archive)
  let content = content_entry(archive, judged_by_root)
  let document = decode_content(content)
  read_document(document, bytes.length(), judged_by_root)
}
