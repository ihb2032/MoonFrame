// Reading a Version 5 transport file: the header records, the NAMESTRs,
// the observations, and the column each variable becomes.

///|
/// Read the SAS Transport (XPORT) Version 5 file held in `bytes`: its
/// columns in file order, each named as the file spells the variable and
/// holding its observations, and the number of observations the file
/// holds.
///
/// A numeric variable reads as `Float`, and as a `Date` or `Timestamp`
/// when a display format of the date, time or datetime family is
/// attached to it and every present cell is a whole number of the
/// dtype's unit: days since the Unix epoch under a date format
/// (`DATE`, `MMDDYY`, `YYMMDD`, …), seconds since midnight as
/// microseconds on 1970-01-01 under a time format (`TIME`, `HHMM`,
/// `TOD`, …), and seconds since the Unix epoch as microseconds under a
/// datetime format (`DATETIME`, `DATEAMPM`, …). One cell that is not
/// leaves the whole column `Float`, the raw numbers. A numeric cell's
/// IBM floating-point value converts exactly whenever a double holds it
/// exactly, and to the nearest double otherwise. The 28 missing values
/// (`.`, `._`, `.A` to `.Z`) read as null.
///
/// A character variable reads as `String`: its bytes are read as UTF-8,
/// the blanks that pad the cell are cut, and a cell of nothing but
/// blanks is the empty string.
///
/// The file records no observation count. The observations run from the
/// observation header record to the end of the file, and a writer pads
/// them with blanks to a whole 80-byte record, so the last byte that is
/// not a blank ends the last observation. A file whose last observations
/// are nothing but blank character cells cannot be told from that
/// padding, and reads without them.
///
/// Raises `Unsupported`, naming the byte, for a file that is not a
/// Version 5 transport file: another library header record (a CPORT
/// file, Version 8 or 9), another member header record, or a variable
/// whose type is neither numeric nor character. Raises `ParseError`,
/// naming the byte, for bytes that contradict the layout: a record the
/// file cuts short, a header record that is not the one the layout
/// spells, a count or a length the file cannot hold, a numeric variable
/// that is not 2 to 8 bytes wide, character data that is not well-formed
/// UTF-8, and observations that do not end on a record boundary or do
/// not hold a whole number of rows.
pub fn read_xport_frame(
  bytes : Bytes,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let layout = read_layout(bytes)
  let count = observation_count(bytes, layout)
  let columns : Array[(String, @series.Series)] = []
  for variable in layout.variables {
    columns.push((variable.name, read_column(bytes, layout, variable, count)))
  }
  (columns, count)
}

///|
/// The error for a library header record that is not Version 5's: what
/// the record names, when it names a format at all.
fn library_refusal(bytes : Bytes) -> @types.DataError {
  if record_contains(bytes, 0, "**COMPRESSED**") {
    return refused(
      0L, "the library header record marks a CPORT file, which is not a transport file",
    )
  }
  let kind = field_text(bytes, 20, 8)
  if kind == "LIBV8" || kind == "LIBV9" {
    return refused(
      0L,
      "the library header record names \{kind}, a later version of the transport format, and this reader reads Version 5 files",
    )
  }
  refused(
    0L, "the library header record is not the transport format's, so the file is not an XPORT file",
  )
}

