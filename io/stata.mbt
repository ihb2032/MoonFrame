// The Stata dataset interchange — a native reader and writer over the
// codec in `internal/stata` (the binary header of releases 113 to 116,
// the tagged header of 117 to 119, the row-major data block, and the
// long-string table). Projection is pushed into the read.

///|
/// Write a frame as one Stata dataset: release 118, little-endian, every
/// column under its own name. Raises `InvalidOperation` for a column
/// whose name the format forbids (one to 32 of ASCII letters, digits and
/// `_`, not opening with a digit, not a word the Stata language reserves,
/// not repeated), and for a cell the format cannot carry — an integer too
/// large for the `double` storage to hold exactly, an infinite float, a
/// date or a timestamp outside its storage, a string cell holding a lone
/// UTF-16 surrogate; `Unsupported` for a `Duration`, `Decimal`, `List` or
/// `Struct` column; `IoError` for a path that cannot be written. Nothing
/// is renamed.
///
/// A round trip is not the identity: a `Bool` column reads back as `Int`
/// 0 / 1, an `Int` column with a cell past the `long` storage as `Float`,
/// a NaN as missing, a missing string cell as the empty string, and a
/// `Null` column as an all-missing `Float` column. The same frame writes
/// the same file.
pub fn write_stata(
  df : @frame.DataFrame,
  path : String,
) -> Unit raise @types.DataError {
  let columns = df.column_series()
  let bytes = @stata.write_stata_bytes(columns, height=df.nrows())
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Read a Stata dataset into a frame — the file's variables as the
/// columns, in the file's order. Raises the errors `parse_stata` states;
/// a path that cannot be read raises `IoError`.
pub fn read_stata(
  path : String,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_stata(bytes, projection?)
}

///|
/// Parse Stata dataset bytes into a frame — the string-level entry's
/// binary counterpart (what `read_stata` hands the codec, exposed for
/// in-memory bytes).
///
/// Releases 113 to 119 read, in either byte order; any other release
/// raises `Unsupported`, naming it. `projection` keeps only the variables
/// it names, in the file's order: a name the file does not carry builds no
/// column, and the rows stay. A variable it leaves out is never read into
/// a cell.
///
/// The columns a file's variables read as:
///
/// - `byte`, `int` and `long` → `Int`; `float` and `double` → `Float`. A
///   numeric cell outside its storage's valid range is missing — the 27
///   missing codes (`.` and `.a` to `.z`) and whatever else the range
///   excludes.
/// - A variable whose display format opens a date family — `%td`, a count
///   of days, or `%tc` / `%tC`, a count of milliseconds — reads as `Date`
///   or `Timestamp`; under `float` or `double` only while every present
///   cell is a whole number. Every other format leaves its column a
///   number.
/// - `str#` and `strL` → `String`, where an empty string is an empty cell
///   and never a missing one. Text is Latin-1 before release 118 and UTF-8
///   from it on, where bytes that are not well-formed UTF-8 read as
///   Latin-1, string by string.
/// - The value-label table, the characteristics, the sort list, the
///   dataset label and the timestamp are not applied to any cell: a
///   labelled variable reads as the numbers it stores.
///
/// Raises `ParseError` (`Message`) for bytes that contradict the layout —
/// a file that ends before a field, a section or the data block its own
/// counts describe, that carries a tag or a byte order the layout does not
/// know, or a long-string cell whose key names no record — naming the byte
/// offset, or the row and column, where it fails. Raises `Unsupported` for
/// a variable type code the reader does not read, or a long-string cell
/// that holds binary data.
pub fn parse_stata(
  bytes : Bytes,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let (columns, nrows) = @stata.read_stata_frame(bytes, projection?)
  // A lenient projection that matches no variable still reports the file's
  // rows — the `N×0` shape the text readers' projections yield, not a
  // collapse to zero.
  if columns.length() == 0 {
    @frame.DataFrame::from_parts([], nrows)
  } else {
    @frame.DataFrame::DataFrame(columns.map(pair => pair.1))
  }
}
