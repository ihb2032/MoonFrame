// Writing a Version 5 transport file: the header records, each column's
// NAMESTR, and its observations.

///|
/// The SAS release a file's header records name, as the layout's own
/// example spells it.
const SAS_RELEASE : String = "6.06"

///|
/// The operating system a file's header records name, as the layout's
/// own example spells it.
const SAS_SYSTEM : String = "bsd4.2"

///|
/// The creation and modification timestamp every file carries: the
/// layout holds it as display information, never as a clock. It lies
/// after 1970 in every time zone.
const STAMP : String = "01JAN80:00:00:00"

///|
/// The member name every file carries.
const MEMBER_NAME : String = "DATASET"

///|
/// The display format a `Date` column writes under.
const DATE_FORMAT : String = "DATE"

///|
/// The display format a `Timestamp` column writes under.
const DATETIME_FORMAT : String = "DATETIME"

///|
/// The 64 bits of the number 1.
const ONE : UInt64 = 0x4110000000000000UL

///|
/// The largest magnitude an `Int` cell keeps through a double.
const EXACT_INT : Int64 = 9007199254740992L

///|
/// A bound with room to add an epoch to, well inside a 64-bit count.
const NEAR_LIMIT : Int64 = 9000000000000000000L

///|
/// A `Timestamp` cell's microseconds are a multiple of this when they are
/// a number of seconds a double spells exactly: `10^6 / 64`.
const MICRO_STEP : Int64 = 15625L

///|
/// What the cells of a numeric column count, which decides the bits of
/// each.
priv enum Count {
  Plain
  Days
  Seconds
}

///|
/// One column decided for writing: its variable's bytes, each cell
/// `width` of them, in row order.
priv struct Plan {
  name : String
  numeric : Bool
  format : String
  width : Int32
  data : Array[Byte]
}

///|
/// Write `columns` as a SAS Transport (XPORT) Version 5 file, under each
/// column's own name, and answer the file's bytes. Without `height` the
/// first column's length is the height, and no column means zero;
/// `height` pins the height of a table with no column.
///
/// A `Bool` column writes 1 or 0, a `Date` column its days since
/// 1960-01-01 under the `DATE` format, and a `Timestamp` column its
/// seconds since 1960-01-01 under the `DATETIME` format. An `Int` and a
/// `Float` column write numbers, and a column of dtype `Null` writes
/// missing values. A missing numeric cell writes `.`, and so does a NaN.
/// A `String` column writes a character variable as wide as its longest
/// cell, one byte at least, in UTF-8; a missing cell writes blanks.
/// Variable labels are blanks and the creation and modification
/// timestamps are constants, so the same columns write the same bytes.
/// A name is written as spelled.
///
/// Raises `LengthMismatch` when the columns' lengths disagree, or when
/// `height` disagrees with them. Raises `Unsupported`, naming the column
/// and the dtype, for a column of dtype `Duration`, `Decimal`, `List` or
/// `Struct`. Raises `InvalidOperation`, naming the column, for a name
/// the format does not hold — one to eight ASCII letters, digits or
/// underscores, opening on a letter or an underscore — for two columns
/// whose names differ only in case, and for a cell the format cannot
/// carry: an `Int` past 2^53 in magnitude, a `Float` that is infinite or
/// lies outside `16^-65` to `16^63` in magnitude, a `String` cell longer
/// than 200 bytes in UTF-8 or holding an unpaired surrogate, a `Date` or
/// `Timestamp` too far from the epoch for a 64-bit count or for a double
/// to hold exactly, and a `Timestamp` whose microseconds are not a
/// multiple of 15625 — the file holds seconds as a double, and only a
/// multiple of 1/64 second is one exactly. `InvalidOperation` also
/// answers a negative `height`, and a positive `height` for a table with
/// no column: the format has no place to record it.
pub fn write_xport_bytes(
  columns : Array[@series.Series],
  height? : Int32,
) -> Bytes raise @types.DataError {
  // The caller's array is copied at the boundary: the file is laid out
  // from the codec's own copy, so a later mutation of theirs cannot
  // reach it.
  let own = columns.copy()
  let count = own.length()
  let derived = if count == 0 { 0 } else { own[0].len() }
  for i in 1..<count {
    if own[i].len() != derived {
      raise @types.DataError::LengthMismatch(derived, own[i].len())
    }
  }
  let pinned = match height {
    Some(given) => given
    None => derived
  }
  if pinned < 0 {
    raise @types.DataError::InvalidOperation(
      "xport: the writer was handed a height of \{pinned}, and a file declares no negative observation count",
    )
  }
  if count > 0 && pinned != derived {
    raise @types.DataError::LengthMismatch(derived, pinned)
  }
  if count == 0 && pinned > 0 {
    raise @types.DataError::InvalidOperation(
      "xport: a table with no variable has no place in a transport file for its \{pinned} observations",
    )
  }
  for i in 0..<count {
    let name = own[i].name()
    if !is_variable_name(name) {
      raise @types.DataError::InvalidOperation(
        "xport: cannot write column \{i + 1}: \"\{name}\" is not a name the transport format holds, which is one to eight ASCII letters, digits or underscores opening on a letter or an underscore",
      )
    }
    for earlier in 0..<i {
      if own[earlier].name().compare_ignore_ascii_case(name) == 0 {
        raise @types.DataError::InvalidOperation(
          "xport: cannot write column \{i + 1}: its name \"\{name}\" and column \{earlier + 1}'s name \"\{own[earlier].name()}\" differ only in case, and the transport format holds them as one variable",
        )
      }
    }
  }
  // Every column is encoded before a byte of the file is laid out, so a
  // refusal answers without a half-built file.
  let plans : Array[Plan] = []
  for i in 0..<count {
    plans.push(plan_column(own[i]))
  }
  assemble(plans, pinned)
}

