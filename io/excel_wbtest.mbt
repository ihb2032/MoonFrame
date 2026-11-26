// Whitebox tests of the Excel entries' own decisions: what each number
// format makes of a number, the serial arithmetic of both date systems,
// and every cell shape under every column dtype — the combinations the
// reader's verdicts never produce, met here so the total functions are
// known to be total.

///|
/// The day count of an ISO date, as the readers parse it.
fn xlsx_days(text : String) -> Int64 {
  @types.parse_date_days_opt(text).unwrap()
}

///|
test "the builtin number formats a date is read by" {
  // The shared date and time formats, and nothing else: 0 to 13, 23 to
  // 44, and the locale's own 27 to 36 and 50 to 58 are numbers.
  assert_true(excel_builtin_format(14) is Date(false))
  assert_true(excel_builtin_format(15) is Date(false))
  assert_true(excel_builtin_format(16) is Date(false))
  assert_true(excel_builtin_format(17) is Date(false))
  assert_true(excel_builtin_format(18) is Time)
  assert_true(excel_builtin_format(19) is Time)
  assert_true(excel_builtin_format(20) is Time)
  assert_true(excel_builtin_format(21) is Time)
  assert_true(excel_builtin_format(22) is Date(true))
  assert_true(excel_builtin_format(45) is Time)
  assert_true(excel_builtin_format(46) is Elapsed)
  assert_true(excel_builtin_format(47) is Time)
  for id in [0, 1, 9, 10, 13, 23, 27, 30, 36, 37, 44, 48, 50, 58, 59, 99] {
    assert_true(excel_builtin_format(id) is Plain, msg="\{id}")
  }
  // No format at all is a plain number; the other kinds are the fixtures'
  // to carry, the type being read-only outside its package.
  assert_true(excel_format(None) is Plain)
}

///|
test "what a custom number format's code makes of a number" {
  // Dates without a time.
  for
    code in [
      "yyyy-mm-dd", "m/d/yy", "d-mmm-yy", "mmm-yy", "d/m/yyyy", "dd/mm/yyyy", "mm-dd-yy",
      "yyyy\"年\"m\"月\"d\"日\"", "[$-409]mmmm d, yyyy", "yyyy/m/d", "mm\"月\"dd\"日\"",
      "ddd dd/mmm/yy", "yyyy\\-mm\\-dd", "YYYY.MM.DD", "[$-F800]dddd, mmmm dd, yyyy",
      "m/d/yyyy;@", "yyyy-mm-dd;@",
    ] {
    assert_true(excel_custom_format(code) is Date(false), msg=code)
  }
  // Dates with a time of day.
  for
    code in [
      "m/d/yy h:mm", "yyyy-mm-dd hh:mm:ss", "d/m/yyyy hh:mm", "yyyy-mm-dd h:mm AM/PM",
      "yyyy-mm-dd hh:mm:ss AM/PM", "m/d/yy h:mm;@",
    ] {
    assert_true(excel_custom_format(code) is Date(true), msg=code)
  }
  // Times of day alone: the meridian's M is no month, and an m next to
  // an hour or a second is a minute.
  for
    code in [
      "h:mm", "hh:mm", "h:mm:ss", "hh:mm:ss", "h:mm AM/PM", "h:mm:ss AM/PM", "hh:mm:ss am/pm",
      "h:mm A/P", "mm:ss", "h\"时\"mm\"分\"", "hh:mm:ss;@", "[$-409]h:mm:ss AM/PM",
    ] {
    assert_true(excel_custom_format(code) is Time, msg=code)
  }
  // Elapsed times: the bracketed unit is the whole serial's.
  for code in ["[h]:mm:ss", "[hh]:mm", "[m]:ss", "[s]", "[HH]", "[mm]"] {
    assert_true(excel_custom_format(code) is Elapsed, msg=code)
  }
  // Numbers: quoted words with the date letters in them, escapes, skips,
  // fills, brackets of condition and locale, and letters that are no
  // date's.
  for
    code in [
      "General", "@", "0", "0.00", "#,##0.00", "0.00E+00", "##0.0E+0", "0%", "0.0%",
      "\"day \"0\" m\"", "0.0\" m\"", "0.0\"h\"", "#,##0 \"days\"", "#,##0_);(#,##0)",
      "#,##0_);[Red](#,##0)", "[$$-409]#,##0.00", "[$€-2]#,##0.00", "_($* #,##0.00_);_($* (#,##0.00);_($* \"-\"??_);_(@_)",
      "[<0]-#,##0;#,##0", "00000", "0.00_);[Red](0.00)", "# ?/?", "\"$\"#,##0.00",
      "0.00;(0.00)", "* #-##0", "0.000", "#,##0.00 \"€\"", "\"Yes\";\"Yes\";\"No\"",
      "@;", "[<>0]0.00", "[Red][$$$-409]#,##0.00", "0.00 \"units\";[Red]-0.00 \"units\"",
    ] {
    assert_true(excel_custom_format(code) is Plain, msg=code)
  }
  // A bracket that is no time unit does not make an elapsed time.
  assert_true(excel_custom_format("[Red]yyyy-mm-dd") is Date(false))
  // A month's name is a month, bracketed locale or not.
  assert_true(excel_custom_format("[$-409]mmm\"?\"") is Date(false))
  assert_true(excel_custom_format("[>0]0.00;[<=0]\"-\"") is Plain)
  // The first section is the one read: a date format for the other
  // signs is not a date.
  assert_true(excel_custom_format("0.00;[Red]yyyy-mm-dd") is Plain)
  assert_true(excel_custom_format("\"a\"\"b\"0.00") is Plain)
  assert_true(excel_elapsed("0.00;[h]:mm") is false)
  assert_true(excel_elapsed("\"[h]\"0.00") is false)
  // A bracket holding two time letters, or another character, is no
  // elapsed unit.
  assert_true(excel_elapsed("[hm]:mm") is false)
  assert_true(excel_elapsed("[h ]:mm") is false)
}

