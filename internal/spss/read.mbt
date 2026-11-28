///|
/// The family a variable's print format names, by its type code. The
/// date formats — `DATE`, `ADATE`, `EDATE`, `JDATE`, `SDATE`, `QYR`,
/// `MOYR`, `WKYR` — and the datetime formats — `DATETIME`, `YMDHMS` —
/// hold seconds since midnight preceding 14 October 1582; the time
/// formats — `TIME`, `DTIME`, `MTIME` — hold seconds since midnight.
/// `WKDAY` and `MONTH` hold a small whole number, the weekday or the
/// month, and every other format a plain number.
priv enum Family {
  Plain
  Date
  DateTime
  TimeOfDay
}

///|
/// The family `format`, a print format's type code, names.
fn family(format : Int32) -> Family {
  match format {
    20 | 23 | 38 | 24 | 39 | 29 | 28 | 30 => Date
    22 | 41 => DateTime
    21 | 25 | 40 => TimeOfDay
    _ => Plain
  }
}

///|
/// The microseconds between 14 October 1582 and 1970-01-01: what a
/// datetime's seconds since the former leave to spell microseconds
/// since the latter.
const EPOCH_MICROS : Int64 = 12219379200000000L

///|
/// The days since 1970-01-01 a date-format cell names, when its number
/// — seconds since 14 October 1582 — is a whole number of days the
/// library can hold; `None` when it is not, and the column stays a
/// number.
fn whole_days(seconds : Double) -> Int64? {
  if seconds % 86400.0 != 0.0 {
    return None
  }
  let days = seconds / 86400.0
  if days < -9000000000000000000.0 || days > 9000000000000000000.0 {
    return None
  }
  Some(days.to_int64() - 141428L)
}

///|
/// The microseconds a datetime- or time-format cell names, when its
/// seconds are an exact whole number of microseconds the library can
/// hold: the number times a million, in double arithmetic, is whole,
/// and divided by a million gives the number back. `None` when they are
/// not, and the column stays a number.
fn whole_micros(seconds : Double) -> Int64? {
  let micros = seconds * 1000000.0
  if micros != micros.floor() || micros / 1000000.0 != seconds {
    return None
  }
  if micros < -9000000000000000000.0 || micros > 9000000000000000000.0 {
    return None
  }
  Some(micros.to_int64())
}

///|
/// Whether a number lies in one of a variable's missing ranges, ends
/// included; a discrete missing value is a range of one number.
fn in_ranges(value : Double, ranges : Array[Double]) -> Bool {
  let mut range = 0
  while range + 1 < ranges.length() {
    if value >= ranges[range] && value <= ranges[range + 1] {
      return true
    }
    range += 2
  }
  false
}

///|
/// Whether a string is one of a variable's declared missing values.
fn is_missing(text : String, missing : Array[String]) -> Bool {
  for value in missing {
    if value == text {
      return true
    }
  }
  false
}

///|
/// Read an SPSS system file — the `.sav` layout and its
/// zlib-compressed `.zsav` twin — from `bytes`: the dictionary, then
/// the data record, uncompressed, bytecode-compressed or
/// zlib-compressed alike.
///
/// Answers the columns in file order, each named as the file spells it
/// (its long name, where the dictionary gives one), and the case count
/// the header declares — or, when the header declares none, the count
/// read from the data.
///
/// Each cell reads as:
///
/// - a numeric variable under any format but a date, datetime or time
///   format: `Float`, the file's IEEE 754 number bit for bit;
/// - a numeric variable under a date format: `Date`, days since
///   1970-01-01, when every present cell is a whole number of days (the
///   file counts seconds since 14 October 1582);
/// - a numeric variable under a datetime format: `Timestamp`,
///   microseconds since 1970-01-01, when every present cell is an exact
///   whole number of microseconds;
/// - a numeric variable under a time format: `Timestamp`, the seconds
///   since midnight as microseconds on 1970-01-01, under the same rule;
///   one cell that is not leaves its whole column `Float`, the numbers
///   as stored;
/// - a string variable, however many eight-byte segments or very long
///   string segments it spans: `String`, its trailing blanks cut — an
///   all-blank cell is the empty string, never missing.
///
/// The system-missing value, and a cell the variable declares missing
/// (up to three values, or a range and a value), read as null. Value
/// labels are not applied: there is no categorical dtype to carry them.
/// Names, labels and string cells decode in the encoding the file
/// declares: UTF-8, Latin-1 or windows-1252.
///
/// Raises `Unsupported`, naming what it is, for a file this reader does
/// not read — a signature that is not a system file's, an encrypted or
/// EBCDIC file, a compression code or bias, a floating-point format, a
/// character encoding or a variable type it does not decode. Raises
/// `ParseError`, naming the byte, for bytes that contradict the layout:
/// a record cut short, a count or length the file cannot hold, a case
/// count the data cannot hold, a stream of codes or a zlib block that
/// breaks off, and text that is not well formed in its encoding.
pub fn read_spss_frame(
  bytes : Bytes,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let c = Cursor::{ bytes, pos: 0, big: false, big_float: false, }
  let dict = read_dictionary(c)
  let data = read_data(c, dict)
  (build_columns(dict, data), data.rows)
}