///|
/// The 64 bits of the numeric cell holding the non-zero, finite `value`
/// of column `name` at row `row`. A value outside the magnitudes a
/// numeric cell holds raises `InvalidOperation`, naming the column, the
/// row and the value.
fn number_bits(
  name : String,
  row : Int32,
  value : Double,
) -> UInt64 raise @types.DataError {
  // Both zeros spell plain zero bytes: the layout puts no sign on zero,
  // and a reader mistaking the signed spelling for something else is
  // avoided.
  if value == 0.0 {
    return 0UL
  }
  if !value.is_finite() {
    raise @types.DataError::InvalidOperation(
      "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{value}, and a numeric cell spells no infinity",
    )
  }
  match ibm_bits_of(value) {
    Ok(bits) => bits
    Err(_) =>
      raise @types.DataError::InvalidOperation(
        "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{value}, and a numeric cell holds magnitudes from 16^-65 up to 16^63",
      )
  }
}

///|
/// The bits of the numeric cell holding the `Int` cell `value`. The
/// count keeps its value through a double only up to 2^53 in magnitude.
fn int_bits(
  name : String,
  row : Int32,
  value : Int64,
) -> UInt64 raise @types.DataError {
  if value > EXACT_INT || value < -EXACT_INT {
    raise @types.DataError::InvalidOperation(
      "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{value}, which is past the 2^53 a numeric cell holds exactly",
    )
  }
  number_bits(name, row, value.to_double())
}

///|
/// The bits of the numeric cell holding the `Date` cell `days`, days
/// since the Unix epoch: the file counts its days since 1960-01-01.
fn date_bits(
  name : String,
  row : Int32,
  days : Int64,
) -> UInt64 raise @types.DataError {
  if days > NEAR_LIMIT || days < -NEAR_LIMIT {
    raise @types.DataError::InvalidOperation(
      "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{days} days, too far from the epoch for a file to count",
    )
  }
  let since_sas = days + SAS_EPOCH_DAYS
  if since_sas > EXACT_INT || since_sas < -EXACT_INT {
    raise @types.DataError::InvalidOperation(
      "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{days} days, which is past the 2^53 a numeric cell holds exactly",
    )
  }
  number_bits(name, row, since_sas.to_double())
}

///|
/// The bits of the numeric cell holding the `Timestamp` cell `micros`,
/// microseconds since the Unix epoch: the file counts seconds since
/// 1960-01-01 as a double, so the count must be a number of microseconds
/// that a double spells exactly.
fn timestamp_bits(
  name : String,
  row : Int32,
  micros : Int64,
) -> UInt64 raise @types.DataError {
  if micros > NEAR_LIMIT || micros < -NEAR_LIMIT {
    raise @types.DataError::InvalidOperation(
      "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{micros} microseconds, too far from the epoch for a file to count",
    )
  }
  let since_sas = micros + SAS_EPOCH_MICROS
  if since_sas % MICRO_STEP != 0L {
    raise @types.DataError::InvalidOperation(
      "xport: cannot write column \"\{name}\": the cell at row \{row + 1} holds \{micros} microseconds, and only a multiple of 15625 is a number of seconds a double spells exactly",
    )
  }
  // The quotient is below 2^53, so both divisions are exact.
  number_bits(name, row, (since_sas / MICRO_STEP).to_double() / 64.0)
}