///|
test "a serial names a day or an instant by the date system" {
  // The 1900 system's phantom day: 59 is the 28th of February, 60 the
  // day it displays over, and 61 the 1st of March; day 1 the 1st of
  // January 1900.
  let day_1900_01_01 = xlsx_days("1900-01-01")
  assert_eq(excel_day(1.0, false, "c"), day_1900_01_01)
  assert_eq(excel_day(59.0, false, "c"), xlsx_days("1900-02-28"))
  assert_eq(excel_day(60.0, false, "c"), xlsx_days("1900-02-28"))
  assert_eq(excel_day(61.0, false, "c"), xlsx_days("1900-03-01"))
  assert_eq(excel_day(25569.0, false, "c"), 0L)
  assert_eq(excel_day(45476.0, false, "c"), xlsx_days("2024-07-03"))
  assert_eq(excel_day(2958465.0, false, "c"), EXCEL_LAST_DAY)
  // The 1904 system has no phantom day.
  assert_eq(excel_day(0.0, true, "c"), -24107L)
  assert_eq(excel_day(24107.0, true, "c"), 0L)
  assert_eq(excel_day(44014.0, true, "c"), xlsx_days("2024-07-03"))
  // An instant: the fraction to the microsecond, and a fraction that
  // rounds to a whole day being the next midnight.
  let day = xlsx_days("2024-07-03") * EXCEL_DAY_MICROS
  assert_eq(excel_instant(45476.5, false, "c"), day + 43_200_000_000L)
  assert_eq(
    excel_instant(45476.521388888888, false, "c"),
    day + 45_048_000_000L,
  )
  assert_eq(
    excel_instant(45476.99999999999999, false, "c"),
    day + EXCEL_DAY_MICROS,
  )
  assert_eq(
    excel_instant(0.99999999999999, false, "c"),
    excel_day(1.0, false, "c") * EXCEL_DAY_MICROS,
  )
  assert_eq(excel_day(60.0, true, "c"), -24107L + 60L)
  // A time of day is the fraction alone, and an elapsed time the whole
  // serial.
  assert_eq(excel_time(45476.5, "c"), 43_200_000_000L)
  assert_eq(excel_time(0.99999999999999, "c"), 0L)
  assert_eq(excel_span(1.25, "c"), 108_000_000_000L)
  assert_eq(excel_span(0.0, "c"), 0L)
  // A serial naming no day refuses: one before the first, one past the
  // last, and one that is not a number.
  for serial in [-1.0, -0.5, 0.0 / 0.0] {
    assert_true(
      (Ok(ignore(excel_day(serial, false, "B2"))) catch { e => Err(e) })
      is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
      m.contains("cell B2 carries a date") &&
      m.contains("before the first day"),
      msg="\{serial}",
    )
  }
  assert_true(
    (Ok(ignore(excel_day(2958466.0, false, "C3"))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
    m.contains("cell C3 carries a date 2958466, past 9999-12-31"),
  )
}

///|
test "a number cell under each format" {
  assert_true(excel_number(45476.5, Plain, false, "A1") is Number(_))
  assert_true(excel_number(0.5, Time, false, "A1") is Instant(43_200_000_000L))
  assert_true(
    excel_number(1.25, Elapsed, false, "A1") is Instant(108_000_000_000L),
  )
  assert_true(excel_number(45476.0, Date(false), false, "A1") is Day(_))
  // A fraction a date format does not show is the instant it names.
  assert_true(excel_number(45476.5, Date(false), false, "A1") is Instant(_))
  assert_true(excel_number(45476.5, Date(true), false, "A1") is Instant(_))
}

///|
test "the serial of a day and of an instant, in both date systems" {
  // The inverse of the reads above, over the days and instants the
  // calendar holds.
  for
    text in [
      "1900-01-01", "1900-02-28", "1900-03-01", "1904-01-01", "1970-01-01", "2000-02-29",
      "2024-07-03", "2148-12-31", "9999-12-31",
    ] {
    let days = xlsx_days(text)
    for date1904 in [false, true] {
      if date1904 && days < -24107L {
        continue
      }
      let serial = excel_day_serial(days, date1904, "d")
      assert_eq(excel_day(serial, date1904, "c"), days, msg=text)
    }
  }
  for
    text in [
      "1900-03-01T00:00:00.000001", "1969-12-31T23:59:59.999999", "2024-02-29T23:59:59.999999",
      "2148-12-31T12:34:56.789012", "2200-01-01T00:00:00.000000",
    ] {
    let micros = @types.parse_timestamp_micros_opt(text).unwrap()
    let serial = excel_instant_serial(micros, false, "t")
    assert_eq(excel_instant(serial, false, "c"), micros, msg=text)
  }
  // A day the calendar does not name refuses, naming the column.
  let early = Ok(excel_day_serial(-25568L, false, "d")) catch { e => Err(e) }
  assert_true(
    early
    is Err(
      @types.DataError::Unsupported(
        "excel: column \"d\" holds a day before 1900-01-01, the first day the 1900 calendar names",
      ),
    ),
  )
  let early_1904 = Ok(excel_day_serial(-24108L, true, "d")) catch {
    e => Err(e)
  }
  assert_true(
    early_1904
    is Err(
      @types.DataError::Unsupported(
        "excel: column \"d\" holds a day before 1904-01-01, the first day the 1904 calendar names",
      ),
    ),
  )
  let late = Ok(excel_day_serial(EXCEL_LAST_DAY + 1L, false, "d")) catch {
    e => Err(e)
  }
  assert_true(
    late
    is Err(
      @types.DataError::Unsupported(
        "excel: column \"d\" holds a day past 9999-12-31, the last day the calendar names",
      ),
    ),
  )
  assert_eq(excel_place(3, 2), "at row 3, column 2")
}

///|
test "every cell shape under every column dtype is total" {
  // The combinations the reader's verdicts never produce are met here,
  // each answering the null a shape the dtype cannot hold.
  let cells : Array[ExcelCell] = [
    Missing,
    Text("x"),
    Boolean(true),
    Number(1.5),
    Day(19724),
    Instant(45_000_000_000L),
  ]
  let dtypes : Array[@types.DataType] = [
    @types.DataType::String,
    @types.DataType::Bool,
    @types.DataType::Int,
    @types.DataType::Float,
    @types.DataType::Date,
    @types.DataType::Timestamp,
    @types.DataType::Null,
    @types.DataType::Decimal,
    @types.DataType::Duration,
    @types.DataType::List(@types.DataType::Int),
    @types.DataType::Struct(@types.Schema::Schema([])),
  ]
  for cell in cells {
    for dtype in dtypes {
      ignore(excel_scalar(cell, dtype))
    }
  }
  // The shapes a dtype holds beyond its verdict's own.
  assert_eq(excel_scalar(Missing, @types.DataType::String), Null)
  assert_eq(excel_scalar(Text("x"), @types.DataType::Bool), Null)
  assert_eq(
    excel_scalar(Boolean(true), @types.DataType::String),
    @types.Scalar::String("true"),
  )
  assert_eq(
    excel_scalar(Number(45476.5), @types.DataType::String),
    @types.Scalar::String("45476.5"),
  )
  assert_eq(
    excel_scalar(Day(19724), @types.DataType::String),
    @types.Scalar::String("2024-01-02"),
  )
  assert_eq(
    excel_scalar(Instant(45_000_000_000L), @types.DataType::String),
    @types.Scalar::String("1970-01-01T12:30:00.000000"),
  )
  assert_eq(excel_scalar(Text("x"), @types.DataType::Int), Null)
  assert_eq(
    excel_scalar(Number(42.0), @types.DataType::Int),
    @types.Scalar::Int(42),
  )
  assert_eq(
    excel_scalar(Number(-1.5), @types.DataType::Int),
    @types.Scalar::Int(-1),
  )
  assert_eq(
    excel_scalar(Number(-1.5), @types.DataType::Float),
    @types.Scalar::Float(-1.5),
  )
  // An instant in a Date column is its day; a day in a Timestamp column
  // is its midnight.
  assert_eq(
    excel_scalar(Instant(45_048_000_000L), @types.DataType::Date),
    @types.Scalar::Date(0),
  )
  assert_eq(
    excel_scalar(Day(19724), @types.DataType::Timestamp),
    @types.Scalar::Timestamp(19724L * EXCEL_DAY_MICROS),
  )
  assert_eq(excel_text(Missing), "")
  assert_eq(excel_text(Boolean(false)), "false")
}

///|
test "the library's own refusals are the entries' errors" {
  // A cell asked for where no row is: the refusal is a ParseError
  // naming the library's text.
  let workbook = @xlsx.Workbook::new()
  ignore(workbook.add_sheet("S"))
  let sheet = workbook.sheets()[0]
  assert_true(
    (Ok(ignore(excel_cell_value(workbook, "S", 0, 0))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
    m.has_prefix("excel: "),
  )
  assert_true(
    (Ok(ignore(excel_style(sheet, 0, 0))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
    m.has_prefix("excel: "),
  )
  // A typed value and a text written where no cell is.
  assert_true(
    (Ok(ignore(excel_write(workbook, "S", 0, 1, @xlsx.CellValue::Bool(true)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
    m.has_prefix("excel: "),
  )
  assert_true(
    (Ok(ignore(excel_write_text(workbook, "S", 0, 1, "x"))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
    m.has_prefix("excel: "),
  )
  // A sheet the workbook does not carry names the ones it does.
  assert_true(
    (Ok(ignore(excel_sheet(workbook, "T"))) catch { e => Err(e) })
    is Err(
      @types.DataError::InvalidOperation(
        "excel: the workbook carries no sheet named \"T\"; its sheets are \"S\"",
      ),
    ),
  )
  // A workbook of no sheet at all.
  assert_true(
    (Ok(ignore(excel_sheet(@xlsx.Workbook::new(), ""))) catch { e => Err(e) })
    is Err(
      @types.DataError::InvalidOperation("excel: the workbook carries no sheet"),
    ),
  )
  // An encrypted workbook is one these entries do not open.
  let locked = @xlsx.Workbook::new()
  ignore(locked.add_sheet("S"))
  let secret = @xlsx.write_with_password(locked, "secret")
  assert_true(
    (Ok(ignore(excel_workbook(secret))) catch { e => Err(e) })
    is Err(
      @types.DataError::Unsupported(
        "excel: the workbook is encrypted, which these entries do not open",
      ),
    ),
  )
  // A file's bytes that cannot be read.
  assert_true(
    (Ok(ignore(excel_bytes("_build/xlsx-absent-dir/x.xlsx"))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::IoError(_)),
  )
  // A style set where no cell is.
  assert_true(
    (Ok(ignore(excel_style_cell(workbook, "S", 0, 1, 0))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(m))) &&
    m.has_prefix("excel: "),
  )
}

///|
test "a cell with no value is missing, however it has none" {
  // A sheet whose first style is a date format, for the number below.
  let workbook = @xlsx.Workbook::new()
  ignore(workbook.add_sheet("S"))
  ignore(workbook.new_style(@xlsx.Style::builtin_number_format(14)))
  let sheet = workbook.sheets()[0]
  let formats = workbook.styles.map(style => excel_format(style.number_format))
  let read = fn(
    value : @xlsx.CellValue?,
    dates : Bool,
  ) -> ExcelCell raise @types.DataError {
    excel_read(value, sheet, 1, 1, formats, dates, false, "A1")
  }
  assert_true(read(None, true) is Missing)
  assert_true(read(Some(@xlsx.CellValue::String("")), true) is Missing)
  assert_true(read(Some(@xlsx.CellValue::Error("#N/A")), true) is Missing)
  // Without dates a number is itself whatever its format would say.
  assert_true(
    read(Some(@xlsx.CellValue::Numeric(45476.0)), false) is Number(45476.0),
  )
  // Under dates the style formats it: style 0 has no format here, so it
  // is a number; a cell given the date style reads as the day.
  assert_true(
    read(Some(@xlsx.CellValue::Numeric(45476.0)), true) is Number(45476.0),
  )
  workbook.set_cell_style_rc("S", 1, 1, 1)
  assert_true(read(Some(@xlsx.CellValue::Numeric(45476.0)), true) is Day(19907))
  assert_true(read(Some(@xlsx.CellValue::Bool(true)), true) is Boolean(true))
  assert_true(read(Some(@xlsx.CellValue::String("x")), true) is Text("x"))
}

///|
test "an instant finer than a sheet's number holds refuses the write" {
  // Near the calendar's end the serial's double steps by more than a
  // microsecond: the last instant of 9999 would read back as another
  // day, so it is refused rather than written.
  let micros = @types.parse_timestamp_micros_opt("9999-12-31T23:59:59.999999").unwrap()
  let refused = Ok(excel_instant_serial(micros, false, "t")) catch {
    e => Err(e)
  }
  assert_true(
    refused is Err(@types.DataError::Unsupported(m)) &&
    m.contains("9999-12-31T23:59:59.999999") &&
    m.contains("finer than the number a sheet's date holds it by"),
  )
}
