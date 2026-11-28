// Whitebox unit tests of the reader's parts over hand-picked inputs: the
// number, date, duration and clock parsers; the declaration's encoding
// name; a position's byte; a text node's cut line breaks; the budget; the
// mimetype entry's display; and the bytes a range reader asks for.

///|
/// An attribute as the parsers are handed one, at byte 7.
fn attr(name : String, value : String) -> Attr {
  Attr::{ name, value, byte: 7, }
}

///|
/// A value as a test compares it.
fn spelled(value : OdsValue) -> String {
  match value {
    Text(text) => "Text \{text}"
    Number(number) => "Number \{number.reinterpret_as_uint64()}"
    Boolean(boolean) => "Boolean \{boolean}"
    Day(days) => "Day \{days}"
    Instant(micros) => "Instant \{micros}"
    Time(micros) => "Time \{micros}"
  }
}

///|
/// What `parse` refuses for `text`, as the library renders the refusal —
/// `<parsed>` when it parses.
fn refusal_text(
  text : String,
  parse : (String, Attr) -> Unit raise @types.DataError,
) -> String {
  let outcome : Result[_, @types.DataError] = Ok(
    parse(text, attr("office:x", text)),
  ) catch {
    e => Err(e)
  }
  match outcome {
    Err(error) => error.message()
    Ok(_) => "<parsed>"
  }
}

///|
/// The refusal a parser must give for `text`: its attribute, byte 7 and
/// `name`, the value, then `wrong`.
fn expect_refusal(
  name : String,
  text : String,
  got : String,
  wrong : String,
) -> Unit raise Failure {
  let expected = "Parse error: ods: content.xml byte 7: the \{name} attribute \"\{cut(text, 32)}\" \{wrong}"
  if got != expected {
    fail("for \{text}: \{got}; expected \{expected}")
  }
}

///|
test "parse_number takes the XML Schema double spellings" {
  let cases : Array[(String, Double)] = [
    ("1", 1.0),
    ("+1", 1.0),
    ("1.", 1.0),
    ("1.0", 1.0),
    (".5", 0.5),
    ("-.5", -0.5),
    ("1e3", 1000.0),
    ("1E-3", 0.001),
    ("1e+3", 1000.0),
    (" 5 ", 5.0),
    ("\t5\n", 5.0),
    ("1.7976931348623157e308", @double.max_value),
    ("5.0e-324", 5.0e-324),
    ("2.2250738585072014e-308", 2.2250738585072014e-308),
    ("4.9406564584124654e-324", 5.0e-324),
    ("9007199254740993", 9007199254740992.0),
    ("123456789012345678", 123456789012345680.0),
    ("0.1", 0.1),
    ("1e-400", 0.0),
    ("1e-2147483649", 0.0),
    ("INF", @double.infinity),
    ("-INF", @double.neg_infinity),
    ("+5.0e0", 5.0),
    ("-1.7976931348623157e308", -@double.max_value),
  ]
  for (text, wanted) in cases {
    assert_eq(parse_number(text, attr("office:value", text)), wanted)
  }
  assert_true(parse_number("NaN", attr("office:value", "NaN")).is_nan())
  assert_eq(
    parse_number("-0", attr("office:value", "-0")).reinterpret_as_uint64(),
    0x8000000000000000UL,
  )
  assert_eq(
    parse_number("-0.0", attr("office:value", "-0.0")).reinterpret_as_uint64(),
    0x8000000000000000UL,
  )
}

///|
test "parse_number refuses what is not a number, by the same message" {
  for
    text in [
      "", "+", "-", ".", "e5", "1e", "1e+", "1e-", "1.2.3", "--5", "abc", "inf",
      "Infinity", "nan", "NAN", "+INF", "NaN x", "1_000", "0x10", "1,5", "5f", "1e400",
      "-1e400", "1e2147483648", "1e99999999999999999999999", "١٢٣", "1.5d", "0x1p3",
      "N/A", "1 e 3", "0.1.2.3e5", "1e3080", "012345678901234567890123456789012345678901234567890123456789012345678901e400",
    ] {
    expect_refusal(
      "office:x",
      text,
      refusal_text(text, (text, at) => ignore(parse_number(text, at))),
      "is not a number",
    )
  }
}