///|
/// Read the header records and the NAMESTRs: the file's variables and
/// where its observations start. Every record and every count is checked
/// against the bytes the file holds before it is used.
fn read_layout(bytes : Bytes) -> Layout raise @types.DataError {
  // The library's header records.
  need(bytes, 0L, RECORD.to_int64(), "the library header record")
  if !record_is(bytes, 0, LIBRARY_RECORD) {
    raise library_refusal(bytes)
  }
  need(
    bytes,
    RECORD.to_int64(),
    2L * RECORD.to_int64(),
    "the library's description records",
  )
  if !record_opens_with(bytes, RECORD, "SAS     SAS     SASLIB") {
    raise bad(
      RECORD.to_int64(),
      "the record after the library header record does not open with \"SAS     SAS     SASLIB\"",
    )
  }
  // The member's header records.
  need(
    bytes,
    3L * RECORD.to_int64(),
    2L * RECORD.to_int64(),
    "the member header record and the descriptor header record",
  )
  let member_at = 3 * RECORD
  let namestr_length = if record_opens_with(bytes, member_at, MEMBER_RECORD) &&
    record_opens_with(bytes, member_at + 78, "  ") {
    let spelled = record_number(bytes, member_at, 68, 10)
    if spelled < 88L || spelled > NAMESTR_BYTES.to_int64() {
      raise bad(
        (member_at + 68).to_int64(),
        "the NAMESTR length is spelled \{spelled}, and the layout's is 88 to \{NAMESTR_BYTES}",
      )
    }
    spelled.to_int()
  } else {
    let kind = field_text(bytes, member_at + 20, 8)
    if kind == "MEMBV8" || kind == "MEMBV9" {
      raise refused(
        member_at.to_int64(),
        "the member header record names \{kind}, a later version of the transport format, and this reader reads Version 5 files",
      )
    }
    raise refused(
      member_at.to_int64(),
      "the member header record is not the transport format's",
    )
  }
  let descriptor = 4 * RECORD
  if !record_is(bytes, descriptor, DESCRIPTOR_RECORD) {
    let kind = field_text(bytes, descriptor + 20, 8)
    if kind == "DSCPTV8" || kind == "DSCPTV9" {
      raise refused(
        descriptor.to_int64(),
        "the descriptor header record names \{kind}, a later version of the transport format, and this reader reads Version 5 files",
      )
    }
    raise refused(
      descriptor.to_int64(),
      "the descriptor header record is not the transport format's",
    )
  }
  // The member's description records, then the NAMESTR header record.
  need(
    bytes,
    5L * RECORD.to_int64(),
    3L * RECORD.to_int64(),
    "the member's description records and the NAMESTR header record",
  )
  let namestr_header = 7 * RECORD
  if !record_opens_with(bytes, namestr_header, NAMESTR_RECORD) {
    raise bad(
      namestr_header.to_int64(),
      "the NAMESTR header record does not open with \"HEADER RECORD*******NAMESTR HEADER RECORD!!!!!!!\"",
    )
  }
  let count = record_number(bytes, namestr_header, 48, 10)
  // The NAMESTRs fill whole records, and the observation header record
  // follows them: the file must hold both before one NAMESTR is read.
  let spelled_bytes = count * namestr_length.to_int64()
  let area = (spelled_bytes + RECORD.to_int64() - 1L) /
    RECORD.to_int64() *
    RECORD.to_int64()
  need(
    bytes,
    NAMESTR_START,
    area + RECORD.to_int64(),
    "\{count} NAMESTRs of \{namestr_length} bytes and the observation header record",
  )
  let observation_header = (NAMESTR_START + area).to_int()
  if !record_is(bytes, observation_header, OBSERVATION_RECORD) {
    raise bad(
      observation_header.to_int64(),
      "the observation header record does not follow the NAMESTRs",
    )
  }
  let variables : Array[Variable] = []
  let mut position = 0L
  for index in 0L..<count {
    let at = (NAMESTR_START + index * namestr_length.to_int64()).to_int()
    let variable = read_variable(bytes, at, position)
    variables.push(variable)
    position += variable.width.to_int64()
  }
  {
    variables,
    data_start: NAMESTR_START + area + RECORD.to_int64(),
    row_width: position,
  }
}

///|
/// The variable the NAMESTR at `at` describes, which starts `position`
/// bytes into an observation. `at` is the start of the `namestr_length`
/// bytes the file holds for it, at least 88.
fn read_variable(
  bytes : Bytes,
  at : Int32,
  position : Int64,
) -> Variable raise @types.DataError {
  let kind = be16(bytes, at)
  if kind != 1 && kind != 2 {
    raise refused(
      at.to_int64(),
      "a NAMESTR names variable type \{kind}, which is neither numeric (1) nor character (2)",
    )
  }
  let numeric = kind == 1
  let width = be16(bytes, at + 4)
  let name = match
    decode_utf8(bytes, at + 8, trimmed_length(bytes, at + 8, LONGEST_NAME)) {
    Ok(text) => text
    Err(offset) =>
      raise bad(
        offset.to_int64(),
        "a variable's name holds bytes that are not well-formed UTF-8",
      )
  }
  if numeric {
    if width < 2 || width > 8 {
      raise bad(
        (at + 4).to_int64(),
        "the numeric variable \"\{name}\" is \{width} bytes wide, and a numeric variable is 2 to 8 bytes",
      )
    }
  } else if width < 1 {
    raise bad(
      (at + 4).to_int64(),
      "the character variable \"\{name}\" is \{width} bytes wide, and a character variable is at least 1 byte",
    )
  }
  let family = if numeric {
    format_family(field_text(bytes, at + 56, LONGEST_NAME))
  } else {
    Number
  }
  { name, numeric, width, position, family, }
}

