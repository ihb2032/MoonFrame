// The SAS transport interchange — a native reader and writer over the
// codec in `internal/xport` (the Version 5 header records, the NAMESTR
// descriptors, the row-major observations, and the IBM floating point a
// numeric cell is spelled in).

///|
/// Write a frame as one SAS transport file: Version 5, big-endian, every
/// column under its own name. Raises `InvalidOperation` for a column whose
/// name the format does not hold (one to eight of ASCII letters, digits
/// and `_`, opening on a letter or `_`; two that differ only in case are
/// one variable), and for a cell the format cannot carry — an integer past
/// what a double holds exactly, an infinite float, a timestamp whose
/// microseconds are not a multiple of 15625, a string cell past 200 bytes
/// in UTF-8; `Unsupported` for a `Duration`, `Decimal`, `List` or `Struct`
/// column; `IoError` for a path that cannot be written. A name is written
/// as spelled and never changed.
///
/// A round trip is not the identity: a `Bool` column reads back as
/// `Float` 1.0 / 0.0, an `Int` column as `Float`, a NaN as missing, a
/// missing string cell as the empty string, and a `Null` column as an
/// all-missing `Float` column. The same frame writes the same file.
pub fn write_sas(
  df : @frame.DataFrame,
  path : String,
) -> Unit raise @types.DataError {
  let columns = df.column_series()
  let bytes = @xport.write_xport_bytes(columns, height=df.nrows())
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Read a SAS transport file into a frame — the file's variables as the
/// columns, in the file's order. Raises the errors `parse_sas` states; a
/// path that cannot be read raises `IoError`.
pub fn read_sas(path : String) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_sas(bytes)
}

///|
/// Parse a SAS transport file's bytes into a frame — the string-level
/// entry's binary counterpart (what `read_sas` hands the codec, exposed
/// for in-memory bytes). A Version 5 transport file reads; a later
/// version's, a CPORT file, and a file of another format refuse with
/// `Unsupported`, naming what the first record says.
///
/// The columns a file's variables read as:
///
/// - A numeric variable → `Float`, its IEEE double bit for bit; a
///   character variable → `String`, trailing blanks cut, where an empty
///   string is an empty cell and never a missing one. The 28 missing
///   spellings — `.` and `._` and `.A` to `.Z` — read missing.
/// - A numeric variable under a date format reads as `Date`, under a
///   time or a datetime format as `Timestamp` (a time of day as the
///   instant on the epoch day) — only while every present cell is a whole
///   number of the unit; one cell that is not leaves the whole column
///   `Float`, the raw numbers.
/// - Text is UTF-8; bytes that are not well-formed UTF-8 refuse.
///
/// A file holds one data set here: what follows its observations — a
/// second data set's records included — reads as observations, and the
/// observations end at the last byte that is not a blank, so trailing rows
/// of blank character cells are the file's padding. A file of no variable
/// reads as a frame of no column.
///
/// Raises `ParseError` (`Message`) for bytes that contradict the layout —
/// a record the file cuts short, a header record that is not the
/// layout's, a count or a length the file cannot hold, observations that
/// do not end on a record boundary — naming the byte; and `Unsupported`
/// for a variable type that is neither numeric nor character.
pub fn parse_sas(bytes : Bytes) -> @frame.DataFrame raise @types.DataError {
  let (columns, nrows) = @xport.read_xport_frame(bytes)
  if columns.length() == 0 {
    @frame.DataFrame::from_parts([], nrows)
  } else {
    @frame.DataFrame::DataFrame(columns.map(pair => pair.1))
  }
}