///|
test "parse_date takes a calendar date as a Day" {
  let cases : Array[(String, Int64)] = [
    ("2020-01-02", 18263L),
    ("1970-01-01", 0L),
    ("1969-12-31", -1L),
    ("0001-01-01", -719162L),
    ("0999-01-01", -354650L),
    ("9999-12-31", 2932896L),
    ("1900-02-28", -25509L),
    ("2000-02-29", 11016L),
    ("0000-01-01", -719528L),
    (" 2020-01-02 ", 18263L),
    ("2020-01-02T00:00:00", 18263L),
    ("2020-01-02 00:00:00.000000", 18263L),
    ("2020-01-02t00:00", 18263L),
    ("2020-01-02T00:00:00.0000004", 18263L),
    ("2020-01-02T00:00:00.0000004999", 18263L),
    ("2020-01-02T00:00:00.0000006", 18263L),
    ("2400-02-29", 157113L),
    ("1970-03-01", 59L),
    ("1972-02-29", 789L),
  ]
  for (text, wanted) in cases {
    assert_eq(
      spelled(parse_date(text, attr("office:date-value", text))),
      "Day \{wanted}",
    )
  }
}

///|
test "parse_date takes a date with a clock, or an offset, as the Instant it names" {
  let day = 18263L * DAY_MICROS
  let cases : Array[(String, Int64)] = [
    ("2020-01-02T12:34:56", day + 45296000000L),
    ("2020-01-02 12:34:56", day + 45296000000L),
    ("2020-01-02T12:34:56.5", day + 45296500000L),
    ("2020-01-02T12:34:56.123456", day + 45296123456L),
    ("2020-01-02T12:34:56.123456789", day + 45296123456L),
    ("2020-01-02T12:34:56.9999995", day + 45296999999L),
    ("2020-01-02T12:34:56.0000005", day + 45296000000L),
    ("2020-01-02T12:34:56.0000015", day + 45296000001L),
    ("2020-01-02T12:34", day + 45240000000L),
    ("2020-01-02T00:00:00.000001", day + 1L),
    ("2020-01-02T00:00:01", day + 1000000L),
    ("2020-01-02t12:34:56z", day + 45296000000L),
    ("2020-01-02T12:34:56+02:00", day + 45296000000L - 7200000000L),
    ("2020-01-02T12:34:56-05:30", day + 45296000000L + 19800000000L),
    ("2020-01-02T12:34:56.5+02:00", day + 45296500000L - 7200000000L),
    ("2020-01-02T12:34:56.123456789+02:00", day + 45296123456L - 7200000000L),
    ("2020-01-02Z", day),
    ("2020-01-02z", day),
    ("2020-01-02+02:00", day - 7200000000L),
    ("2020-01-02-05:30", day + 19800000000L),
    ("2020-01-02T00:00:00+02:00", day - 7200000000L),
    ("2020-01-02+00:00", day),
    ("2020-01-02+14:00", day - 50400000000L),
    ("1969-12-31T23:59:59.123456789", -876544L),
    ("1969-12-31T23:59:59.9999995", -1L),
  ]
  for (text, wanted) in cases {
    assert_eq(
      spelled(parse_date(text, attr("office:date-value", text))),
      "Instant \{wanted}",
    )
  }
}