///|
/// How many observations the file holds after its header: zero when
/// there is no variable. The observations end at the last byte that is
/// not a blank, since a writer pads the last record with blanks.
fn observation_count(
  bytes : Bytes,
  layout : Layout,
) -> Int32 raise @types.DataError {
  let length = bytes.length().to_int64()
  let data = length - layout.data_start
  let over = data % RECORD.to_int64()
  if over != 0L {
    raise bad(
      length,
      "the observations end at byte \{length}, \{over} bytes past the last 80-byte record boundary",
    )
  }
  let mut last = length - 1L
  while last >= layout.data_start && bytes[last.to_int()] == b' ' {
    last -= 1L
  }
  if last < layout.data_start {
    return 0
  }
  if layout.variables.length() == 0 {
    raise bad(
      last, "the file holds no variable, and a byte that is not a blank lies past its observation header record",
    )
  }
  let into = last - layout.data_start
  // Every observation is at least one byte wide, so the count cannot
  // pass the file's own size, which a 32-bit length already bounds.
  let count = into / layout.row_width + 1L
  if count * layout.row_width > data {
    raise bad(
      last,
      "a byte that is not a blank lies \{into % layout.row_width} bytes into the partial observation after the last whole one",
    )
  }
  count.to_int()
}

///|
/// The bits of the numeric variable's cell in observation `row`. The
/// cell lies inside the bytes: the observation count showed that every
/// observation ends before the file does, and a variable's position and
/// width lie inside the observation.
fn cell_bits(
  bytes : Bytes,
  layout : Layout,
  variable : Variable,
  row : Int32,
) -> IbmBits {
  let at = layout.data_start +
    row.to_int64() * layout.row_width +
    variable.position
  ibm_bits(bytes, at.to_int(), variable.width)
}

///|
/// The column the variable's observations become, under its own name.
fn read_column(
  bytes : Bytes,
  layout : Layout,
  variable : Variable,
  count : Int32,
) -> @series.Series raise @types.DataError {
  if variable.numeric {
    return read_numbers(bytes, layout, variable, count)
  }
  let cells : Array[String?] = []
  for row in 0..<count {
    let at = layout.data_start +
      row.to_int64() * layout.row_width +
      variable.position
    let start = at.to_int()
    match
      decode_utf8(bytes, start, trimmed_length(bytes, start, variable.width)) {
      Ok(text) => cells.push(Some(text))
      Err(offset) =>
        raise bad(
          offset.to_int64(),
          "the character variable \"\{variable.name}\" holds bytes that are not well-formed UTF-8",
        )
    }
  }
  @series.Series::from_string_options(variable.name, cells)
}

///|
/// The column a numeric variable's observations become. The numbers are
/// read once as doubles; under a date, time or datetime format they are
/// then read again as counts of the dtype's unit, and the first cell
/// that is not a whole count leaves the column the doubles.
fn read_numbers(
  bytes : Bytes,
  layout : Layout,
  variable : Variable,
  count : Int32,
) -> @series.Series {
  let numbers : Array[Double?] = []
  for row in 0..<count {
    let bits = cell_bits(bytes, layout, variable, row)
    numbers.push(if bits.is_missing() { None } else { Some(bits.to_double()) })
  }
  match variable.family {
    Number => @series.Series::from_float_options(variable.name, numbers)
    Days => {
      let days : Array[Int64?] = []
      for row in 0..<count {
        let bits = cell_bits(bytes, layout, variable, row)
        if bits.is_missing() {
          days.push(None)
        } else {
          match bits.to_days() {
            Ok(value) => days.push(Some(value - SAS_EPOCH_DAYS))
            Err(_) =>
              return @series.Series::from_float_options(variable.name, numbers)
          }
        }
      }
      @series.Series::from_date_options(variable.name, days)
    }
    Clock | Instant => {
      let micros : Array[Int64?] = []
      for row in 0..<count {
        let bits = cell_bits(bytes, layout, variable, row)
        if bits.is_missing() {
          micros.push(None)
        } else {
          match bits.to_micros() {
            Ok(value) =>
              micros.push(
                Some(
                  if variable.family is Instant {
                    value - SAS_EPOCH_MICROS
                  } else {
                    value
                  },
                ),
              )
            Err(_) =>
              return @series.Series::from_float_options(variable.name, numbers)
          }
        }
      }
      @series.Series::from_timestamp_options(variable.name, micros)
    }
  }
}