///|
/// Append the eight bytes of the 64 `bits`, most significant first.
fn push_bits(out : Array[Byte], bits : UInt64) -> Unit {
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    out.push((bits >> shift).to_byte())
  }
}

///|
/// The plan for a column whose cells are numbers or counts: a missing
/// cell is `.`, and every other cell is `count` applied to the count it
/// carries.
fn numeric_plan(
  series : @series.Series,
  format : String,
  count : Count,
) -> Plan raise @types.DataError {
  let name = series.name()
  let data : Array[Byte] = []
  for row, cell in series.to_scalars() {
    // A missing cell carries no count, so each rule leaves it to the
    // missing spelling.
    let bits = match count {
      Plain =>
        if cell is @types.Scalar::Int(value) {
          int_bits(name, row, value)
        } else {
          MISSING
        }
      Days =>
        if cell is @types.Scalar::Date(days) {
          date_bits(name, row, days)
        } else {
          MISSING
        }
      Seconds =>
        if cell is @types.Scalar::Timestamp(micros) {
          timestamp_bits(name, row, micros)
        } else {
          MISSING
        }
    }
    push_bits(data, bits)
  }
  { name, numeric: true, format, width: 8, data, }
}

///|
/// The plan for one column: its variable's kind, format, width, and the
/// bytes of every cell.
fn plan_column(series : @series.Series) -> Plan raise @types.DataError {
  let name = series.name()
  match series.dtype() {
    Bool => {
      let data : Array[Byte] = []
      for cell in series.to_scalars() {
        if cell is @types.Scalar::Null {
          push_bits(data, MISSING)
        } else {
          push_bits(data, if cell.as_bool() { ONE } else { 0UL })
        }
      }
      { name, numeric: true, format: "", width: 8, data, }
    }
    Int => numeric_plan(series, "", Plain)
    Float => {
      let data : Array[Byte] = []
      for row, cell in series.to_scalars() {
        if cell is @types.Scalar::Null || cell.as_float().is_nan() {
          push_bits(data, MISSING)
        } else {
          push_bits(data, number_bits(name, row, cell.as_float()))
        }
      }
      { name, numeric: true, format: "", width: 8, data, }
    }
    Date => numeric_plan(series, DATE_FORMAT, Days)
    Timestamp => numeric_plan(series, DATETIME_FORMAT, Seconds)
    Null => {
      let data : Array[Byte] = []
      for _ in 0..<series.len() {
        push_bits(data, MISSING)
      }
      { name, numeric: true, format: "", width: 8, data, }
    }
    String => {
      let texts : Array[Bytes] = []
      let mut width = 1
      for row, cell in series.to_scalars() {
        if cell is @types.Scalar::Null {
          texts.push([])
        } else {
          match utf8_bytes(cell.as_string()) {
            Ok(encoded) => {
              if encoded.length() > LONGEST_TEXT {
                raise @types.DataError::InvalidOperation(
                  "xport: cannot write column \"\{name}\": the String cell at row \{row + 1} is \{encoded.length()} bytes in UTF-8, and a character variable of the Version 5 transport format holds at most \{LONGEST_TEXT}",
                )
              }
              if encoded.length() > width {
                width = encoded.length()
              }
              texts.push(encoded)
            }
            Err(_) =>
              raise @types.DataError::InvalidOperation(
                "xport: cannot write column \"\{name}\": the String cell at row \{row + 1} holds an unpaired surrogate, which has no UTF-8 spelling",
              )
          }
        }
      }
      let data : Array[Byte] = []
      for encoded in texts {
        for byte in encoded {
          data.push(byte)
        }
        for _ in encoded.length()..<width {
          data.push(b' ')
        }
      }
      { name, numeric: false, format: "", width, data, }
    }
    Decimal | Duration | List(_) | Struct(_) =>
      raise @types.DataError::Unsupported(
        "xport: cannot write column \"\{name}\": the transport format does not carry a column of dtype \{series.dtype()}",
      )
  }
}