///|
test "parse_date refuses what is not a date, by the same message" {
  for
    text in [
      "", "2020-1-2", "2020-01-2", "202-01-02", "20200-01-02", "20200102", "2020.01.02",
      "2020-01", "2020/01/02", "2020-01-02T", "2020-01-02T12", "2020-01-02T12:3",
      "2020-01-02T12:345", "2020-01-02T12:34:5", "2020-01-02T12:34:567", "2020-01-02T12:34:56.",
      "2020-01-02T12:34:56.5x", "2020-01-02T12:34:56.5.6", "2020-01-02T24:00:00",
      "2020-01-02T25:00:00", "2020-01-02T12:60:00", "2020-01-02T12:34:60", "2020-01-02T12:34:61",
      "2020-01-02 12:34:56 x", "2020-13-01", "2020-00-10", "2020-01-00", "2020-01-32",
      "2020-02-30", "2019-02-29", "1900-02-29", "2100-02-29", "2020-04-31", "2020-01-02x",
      "2020-01-02T12:34:56Zx", "2020-01-02T12:34:56+2:00", "2020-01-02T12:34:56+0200",
      "2020-01-02T12:34:56+02:6", "2020-01-02T12:34:56+25:00", "2020-01-02T12:34:56+02:60",
      "2020-01-02T12:34:56-", "10000-01-01", "100000-01-01", "-0001-01-01", "+2020-01-02",
      "12:34:56", "P1D", "2020-01-02T+02:00", "2020-W01-1", "0123456789012345678901234567890123456789012-01-02",
      "2020-01-02T0123456789012345678901234567890123456789:00", "2020-01-02T12:34:56.012345678901234567890123456789012345678901234567890123456789x",
    ] {
    expect_refusal(
      "office:x",
      text,
      refusal_text(text, (text, at) => ignore(parse_date(text, at))),
      "is not a date",
    )
  }
}

///|
test "parse_duration takes the durations of a time of day" {
  let cases : Array[(String, Int64)] = [
    ("PT12H34M56S", 45296000000L),
    ("PT00H00M00S", 0L),
    ("PT0M0S", 0L),
    ("PT0H", 0L),
    ("P1D", DAY_MICROS),
    ("PT26H", 93600000000L),
    ("P1DT02H00M00S", 93600000000L),
    ("P1DT2H", 93600000000L),
    ("PT0.5S", 500000L),
    ("PT.5S", 500000L),
    ("PT12H34S", 43234000000L),
    ("PT12H34M56.789123456S", 45296789123L),
    ("PT12H34M56.7891234564S", 45296789123L),
    ("PT12H34M56.7891234565S", 45296789123L),
    ("PT56.5S", 56500000L),
    ("P99999999D", 8639999913600000000L),
    ("PT9999999999S", 9999999999000000L),
    ("  PT1S  ", 1000000L),
    ("PT1M", 60000000L),
    ("PT1H", 3600000000L),
    ("PT0.000001S", 1L),
    ("PT0.0000004S", 0L),
    ("P0D", 0L),
    // The largest counts a 64-bit integer of microseconds holds.
    ("PT9223372036854S", 9223372036854000000L),
    ("PT9223372036854.775807S", 9223372036854775807L),
    ("PT9223372036853.709552S", 9223372036853709552L),
  ]
  for (text, wanted) in cases {
    assert_eq(
      spelled(Time(parse_duration(text, attr("office:time-value", text)))),
      "Time \{wanted}",
    )
  }
}

///|
test "parse_duration refuses what is not a time of day, by the same message" {
  for
    text in [
      "", "T12H", "pT1H", "-PT1H", "P", "PT", "P1Y", "P1M", "P1W", "P1MT12H", "P1DT",
      "P1S", "PT1D", "PT12HX", "PT12S34M", "PT34M12H", "PT12.5H", "PT1.5M", "PT12H34M56S5",
      "PT12H34M56S.", "PT1S.", "PT.S", "PT12H12H", "PT34M34M", "PT1S1S", "PT9223372036855S",
      "P106751992D", "PT999999999999999999D", "PT9999999999999999999H", "P9999999999999999999D",
      "PT9223372036854.775808S", "PT9223372036854.8S", "PT9223372036853S.1S", "x",
      "PT 1H", "PTx", "PT1x", "PT92233720368547758070S", "PT1D1D", "PT99999999D",
    ] {
    expect_refusal(
      "office:x",
      text,
      refusal_text(text, (text, at) => ignore(parse_duration(text, at))),
      "is not a time value",
    )
  }
}

