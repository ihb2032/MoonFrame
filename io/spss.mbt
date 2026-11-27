// The SPSS system-file interchange — a native reader over the codec in
// `internal/spss` (the file header, the dictionary's records with the
// variables' print formats and declared missing values, and the cases —
// plain, bytecode-compressed, or inside a zlib stream). The format is read
// only: nothing is written.

///|
/// Read an SPSS system file into a frame — the file's variables as the
/// columns, in the file's order. Raises the errors `parse_spss` states; a
/// path that cannot be read raises `IoError`.
pub fn read_spss(path : String) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_spss(bytes)
}

///|
/// Parse an SPSS system file's bytes into a frame — a `.sav` file, or its
/// zlib-compressed `.zsav` form — the file's variables as the columns in the
/// file's order, each named as the file spells it (its long name, where the
/// dictionary gives one). A file reads in either byte order, its cases plain,
/// bytecode-compressed or inside a zlib stream.
///
/// The columns a file's variables read as:
///
/// - A numeric variable → `Float`, its IEEE 754 number bit for bit: an
///   infinity stays, and no number is missing but the system-missing value.
/// - A numeric variable under a date format (`DATE`, `ADATE`, `EDATE`,
///   `JDATE`, `SDATE`, `QYR`, `MOYR`, `WKYR`) → `Date`, days since
///   1970-01-01 — only while every present cell is a whole number of days;
///   under a datetime format (`DATETIME`, `YMDHMS`) → `Timestamp`,
///   microseconds since 1970-01-01; under a time format (`TIME`, `DTIME`,
///   `MTIME`) → `Timestamp`, the seconds since midnight as microseconds on
///   1970-01-01, the library having no time-of-day type, so the cell still
///   prints as a clock reading. One cell that is not leaves its whole column
///   `Float`, the numbers as stored. The file counts a date and a datetime
///   in seconds since 14 October 1582.
/// - A string variable → `String`, its trailing blanks cut, however many
///   eight-byte segments it spans; an all-blank cell is the empty string,
///   never a missing one.
/// - The system-missing value, and a cell the variable declares missing —
///   up to three values, or a range and a value — read as null.
/// - Value labels are not applied: a labelled variable reads as the numbers
///   it stores.
/// - Names and text decode in the encoding the file declares: UTF-8,
///   Latin-1 or windows-1252. The nominal ASCII codes read as windows-1252,
///   an ASCII superset, and a file declaring nothing as UTF-8.
///
/// A file of no case reads as its columns, empty; a file of no variable
/// refuses, a case having no size.
///
/// Raises `Unsupported`, naming what it is, for a file this reader does not
/// read: a signature that is not a system file's, an encrypted or an EBCDIC
/// file, a compression code, a floating-point representation or a compression
/// bias other than IEEE 754 and 100, a character encoding, or a variable type
/// it does not decode. Raises `ParseError` (`Message`), naming the byte, for
/// bytes that contradict the layout: a record cut short, a count or a length
/// the file cannot hold, a case count the data cannot hold, a stream of codes
/// or a zlib block that breaks off, and text that is not well formed in its
/// encoding.
pub fn parse_spss(bytes : Bytes) -> @frame.DataFrame raise @types.DataError {
  let (columns, _) = @spss.read_spss_frame(bytes)
  @frame.DataFrame::DataFrame(columns.map(pair => pair.1))
}