///|
/// Append the ASCII `text`, one byte a character.
fn push_text(out : Array[Byte], text : String) -> Unit {
  let units = text.code_units()
  for i in 0..<units.length() {
    out.push(units[i].to_int().to_byte())
  }
}

///|
/// Append `count` blanks.
fn push_blanks(out : Array[Byte], count : Int32) -> Unit {
  for _ in 0..<count {
    out.push(b' ')
  }
}

///|
/// Append the two bytes of a NAMESTR's 16-bit `value`, most significant
/// first.
fn push_i16(out : Array[Byte], value : Int32) -> Unit {
  out.push((value >> 8).to_byte())
  out.push(value.to_byte())
}

///|
/// Append `count` zero bytes.
fn push_zeros(out : Array[Byte], count : Int32) -> Unit {
  for _ in 0..<count {
    out.push(b'\x00')
  }
}

///|
/// Append the NAMESTR of one variable: its type, its width, its place
/// among the variables, its name, a blank label, its display format, and
/// the remaining fields, which are zeros or blanks as the layout's own
/// writer leaves them, except the right-justification flag a numeric
/// variable sets and the variable's `position` in an observation.
fn push_namestr(
  out : Array[Byte],
  plan : Plan,
  index : Int32,
  position : Int64,
) -> Unit {
  push_i16(out, if plan.numeric { 1 } else { 2 })
  push_i16(out, 0)
  push_i16(out, plan.width)
  push_i16(out, index + 1)
  push_padded(out, plan.name, LONGEST_NAME)
  push_blanks(out, 40)
  push_padded(out, plan.format, LONGEST_NAME)
  push_i16(out, 0)
  push_i16(out, 0)
  push_i16(out, if plan.numeric { 1 } else { 0 })
  push_i16(out, 0)
  push_blanks(out, 8)
  push_i16(out, 0)
  push_i16(out, 0)
  for shift in [24, 16, 8, 0] {
    out.push(((position >> shift) & 0xFFL).to_byte())
  }
  push_zeros(out, 52)
}

///|
/// Append the two records that name the file's library or its member:
/// "SAS", the two names the layout gives it — the library's own, or the
/// member's name and "SASDATA" — the SAS release, the operating system,
/// 24 blanks and the timestamp; then the timestamp again and 64 blanks.
fn push_owner(out : Array[Byte], first : String, second : String) -> Unit {
  push_padded(out, "SAS", 8)
  push_padded(out, first, 8)
  push_padded(out, second, 8)
  push_padded(out, SAS_RELEASE, 8)
  push_padded(out, SAS_SYSTEM, 8)
  push_blanks(out, 24)
  push_padded(out, STAMP, 16)
  push_padded(out, STAMP, 16)
  push_blanks(out, 64)
}

///|
/// Append blanks until a whole number of records is laid out.
fn pad_record(out : Array[Byte]) -> Unit {
  while out.length() % RECORD != 0 {
    out.push(b' ')
  }
}

///|
/// Lay the file out: the header records, the NAMESTRs, the observation
/// header record, the observations row by row, and the blanks that pad
/// the last record.
fn assemble(plans : Array[Plan], rows : Int32) -> Bytes {
  let out : Array[Byte] = []
  push_text(out, LIBRARY_RECORD)
  push_owner(out, "SAS", "SASLIB")
  push_text(out, MEMBER_RECORD)
  push_digits(out, NAMESTR_BYTES, 10)
  push_blanks(out, 2)
  push_text(out, DESCRIPTOR_RECORD)
  push_owner(out, MEMBER_NAME, "SASDATA")
  push_text(out, NAMESTR_RECORD)
  push_digits(out, plans.length(), 10)
  push_text(out, "00000000000000000000")
  push_blanks(out, 2)
  let mut position = 0L
  for index, plan in plans {
    push_namestr(out, plan, index, position)
    position += plan.width.to_int64()
  }
  pad_record(out)
  push_text(out, OBSERVATION_RECORD)
  for row in 0..<rows {
    for plan in plans {
      for i in 0..<plan.width {
        out.push(plan.data[row * plan.width + i])
      }
    }
  }
  pad_record(out)
  Bytes::from_array(out)
}