///|
test "parse_clock_text takes a clock reading and refuses what is not one" {
  assert_eq(spelled(Time(parse_clock_text("12:34:56", 9))), "Time 45296000000")
  assert_eq(spelled(Time(parse_clock_text(" 12:34 ", 9))), "Time 45240000000")
  assert_eq(spelled(Time(parse_clock_text("1:05", 9))), "Time 3900000000")
  assert_eq(
    spelled(Time(parse_clock_text("12:34:56.789123456", 9))),
    "Time 45296789123",
  )
  assert_eq(spelled(Time(parse_clock_text("00:00:00.0000004", 9))), "Time 0")
  assert_eq(
    spelled(Time(parse_clock_text("23:59:59.999999", 9))),
    "Time 86399999999",
  )
  for
    text in [
      "", "x", "12", "12:0", "12:345", "12:60", "24:00:00", "25:00", "12:34:60",
      "12:34:5", "12:34:56.", "12:34:56Z", "12:34:56+02:00", "PT12H34M56S", "2020-01-02 12:34:56",
      "12:34:56 x", "12 :34", "١٢:34", "0123456789012345678901234567890123456789:00",
    ] {
    let got = refusal_text(text, (text, _) => ignore(parse_clock_text(text, 9)))
    assert_eq(
      got,
      "Parse error: ods: content.xml byte 9: the text of a time cell, \"\{cut(text, 32)}\", is not a clock reading",
    )
  }
}

///|
test "cut keeps the first characters and end_breaks_cut cuts only the line breaks at the ends" {
  assert_eq(cut("abc", 5), "abc")
  assert_eq(cut("abcdef", 3), "abc")
  assert_eq(cut("", 3), "")
  assert_eq(cut("日本語🎉です", 5), "日本語🎉で")
  assert_eq(cut("abcdef", 0), "")
  assert_eq(end_breaks_cut("abc\n"), "abc")
  assert_eq(end_breaks_cut("\n\nabc\n\n"), "abc")
  assert_eq(end_breaks_cut("\n"), "")
  assert_eq(end_breaks_cut(""), "")
  assert_eq(end_breaks_cut("a\nb"), "a\nb")
  assert_eq(end_breaks_cut("  a  "), "  a  ")
  // A carriage reference is not a line break here: the XML reader turns
  // the document's own line ends into line feeds before the text arrives.
  assert_eq(end_breaks_cut("\r\na\r\n"), "\r\na\r")
  assert_eq(end_breaks_cut("\ta\n"), "\ta")
  assert_eq(end_breaks_cut("\n\n"), "")
  assert_eq(end_breaks_cut("a\n\nb"), "a\n\nb")
}

///|
test "the calendar arithmetic" {
  assert_eq(days_from_civil(1970, 1, 1), 0L)
  assert_eq(days_from_civil(1970, 3, 1), 59L)
  assert_eq(days_from_civil(1972, 3, 1), 790L)
  assert_eq(days_from_civil(1969, 12, 31), -1L)
  assert_eq(days_from_civil(1969, 3, 1), -306L)
  assert_eq(days_from_civil(2000, 3, 1), 11017L)
  assert_eq(days_from_civil(1900, 3, 1), -25508L)
  assert_eq(days_from_civil(1, 1, 1), -719162L)
  assert_eq(days_from_civil(0, 1, 1), -719528L)
  assert_eq(month_days(2020, 2), 29)
  assert_eq(month_days(2021, 2), 28)
  assert_eq(month_days(2000, 2), 29)
  assert_eq(month_days(1900, 2), 28)
  assert_eq(month_days(2020, 1), 31)
  assert_eq(month_days(2020, 4), 30)
  assert_eq(DAY_MICROS, 86400000000L)
  assert_eq(MOST_MICROS, 9223372036854775807L)
}

///|
test "the budget grows with the package and stops at 2^25" {
  assert_eq(cell_budget(0), 65536L)
  assert_eq(cell_budget(1000), 73536L)
  assert_eq(cell_budget(4186111), 33554424L)
  assert_eq(cell_budget(4186112), 33554432L)
  assert_eq(cell_budget(2147483647), 33554432L)
}