///|
/// The columns of the data record, in dictionary order: one column a
/// variable, or the segments of a very long string joined into the
/// width its record declares.
fn build_columns(
  dict : Dictionary,
  data : Data,
) -> Array[(String, @series.Series)] raise @types.DataError {
  let units = row_units(dict.slots)
  let columns : Array[(String, @series.Series)] = []
  let mut offset = 0L
  for index, slot in dict.slots {
    if slot.owner >= 0 {
      offset += slot.octets.to_int64()
      continue
    }
    if slot.width == 0 {
      columns.push(
        (slot.name, numeric_column(slot, numbers_of(dict, slot, data, offset))),
      )
      offset += 1L
      continue
    }
    let cells : Array[String?] = []
    for row in 0..<data.rows {
      let base = row.to_int64() * units + offset
      let raw : Array[Byte] = []
      if slot.length > 0L {
        let count = ((slot.length + 251L) / 252L).to_int()
        let mut at = base
        for k in 0..<count {
          gather(
            raw,
            data.bytes,
            (at * 8L).to_int(),
            segment_used(slot.length, k),
          )
          at += dict.slots[index + k].octets.to_int64()
        }
      } else {
        gather(raw, data.bytes, (base * 8L).to_int(), slot.width)
      }
      let text = cell_text(
        raw,
        dict.encoding,
        "row \{row + 1}, column \"\{slot.name}\"",
      )
      if is_missing(text, slot.missing) {
        cells.push(None)
      } else {
        cells.push(Some(text))
      }
    }
    columns.push(
      (slot.name, @series.Series::from_string_options(slot.name, cells)),
    )
    offset += slot.octets.to_int64()
  }
  columns
}

///|
/// The bytes of one string cell, from `start` and `count` long, with a
/// NUL byte dropped.
fn gather(
  out : Array[Byte],
  data : Bytes,
  start : Int32,
  count : Int32,
) -> Unit {
  let stop = start + count
  for i in start..<stop {
    if data[i].to_int() != 0 {
      out.push(data[i])
    }
  }
}

///|
/// A numeric variable's cells: the eight bytes of its unit in each case,
/// null for the system-missing value and for a value its variable
/// declares missing.
fn numbers_of(
  dict : Dictionary,
  slot : Slot,
  data : Data,
  offset : Int64,
) -> Array[Double?] {
  let units = row_units(dict.slots)
  let values : Array[Double?] = []
  for row in 0..<data.rows {
    let bits = bits_at(
      data.bytes,
      ((row.to_int64() * units + offset) * 8L).to_int(),
      dict.big_float,
    )
    if bits == dict.sysmis {
      values.push(None)
    } else {
      let value = bits.reinterpret_as_double()
      if in_ranges(value, slot.ranges) {
        values.push(None)
      } else {
        values.push(Some(value))
      }
    }
  }
  values
}

///|
/// A numeric variable's column: under a date, datetime or time format
/// the converted kind when every present cell converts, and `Float`
/// with the stored numbers otherwise.
fn numeric_column(slot : Slot, values : Array[Double?]) -> @series.Series {
  match family(slot.format) {
    Plain => floats(slot.name, values)
    Date => date_column(slot.name, values)
    DateTime => clock_column(slot.name, values, EPOCH_MICROS)
    TimeOfDay => clock_column(slot.name, values, 0L)
  }
}

///|
/// A `Float` column of the stored numbers.
fn floats(name : String, values : Array[Double?]) -> @series.Series {
  @series.Series::from_float_options(name, values)
}

///|
/// A date format's column: `Date` when every present cell is a whole
/// number of days, `Float` with the stored numbers otherwise.
fn date_column(name : String, values : Array[Double?]) -> @series.Series {
  let days : Array[Int64?] = []
  for value in values {
    if value is Some(seconds) {
      match whole_days(seconds) {
        Some(day) => days.push(Some(day))
        None => return floats(name, values)
      }
    } else {
      days.push(None)
    }
  }
  @series.Series::from_date_options(name, days)
}

///|
/// A datetime or time format's column: `Timestamp` when every present
/// cell is an exact whole number of microseconds, `Float` with the
/// stored numbers otherwise. `epoch` is what the microseconds since
/// 14 October 1582 leave out to spell microseconds since 1970-01-01.
fn clock_column(
  name : String,
  values : Array[Double?],
  epoch : Int64,
) -> @series.Series {
  let micros : Array[Int64?] = []
  for value in values {
    if value is Some(seconds) {
      match whole_micros(seconds) {
        Some(count) => micros.push(Some(count - epoch))
        None => return floats(name, values)
      }
    } else {
      micros.push(None)
    }
  }
  @series.Series::from_timestamp_options(name, micros)
}
