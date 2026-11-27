// Reading a SAS Version 7/8/9 data set: the header, the pages, the
// columns they describe, and the rows — each column built through the
// series constructor its cells call for.

///|
/// Read the SAS Version 7/8/9 data set — a `sas7bdat` file — held in
/// `bytes`: its columns in file order, each named as the file spells the
/// variable and holding the observation count the file declares.
///
/// A numeric variable reads as `Float`, holding the file's number bit for
/// bit, and as a `Date` or a `Timestamp` when a display format of the
/// date, time or datetime family is attached to it and every present cell
/// is a whole number of the dtype's unit: days since 1970-01-01 under a
/// date format (`DATE`, `MMDDYY`, `YYMMDD`, …), seconds since midnight as
/// microseconds on 1970-01-01 under a time format (`TIME`, `HHMM`, `TOD`,
/// …), and seconds since 1970-01-01 as microseconds under a datetime
/// format (`DATETIME`, `DATEAMPM`, …). One cell that is not leaves the
/// whole column `Float`, the raw numbers. The missing values (`.`, `._`,
/// `.A` to `.Z`) read as null. A variable stored in fewer than eight
/// bytes reads as the number its leading bytes spell.
///
/// A character variable reads as `String`: the trailing blanks and NULs
/// that pad the cell are cut, and a cell of nothing but padding is the
/// empty string, not a missing value.
///
/// Text is decoded as the header's character-set field says: as UTF-8, or
/// — for the single-byte code pages, among them Latin-1, US-ASCII,
/// windows-1252 and windows-1251 — one byte to one character, in a column
/// name as in a cell. A character set this reader does not decode is
/// refused by name.
///
/// Reads files of either byte order, laid out in 32-bit or in 64-bit
/// fields, with or without the header's four bytes of padding, and rows
/// stored plain or compressed with the CHAR or the BINARY method.
///
/// Raises `Unsupported`, naming the byte, for a character set, a column
/// type or a row compression this reader does not decode. Raises
/// `ParseError`, naming the byte, for bytes that contradict the layout:
/// a wrong magic, a header or a page shorter than its own fixed part, a
/// page length the bytes after the header are not a whole number of, a
/// subheader outside its page or before its pointers, a count of rows,
/// columns or pointers the file cannot hold, a reference into text the
/// file does not hold, a column spanning past its row, a compressed row
/// that does not expand to one row, text that is not well-formed UTF-8,
/// and a byte the file's code page leaves undefined.
pub fn read_sas7bdat_frame(
  bytes : Bytes,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let header = read_header(bytes)
  let meta = walk(bytes, header)
  let plan = resolve(bytes, header, meta)
  let stores = read_cells(bytes, header, plan)
  let columns : Array[(String, @series.Series)] = []
  for i, column in plan.columns {
    let name = column.name
    match stores[i] {
      Cells::Texts(cells) =>
        columns.push((name, @series.Series::from_string_options(name, cells)))
      Cells::Numbers(cells) =>
        match family_of(column.format) {
          Family::Number =>
            columns.push(
              (name, @series.Series::from_float_options(name, cells)),
            )
          Family::Days =>
            match column_values(cells, to_day) {
              Ok(days) =>
                columns.push(
                  (name, @series.Series::from_date_options(name, days)),
                )
              Err(_) =>
                columns.push(
                  (name, @series.Series::from_float_options(name, cells)),
                )
            }
          Family::Clock =>
            match column_values(cells, whole_micros) {
              Ok(micros) =>
                columns.push(
                  (name, @series.Series::from_timestamp_options(name, micros)),
                )
              Err(_) =>
                columns.push(
                  (name, @series.Series::from_float_options(name, cells)),
                )
            }
          Family::Instant =>
            match column_values(cells, to_instant) {
              Ok(micros) =>
                columns.push(
                  (name, @series.Series::from_timestamp_options(name, micros)),
                )
              Err(_) =>
                columns.push(
                  (name, @series.Series::from_float_options(name, cells)),
                )
            }
        }
    }
  }
  (columns, plan.row_count.to_int())
}