///|
test "take_count takes digits only, up to the largest count" {
  let name = "table:number-columns-repeated"
  assert_eq(take_count(attr(name, "0")), 0L)
  assert_eq(take_count(attr(name, "007")), 7L)
  assert_eq(take_count(attr(name, "2147483647")), 2147483647L)
  for
    (value, wrong) in [
      ("", "is not a whole number"),
      ("-1", "is not a whole number"),
      ("+1", "is not a whole number"),
      (" 1", "is not a whole number"),
      ("1 ", "is not a whole number"),
      ("1.0", "is not a whole number"),
      ("١", "is not a whole number"),
      ("abc", "is not a whole number"),
      ("2147483648", "is past the largest count this reader takes"),
      (
        "99999999999999999999999999", "is past the largest count this reader takes",
      ),
      (
        "0000000000000000000002147483648", "is past the largest count this reader takes",
      ),
    ] {
    let got = refusal_text(value, (text, _) => {
      ignore(take_count(attr(name, text)))
    })
    expect_refusal(name, value, got, wrong)
  }
}

///|
test "the refusal for a sheet past its budget names the attribute where there is one" {
  let book = Book::{
    document: Document::{ text: "", wide: false, origin: 0, },
    budget: cell_budget(10),
    size: 10,
    judged_by_root: false,
    rooted: true,
    body: -1,
    spaces: 0L,
    sheets: [],
    tables: [],
    rows: [],
    cells: [],
  }
  let sheet = Sheet::{
    name: "Wide",
    depth: 1,
    cells: [],
    next_row: 0L,
    empty_rows: 0L,
    cause: None,
    width: 0L,
    held: 0L,
  }
  let grant = "than this reader grants a package of 10 bytes (65616)"
  assert_eq(
    sheet.too_big(book).message(),
    "Parse error: ods: content.xml: sheet \"Wide\" holds more cells \{grant}",
  )
  let named = Sheet::{
    ..sheet,
    cause: Some(attr("table:number-rows-repeated", "70000")),
  }
  assert_eq(
    named.too_big(book).message(),
    "Parse error: ods: content.xml byte 7: the table:number-rows-repeated attribute \"70000\" would make sheet \"Wide\" hold more cells \{grant}",
  )
  let long = Sheet::{ ..sheet, name: "n".repeat(70), }
  assert_eq(
    long.too_big(book).message(),
    "Parse error: ods: content.xml: sheet \"\{"n".repeat(64)}\" holds more cells \{grant}",
  )
}

///|
/// The namespace of the first element's name in a one-element document.
fn namespace_of(text : String) -> Space? raise @xml.XmlError {
  let reader = @xml.NamespaceReader::from_string(text)
  let event = reader.read_event()
  match event.kind {
    Start(element) => space_of(element.name)
    Empty(element) => space_of(element.name)
    _ => None
  }
}

///|
test "a name is in a namespace by the URI its prefix or its default is bound to" {
  assert_true(
    namespace_of(
      "<table:table xmlns:table='urn:oasis:names:tc:opendocument:xmlns:table:1.0'/>",
    )
    is Some(Table),
  )
  assert_true(
    namespace_of(
      "<tbl:a xmlns:tbl='urn:oasis:names:tc:opendocument:xmlns:table:1.0'/>",
    )
    is Some(Table),
  )
  assert_true(
    namespace_of("<a xmlns='urn:oasis:names:tc:opendocument:xmlns:table:1.0'/>")
    is Some(Table),
  )
  assert_true(
    namespace_of(
      "<a xmlns='urn:oasis:names:tc:opendocument:xmlns:office:1.0'/>",
    )
    is Some(Office),
  )
  assert_true(
    namespace_of(
      "<t:a xmlns:t='urn:oasis:names:tc:opendocument:xmlns:text:1.0'/>",
    )
    is Some(Text),
  )
  assert_true(namespace_of("<a/>") is None)
  assert_true(namespace_of("<a xmlns='urn:example:t'/>") is None)
  assert_true(
    namespace_of("<table:table xmlns:table='urn:example:t'/>") is None,
  )
  assert_true(
    namespace_of(
      "<a xmlns='urn:oasis:names:tc:opendocument:xmlns:office:1.0/ext'/>",
    )
    is None,
  )
  assert_eq(Space::prefix(Office), "office")
  assert_eq(Space::prefix(Table), "table")
  assert_eq(Space::prefix(Text), "text")
  assert_eq(
    Space::uri(Office),
    "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
  )
  assert_eq(
    Space::uri(Table),
    "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
  )
  assert_eq(Space::uri(Text), "urn:oasis:names:tc:opendocument:xmlns:text:1.0")
}

