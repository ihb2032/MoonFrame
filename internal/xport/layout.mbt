// The record layout of a transport file: its 80-byte records, the
// NAMESTR that describes each variable, and the display formats that make
// a numeric variable a date, a time or a datetime.

///|
/// One record of a transport file, in bytes.
const RECORD : Int32 = 80

///|
/// The bytes a NAMESTR holds in Version 5. A file may spell a shorter
/// one; every field the reader looks at lies in the first 88 bytes.
const NAMESTR_BYTES : Int32 = 140

///|
/// The first byte of the NAMESTRs.
const NAMESTR_START : Int64 = 640L

///|
/// Days from the transport format's own epoch, 1960-01-01, to the Unix
/// epoch, 1970-01-01.
const SAS_EPOCH_DAYS : Int64 = 3653L

///|
/// Microseconds from 1960-01-01 to the Unix epoch.
const SAS_EPOCH_MICROS : Int64 = 315619200000000L

///|
/// The most characters a variable of the Version 5 transport format
/// holds.
const LONGEST_NAME : Int32 = 8

///|
/// The most bytes a character variable of the Version 5 transport
/// format holds.
const LONGEST_TEXT : Int32 = 200

///|
/// The library header record of a Version 5 file.
const LIBRARY_RECORD : String = "HEADER RECORD*******LIBRARY HEADER RECORD!!!!!!!000000000000000000000000000000  "

///|
/// The member header record up to its NAMESTR length: the first 68
/// bytes.
const MEMBER_RECORD : String = "HEADER RECORD*******MEMBER  HEADER RECORD!!!!!!!00000000000000000160"

///|
/// The descriptor header record.
const DESCRIPTOR_RECORD : String = "HEADER RECORD*******DSCRPTR HEADER RECORD!!!!!!!000000000000000000000000000000  "

///|
/// What the NAMESTR header record opens with; its variable count
/// follows in ten digits.
const NAMESTR_RECORD : String = "HEADER RECORD*******NAMESTR HEADER RECORD!!!!!!!"

///|
/// The observation header record, which the observations follow.
const OBSERVATION_RECORD : String = "HEADER RECORD*******OBS     HEADER RECORD!!!!!!!000000000000000000000000000000  "

///|
/// What a numeric variable's display format makes of its cells: a
/// number, a count of days, a count of seconds since midnight, or a
/// count of seconds since the format's epoch.
priv enum Family {
  Number
  Days
  Clock
  Instant
}

///|
/// One variable as its NAMESTR describes it and the header places it.
priv struct Variable {
  name : String
  numeric : Bool
  width : Int32
  position : Int64
  family : Family
}

///|
/// What the header records say about the file's observations.
priv struct Layout {
  variables : Array[Variable]
  data_start : Int64
  row_width : Int64
}

///|
/// The error for bytes that contradict the layout, naming the byte.
fn bad(offset : Int64, what : String) -> @types.DataError {
  @types.DataError::ParseError(
    @types.ParseErrorDetail::Message("xport: byte \{offset}: \{what}"),
  )
}

///|
/// The error for a file this reader does not read, naming the byte.
fn refused(offset : Int64, what : String) -> @types.DataError {
  @types.DataError::Unsupported("xport: byte \{offset}: \{what}")
}

///|
/// That the file holds `count` bytes from byte `at`, both zero or more:
/// `what` occupies them. A file that ends earlier raises `ParseError`.
fn need(
  bytes : Bytes,
  at : Int64,
  count : Int64,
  what : String,
) -> Unit raise @types.DataError {
  let length = bytes.length().to_int64()
  if at + count > length {
    raise bad(
      at,
      "the file ends at byte \{length} inside \{what} (bytes \{at} to \{at + count - 1L})",
    )
  }
}

///|
/// Whether the record at `at` is exactly `text`, which is 80 characters
/// of ASCII.
fn record_is(bytes : Bytes, at : Int32, text : String) -> Bool {
  let units = text.code_units()
  if units.length() != RECORD {
    false
  } else {
    let mut same = true
    for i in 0..<RECORD {
      if bytes[at + i].to_int() != units[i].to_int() {
        same = false
      }
    }
    same
  }
}

///|
/// Whether the record at `at` opens with the ASCII `text`.
fn record_opens_with(bytes : Bytes, at : Int32, text : String) -> Bool {
  let units = text.code_units()
  let mut same = true
  for i in 0..<units.length() {
    if bytes[at + i].to_int() != units[i].to_int() {
      same = false
    }
  }
  same
}

