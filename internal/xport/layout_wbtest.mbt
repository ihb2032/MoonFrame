// Whitebox tests of the record layout's own helpers: the record constants,
// the checked reads of a record's bytes, and the display-format families.

///|
/// The bytes of an ASCII `text`.
fn ascii(text : String) -> Bytes {
  let out : Array[Byte] = []
  for unit in text.code_units() {
    out.push(unit.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// `text` with the character at `at` replaced by `with`.
fn spelled_with(text : String, at : Int32, instead : Char) -> String {
  let out = StringBuilder()
  for i, unit in text.code_units() {
    if i == at {
      out.write_char(instead)
    } else {
      out.write_char(Int32::unsafe_to_char(unit.to_int()))
    }
  }
  out.to_string()
}

///|
test "the record constants are as long as the layout spells them" {
  assert_eq(RECORD, 80)
  assert_eq(LIBRARY_RECORD.code_units().length(), 80)
  assert_eq(DESCRIPTOR_RECORD.code_units().length(), 80)
  assert_eq(OBSERVATION_RECORD.code_units().length(), 80)
  // The member header record up to its ten-digit NAMESTR length.
  assert_eq(MEMBER_RECORD.code_units().length(), 68)
  assert_eq(NAMESTR_RECORD.code_units().length(), 48)
  assert_eq(NAMESTR_BYTES, 140)
  assert_eq(NAMESTR_START, 640L)
  assert_eq(SAS_EPOCH_DAYS, 3653L)
  assert_eq(SAS_EPOCH_MICROS, 315619200000000L)
  assert_eq(LONGEST_NAME, 8)
  assert_eq(LONGEST_TEXT, 200)
}

///|
test "a record is recognised only when all eighty bytes spell the text" {
  let member_record = MEMBER_RECORD + "0000000140  "
  let bytes = ascii(LIBRARY_RECORD + member_record)
  assert_true(record_is(bytes, 0, LIBRARY_RECORD))
  assert_true(record_is(bytes, 80, member_record))
  assert_false(record_is(bytes, 0, member_record))
  assert_false(record_is(bytes, 80, spelled_with(LIBRARY_RECORD, 79, 'X')))
  assert_false(record_is(bytes, 80, spelled_with(member_record, 78, 'X')))
  // A text of another length names no record.
  assert_false(record_is(bytes, 0, MEMBER_RECORD))
  assert_false(record_is(bytes, 0, ""))
  assert_true(record_opens_with(bytes, 0, "HEADER RECORD*******LIBRARY"))
  assert_false(record_opens_with(bytes, 80, "HEADER RECORD*******LIBRARY"))
  assert_true(record_opens_with(bytes, 80, ""))
  assert_true(record_contains(bytes, 0, "LIBRARY HEADER"))
  assert_true(record_contains(bytes, 0, "000000000000000000000000000000"))
  assert_false(record_contains(bytes, 0, "LIBV8"))
  assert_false(record_contains(bytes, 0, LIBRARY_RECORD + " "))
}

///|
test "a record's fields are read as text, as a length, as a number and as a 16-bit integer" {
  let bytes = ascii(LIBRARY_RECORD + MEMBER_RECORD + "0000000140  ")
  assert_eq(field_text(bytes, 20, 8), "LIBRARY")
  assert_eq(field_text(bytes, 20, 8), "LIBRARY")
  assert_eq(field_text(bytes, 100, 8), "MEMBER")
  // The last thirty columns of the library header record are zeros.
  assert_eq(field_text(bytes, 60, 20), "000000000000000000")
  assert_eq(field_text(bytes, 0, 80).code_units().length(), 78)
  assert_eq(field_text(bytes, 78, 2), "")
  assert_eq(trimmed_length(bytes, 0, 80), 78)
  assert_eq(trimmed_length(bytes, 78, 2), 0)
  assert_eq(trimmed_length(bytes, 0, 1), 1)
  assert_eq(be16(b"\x00\x01\x01\x00", 0), 1)
  assert_eq(be16(b"\x01\x00", 0), 256)
  assert_eq(be16(b"\x7f\xff", 0), 32767)
  assert_eq(be16(b"\x80\x00", 0), -32768)
  assert_eq(be16(b"\xff\xff", 0), -1)
  assert_eq(be16(b"\x00\x00", 0), 0)
  assert_eq(be16(b"ab\x01\x40", 2), 320)
  let member_record = ascii(MEMBER_RECORD + "0000000140  ")
  assert_eq(record_number(member_record, 0, 68, 10), 140L)
  assert_eq(record_number(member_record, 0, 68, 2), 0L)
  assert_eq(record_number(ascii("9999999999"), 0, 0, 10), 9999999999L)
  assert_eq(record_number(ascii("  7"), 0, 2, 1), 7L)
}

///|
test "a field that should be a number refuses on the byte that is not a digit" {
  for (text, from) in [("x40", 0), ("1x0", 1), ("14x", 2), ("1 3", 1)] {
    let outcome : Result[Int64, @types.DataError] = Ok(
      record_number(ascii(text), 0, from, 1),
    ) catch {
      e => Err(e)
    }
    match outcome {
      Ok(number) => fail("\"\{text}\" read as the number \{number}")
      Err(e) =>
        match e {
          @types.DataError::ParseError(
            @types.ParseErrorDetail::Message(message),
          ) =>
            assert_eq(
              message,
              "xport: byte \{from}: a count is spelled here in digits, and this byte is not one",
            )
          other => fail("\"\{text}\" refused with \{other}")
        }
    }
  }
  // Inside a ten-digit count, the refusal names the byte itself.
  let outcome : Result[Int64, @types.DataError] = Ok(
    record_number(ascii("00000000x0"), 0, 0, 10),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Ok(number) => fail("00000000x0 read as the number \{number}")
    Err(e) =>
      match e {
        @types.DataError::ParseError(@types.ParseErrorDetail::Message(message)) =>
          assert_eq(
            message, "xport: byte 8: a count is spelled here in digits, and this byte is not one",
          )
        other => fail("00000000x0 refused with \{other}")
      }
  }
}

///|
test "a display format names the family it belongs to, by its name alone" {
  for name in day_formats() {
    if !(format_family(name) is Days) {
      fail("\"\{name}\" is a date format")
    }
    if !(format_family(name + "9") is Days) {
      fail("\"\{name}9\" is the date format \"\{name}\" at width 9")
    }
  }
  for name in clock_formats() {
    if !(format_family(name) is Clock) {
      fail("\"\{name}\" is a time format")
    }
    if !(format_family(name + "20") is Clock) {
      fail("\"\{name}20\" is the time format \"\{name}\" at width 20")
    }
  }
  for name in instant_formats() {
    if !(format_family(name) is Instant) {
      fail("\"\{name}\" is a datetime format")
    }
    if !(format_family(name + "19") is Instant) {
      fail("\"\{name}19\" is the datetime format \"\{name}\" at width 19")
    }
  }
}

///|
test "a display format of no family leaves the cells numbers" {
  for
    name in [
      "", " ", "date", "Date", "TIME.", "DATETIM", "DATETIMEX", "DDMMYYB", "DDMMYYX",
      "DTDATEx", "WEEKDATEx", "MDYAMPMX", "E8601DN", "DTWKDATX", "JULDAY", "MINGUO",
      "FOO", "123", "B8601D", "NENG",
    ] {
    if !(format_family(name) is Number) {
      fail("\"\{name}\" names a family")
    }
  }
  // The tables are the ones the report lists.
  assert_eq(day_formats().length(), 11)
  assert_eq(clock_formats().length(), 5)
  assert_eq(instant_formats().length(), 7)
  assert_eq(day_formats()[0], "DATE")
  assert_eq(day_formats()[10], "NENGO")
  assert_eq(clock_formats()[4], "TOD")
  assert_eq(instant_formats()[6], "E8601DT")
}

///|
test "a spelling is matched code unit for code unit, over its whole length" {
  assert_true(spells("DATE9", 4, "DATE"))
  assert_true(spells("DATE", 4, "DATE"))
  assert_false(spells("DAT", 4, "DATE"))
  assert_false(spells("DAT9", 4, "DATE"))
  assert_false(spells("DATE9", 5, "DATE"))
  assert_true(spells("", 0, ""))
}