///|
test "a declaration's encoding name is found where it is spelled, and nowhere else" {
  let good : Array[(String, String)] = [
    ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "utf-8"),
    ("<?xml version='1.0' encoding='ISO-8859-1'?>", "iso-8859-1"),
    ("<?xml version=\"1.0\"\n  encoding = \"Utf8\"?>", "utf8"),
    ("<?xml\tversion=\"1.0\" encoding=\"x\"?>", "x"),
  ]
  for (text, wanted) in good {
    assert_eq(declared_encoding(@utf8.encode(text)), Some(wanted))
  }
  for
    text in [
      "", "<a/>", "<?xml-stylesheet href=\"encoding='x'\"?>", "<!-- <?xml version=\"1.0\" encoding=\"x\"?> -->",
      "<?xml version=\"1.0\"?>", "<?xml version=\"1.0\" standalone=\"yes\"?>", "<?xml version=\"1.0\" encoding=\"utf-8\"",
      "<?xml version=\"1.0\"?> <x encoding=\"a\"/>", "<?xml version=\"1.0\" xencoding=\"a\"?>",
      "<?xml version=\"1.0\" encoding \"utf-8\"?>", "<?xml version=\"1.0\" encoding=?>",
      "<?xml version=\"1.0\" encoding=utf-8?>", "<?xml version=\"1.0\" encoding=\"utf-8?>",
      " <?xml version=\"1.0\" encoding=\"utf-8\"?>", "<?XML version=\"1.0\" encoding=\"utf-8\"?>",
      "<?xmlversion=\"1.0\" encoding=\"utf-8\"?>", "<?xml version=\"1.0\" ENCODING=\"utf-8\"?>",
      "<?xml", "<?xml ", "<?xml version=\"1.0\" encoding=\"",
    ] {
    assert_eq(declared_encoding(@utf8.encode(text)), None)
  }
  assert_eq(find_word(b"ab", 0, "abc"), None)
  assert_eq(find_word(b"abc", 1, "a"), None)
  assert_eq(find_word(b"abcabc", 0, "abc"), Some(0))
  assert_eq(find_word(b"abcabc", 1, "abc"), Some(3))
  assert_true(is_xml_space(b' '))
  assert_true(is_xml_space(b'\t'))
  assert_true(is_xml_space(b'\n'))
  assert_true(is_xml_space(b'\r'))
  assert_true(!is_xml_space(b'x'))
  assert_true(is_utf8("utf-8"))
  assert_true(is_utf8("utf8"))
  assert_true(!is_utf8("utf-16"))
  assert_eq(latin1(b"\xe9\x41"), "éA")
}

///|
test "a position's byte counts UTF-8 bytes, or two a UTF-16 unit" {
  // a, é and 日 are one code unit each; 🎉 is two.
  let narrow = Document::{ text: "aé日🎉x", wide: false, origin: 0, }
  assert_eq(narrow.byte(0), 0)
  assert_eq(narrow.byte(1), 1)
  assert_eq(narrow.byte(2), 3)
  assert_eq(narrow.byte(3), 6)
  assert_eq(narrow.byte(5), 10)
  assert_eq(narrow.byte(6), 11)
  assert_eq(narrow.byte(99), 11)
  assert_eq(narrow.byte(-5), 0)
  let marked = Document::{ text: "aé日🎉x", wide: false, origin: 3, }
  assert_eq(marked.byte(0), 3)
  assert_eq(marked.byte(3), 9)
  assert_eq(marked.byte(6), 14)
  let wide = Document::{ text: "\u{FEFF}aé日🎉x", wide: true, origin: 0, }
  assert_eq(wide.byte(0), 0)
  assert_eq(wide.byte(1), 2)
  assert_eq(wide.byte(4), 8)
  assert_eq(wide.byte(6), 12)
  assert_eq(wide.byte(7), 14)
  assert_eq(wide.byte(-1), 0)
}