///|
/// Whether the record at `at` holds the ASCII `text` anywhere.
fn record_contains(bytes : Bytes, at : Int32, text : String) -> Bool {
  let units = text.code_units()
  let last = RECORD - units.length()
  let mut found = false
  for start in 0..<=last {
    let mut same = true
    for i in 0..<units.length() {
      if bytes[at + start + i].to_int() != units[i].to_int() {
        same = false
      }
    }
    if same {
      found = true
    }
  }
  found
}

///|
/// The bytes from `at` for `width`, with the blanks that pad them on the
/// right left out, as text: one character per byte. For a comparison
/// against an ASCII name and for a message.
fn field_text(bytes : Bytes, at : Int32, width : Int32) -> String {
  let chars : Array[Char] = []
  for i in 0..<trimmed_length(bytes, at, width) {
    chars.push(bytes[at + i].to_char())
  }
  String::from_array(chars)
}

///|
/// How many of the `width` bytes from `at` precede the blanks that pad
/// them on the right.
fn trimmed_length(bytes : Bytes, at : Int32, width : Int32) -> Int32 {
  let mut end = width
  while end > 0 && bytes[at + end - 1] == b' ' {
    end -= 1
  }
  end
}

///|
/// The 16-bit big-endian integer at `at`, as a NAMESTR stores one.
fn be16(bytes : Bytes, at : Int32) -> Int32 {
  let value = (bytes[at].to_int() << 8) | bytes[at + 1].to_int()
  if value >= 0x8000 {
    value - 0x10000
  } else {
    value
  }
}

///|
/// The number spelled in the `width` digits from column `from` of the
/// record at `at`. A byte that is not a digit raises `ParseError`,
/// naming it.
fn record_number(
  bytes : Bytes,
  at : Int32,
  from : Int32,
  width : Int32,
) -> Int64 raise @types.DataError {
  let mut value = 0L
  for i in 0..<width {
    let digit = bytes[at + from + i].to_int() - 0x30
    if digit < 0 || digit > 9 {
      raise bad(
        (at + from + i).to_int64(),
        "a count is spelled here in digits, and this byte is not one",
      )
    }
    value = value * 10L + digit.to_int64()
  }
  value
}

///|
/// The display formats whose value is a count of days.
fn day_formats() -> ReadOnlyArray[String] {
  [
    "DATE", "MMDDYY", "DDMMYY", "YYMMDD", "JULIAN", "YYQ", "WEEK", "WEEKDATE", "WEEKDATX",
    "DAY", "NENGO",
  ]
}

///|
/// The display formats whose value is a count of seconds since midnight.
fn clock_formats() -> ReadOnlyArray[String] {
  ["TIME", "HHMM", "MMSS", "HOUR", "TOD"]
}

///|
/// The display formats whose value is a count of seconds since the
/// format's epoch.
fn instant_formats() -> ReadOnlyArray[String] {
  ["DATETIME", "DATEAMPM", "MDYAMPM", "DTDATE", "B8601DT", "B8601DN", "E8601DT"]
}

///|
/// Whether the first `length` code units of `name` spell the ASCII
/// `format`.
fn spells(name : String, length : Int32, format : String) -> Bool {
  let units = name.code_units()
  let wanted = format.code_units()
  if units.length() < length || wanted.length() != length {
    false
  } else {
    let mut same = true
    for i in 0..<length {
      if units[i].to_int() != wanted[i].to_int() {
        same = false
      }
    }
    same
  }
}

///|
/// The family of the display format `name`: a format is matched exactly,
/// with a width written after its name left out (`DATE9` is `DATE`), and
/// upper case as the format's own spelling. A name of no family leaves
/// the cells numbers.
fn format_family(name : String) -> Family {
  let units = name.code_units()
  let mut length = units.length()
  while length > 0 {
    let unit = units[length - 1].to_int()
    if unit < 0x30 || unit > 0x39 {
      break
    }
    length -= 1
  }
  for format in day_formats() {
    if spells(name, length, format) {
      return Days
    }
  }
  for format in clock_formats() {
    if spells(name, length, format) {
      return Clock
    }
  }
  for format in instant_formats() {
    if spells(name, length, format) {
      return Instant
    }
  }
  Number
}