///|
test "a mimetype entry is shown as text, cut, or in hexadecimal" {
  assert_eq(shown(b"abc"), "abc")
  assert_eq(shown(b""), "")
  assert_eq(shown(b"\xc3\xa9"), "é")
  assert_eq(shown(@utf8.encode("x".repeat(70))), "\{"x".repeat(64)}...")
  assert_eq(shown(@utf8.encode("y".repeat(300))), "\{"y".repeat(64)}...")
  assert_eq(shown(@utf8.encode("z".repeat(256))), "\{"z".repeat(64)}...")
  assert_eq(shown(@utf8.encode("w".repeat(255))), "\{"w".repeat(64)}...")
  assert_eq(shown(b"\xff\xfe"), "\\xFF\\xFE")
  // A control character is text; a lone continuation byte is not.
  assert_eq(shown(b"\x01\x02"), "\u{01}\u{02}")
  let sixteen = "\\x80\\x81\\x82\\x83\\x84\\x85\\x86\\x87\\x88\\x89\\x8A\\x8B\\x8C\\x8D\\x8E\\x8F"
  assert_eq(shown(Bytes::makei(17, i => (0x80 + i).to_byte())), "\{sixteen}...")
  assert_eq(shown(Bytes::makei(16, i => (0x80 + i).to_byte())), sixteen)
  assert_eq(
    shown(Bytes::makei(3, i => (0x80 + i).to_byte())),
    "\\x80\\x81\\x82",
  )
  assert_eq(hexadecimal(b"\x00\xff"), "\\x00\\xFF")
  assert_eq(hexadecimal(b""), "")
  assert_true(is_spreadsheet_mimetype(@utf8.encode(SPREADSHEET)))
  assert_true(!is_spreadsheet_mimetype(@utf8.encode("\{SPREADSHEET}\n")))
  assert_true(!is_spreadsheet_mimetype(b""))
}

///|
test "the bytes a range reader asks for are checked against the archive first" {
  let small = Bytes::makei(300, i => (i % 251).to_byte())
  let reader = @zip.DirectoryReader(300UL, limits=@zip.DirectoryLimits())
  let head = match reader.advance(b"") {
    NeedRead(range) => range
    Done(_) => fail("a 300-byte archive listed without being read")
  }
  assert_eq(range_bytes(small, head).length(), 300)
  assert_eq(range_bytes(small, head)[7], small[7])
  // The same range, asked of an archive too short for it.
  assert_eq(range_bytes(b"ab", head), b"")
  // A big stored archive asks first for its tail, past the start.
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(SPREADSHEET), compression=Store)
  archive.add("big.bin", Bytes::makei(70000, _ => b'a'), compression=Store)
  let big = @zip.write(archive) catch { _ => b"" }
  let reader = @zip.DirectoryReader(
    big.length().to_uint64(),
    limits=@zip.DirectoryLimits(),
  )
  let tail = match reader.advance(b"") {
    NeedRead(range) => range
    Done(_) => fail("a 70 KB archive listed without being read")
  }
  assert_eq(tail.offset(), (big.length() - 65557).to_uint64())
  assert_eq(range_bytes(b"ab", tail), b"")
  assert_eq(range_bytes(big, tail).length(), 65557)
}

///|
test "an archive that cannot be listed has no encrypted entry, and a plain one has none" {
  assert_eq(encrypted_entry(b""), None)
  assert_eq(encrypted_entry(b"PK\x05\x06"), None)
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(SPREADSHEET), compression=Store)
  archive.add("content.xml", b"<a/>")
  assert_eq(encrypted_entry(@zip.write(archive) catch { _ => b"" }), None)
}
