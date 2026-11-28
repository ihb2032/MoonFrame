// Blackbox tests of the values a cell spells, at the edges the fixtures
// leave: how a string is composed from what its paragraphs hold, how a
// boolean is read from its text, and what a cell of an unknown type
// holding an error value is.

///|
test "a string is composed as the reference composes it, from whatever its paragraphs hold" {
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          // A comment inside a text node does not split it; a reference to
          // an entity does not either.
          xstring("<text:p>ab\n&amp;\ncd</text:p>") +
          xstring(
            "<text:p>a<!-- a comment -->b<![CDATA[<raw & cdata>]]>c</text:p>",
          ) +
          // A tab element is no character; a non-breaking space is one.
          xstring("<text:p>a<text:tab/>b&#160;c</text:p>") +
          // A run of spaces: one written, the rest by text:s.
          xstring("<text:p> <text:s text:c=\"3\"/>x</text:p>") +
          // Spaces only; and a line break only.
          xstring("<text:p><text:s/></text:p>") +
          xstring(
            "<text:p>line one<text:line-break/>line two<text:line-break/></text:p>",
          ) +
          // Paragraphs inside a span: a line break between them, there too.
          xstring("<text:span><text:p>a</text:p><text:p>b</text:p></text:span>") +
          // List items are elements like any other: no break between them.
          xstring(
            "<text:list><text:list-item><text:p>a</text:p></text:list-item><text:list-item><text:p>b</text:p></text:list-item></text:list>",
          ) +
          // An annotation wherever it sits is skipped, its text with it.
          xstring(
            "<text:p>x<text:span>y<office:annotation><text:p>a note</text:p><text:p>another</text:p></office:annotation>z</text:span>w</text:p>",
          ) +
          // A line end inside a text node stays; at its two ends it goes.
          xstring("<text:p>\n\na\n\nb\n\n</text:p>") +
          // Text directly in the cell, around a paragraph.
          xstring("before<text:p>in</text:p>after") +
          // A string cell holding a drawing and nothing else is empty.
          xstring(
            "<draw:frame xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\"/>",
          ),
        ),
      ),
    ),
    [
      "0,0 Text ab\n&\ncd", "0,1 Text ab<raw & cdata>c", "0,2 Text ab\u{a0}c", "0,3 Text     x",
      "0,4 Text \u{20}", "0,5 Text line one\nline two\n", "0,6 Text a\nb", "0,7 Text ab",
      "0,8 Text xyzw", "0,9 Text a\n\nb", "0,10 Text beforeinafter",
    ],
  )
}

///|
test "a boolean is read from its raw text: TRUE exactly, and nothing else" {
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"false\"",
            xp("TRUE"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp("true"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp("TRUE\n"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp("\nTRUE"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp(" TRUE"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"", "",
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp("#N/A"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp("TRU"),
          ) +
          xcell(
            " office:value-type=\"boolean\" office:boolean-value=\"true\"",
            xp("TRUE&#160;"),
          ),
        ),
      ),
    ),
    [
      "0,0 Boolean true", "0,1 Boolean false", "0,2 Boolean false", "0,3 Boolean false",
      "0,4 Boolean false", "0,5 Boolean false", "0,7 Boolean false", "0,8 Boolean false",
    ],
  )
  // A boolean covered cell with no office:value is empty, its text notwithstanding.
  cells_are(
    body_package(
      xtable("S", xrow(xcovered(" office:value-type=\"boolean\"", xp("TRUE")))),
    ),
    [],
  )
}

///|
test "a cell of a type the reader does not carry is empty while its text is the error value, and refused otherwise" {
  let odd = " office:value-type=\"integer\" office:value=\"1\""
  cells_are(
    body_package(xtable("S", xrow(xcell(odd, xp("#N/A")) + xnumber("2")))),
    ["0,1 Number 4000000000000000"],
  )
  // The error value wins over a value the cell also carries.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"string\" office:string-value=\"x\"",
            xp("#N/A"),
          ) +
          xcell(
            " office:value-type=\"date\" office:date-value=\"2020-01-02\"",
            xp("#N/A"),
          ),
        ),
      ),
    ),
    [],
  )
  // Not the error value: a space before or after, or a line break inside.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xtext(" #N/A ") +
          xtext("#N\nA") +
          xcell(" office:value-type=\"string\"", xp("#N") + xp("A")),
        ),
      ),
    ),
    ["0,0 Text  #N/A ", "0,1 Text #N\nA", "0,2 Text #N\nA"],
  )
  // A void cell with text is empty.
  cells_are(
    body_package(
      xtable("S", xrow(xcell(" office:value-type=\"void\"", xp("x")))),
    ),
    [],
  )
  // The type is spelled as it is: a case the format does not define is refused.
  for kind in ["integer", "String", "", "html", "float ", "boolean-value"] {
    let opening = "<table:table-cell office:value-type=\"\{kind}\""
    let content = document(
      xtable(
        "S",
        xrow(
          "\{opening} office:value=\"1\"><text:p>1</text:p></table:table-cell>",
        ),
      ),
    )
    let at = at_of(@utf8.encode(content), "office:value-type=\"\{kind}\"")
    refusal_is(
      spreadsheet(content),
      "Unsupported",
      "ods: content.xml byte \{at}: the office:value-type \"\{kind}\" is not a value type this reader carries",
    )
  }
}

///|
test "numbers as the format spells them, and the non-finite ones it names" {
  let numbers = [
    ("+1", "3ff0000000000000"),
    (".5", "3fe0000000000000"),
    ("1.", "3ff0000000000000"),
    (" 5 ", "4014000000000000"),
    ("1e3", "408f400000000000"),
    ("1E-3", "3f50624dd2f1a9fc"),
    ("1e+3", "408f400000000000"),
    ("-.5", "bfe0000000000000"),
    ("-0.0", "8000000000000000"),
    ("NaN", "NaN"),
    ("INF", "7ff0000000000000"),
    ("-INF", "fff0000000000000"),
    ("1.7976931348623157e308", "7fefffffffffffff"),
    ("5e-324", "0000000000000001"),
    ("4.9406564584124654e-324", "0000000000000001"),
    ("2.2250738585072014e-308", "0010000000000000"),
    ("0.30000000000000004", "3fd3333333333334"),
    ("1e-400", "0000000000000000"),
    ("0.1", "3fb999999999999a"),
    ("9007199254740993", "4340000000000000"),
    (
      "0.1000000000000000055511151231257827021181583404541015625", "3fb999999999999a",
    ),
  ]
  let cells = StringBuilder()
  let wanted : Array[String] = []
  for (value, bits) in numbers {
    wanted.push("0,\{wanted.length()} Number \{bits}")
    cells.write_string(
      "<table:table-cell office:value-type=\"float\" office:value=\"\{value}\"/>",
    )
  }
  cells_are(body_package(xtable("S", xrow(cells.to_string()))), wanted)
  // The percentage and the currency are the numbers they store.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"percentage\" office:value=\"0.15\"",
            xp("15%"),
          ) +
          xcell(
            " office:value-type=\"currency\" office:value=\"-3\" office:currency=\"USD\"",
            xp("-$3.00"),
          ) +
          xcell(
            " office:value-type=\"currency\" office:value=\"1e2\" office:currency=\"EUR\"",
            "",
          ),
        ),
      ),
    ),
    [
      "0,0 Number 3fc3333333333333", "0,1 Number c008000000000000", "0,2 Number 4059000000000000",
    ],
  )
}

///|
test "a date is a Day or an Instant, a time is read from its value or its text" {
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"date\" office:date-value=\"2020-01-02\"",
            xp("x"),
          ) +
          xcell(
            " office:value-type=\"date\" office:date-value=\"2020-01-02T00:00:00\"",
            xp("x"),
          ) +
          xcell(
            " office:value-type=\"date\" office:date-value=\"2020-01-02 12:00\"",
            xp("x"),
          ) +
          xcell(
            " office:value-type=\"date\" office:date-value=\"2020-01-02Z\"",
            xp("x"),
          ) +
          xcell(
            " office:value-type=\"date\" office:date-value=\"2020-01-02+02:00\"",
            xp("x"),
          ) +
          xcell(" office:value-type=\"date\" office:date-value=\"\"", xp("x")) +
          xcell(
            " office:value-type=\"time\" office:time-value=\"PT12H34M56S\" office:date-value=\"2020-01-02\"",
            xp("12:34:56"),
          ) +
          xcell(
            " office:value-type=\"time\" office:time-value=\"P1DT02H00M00S\"",
            xp("26:00:00"),
          ) +
          xcell(" office:value-type=\"time\"", xp(" 12:34 ")) +
          xcell(" office:value-type=\"time\"", xp("1:05")) +
          xcell(" office:value-type=\"time\"", xp("12:34:56.789123456")) +
          xcell(" office:value-type=\"time\"", "") +
          xcell(" office:value-type=\"time\"", xp(" \n ")) +
          xcell(
            " office:value-type=\"time\" office:time-value=\"PT0S\"",
            xp("midnight"),
          ),
        ),
      ),
    ),
    [
      "0,0 Day 18263", "0,1 Day 18263", "0,2 Instant 1577966400000000", "0,3 Instant 1577923200000000",
      "0,4 Instant 1577916000000000", "0,6 Time 45296000000", "0,7 Time 93600000000",
      "0,8 Time 45240000000", "0,9 Time 3900000000", "0,10 Time 45296789123", "0,13 Time 0",
    ],
  )
  // A formula cell reads its cached value, never its formula; with no cached value it is empty.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xcell(
            " table:formula=\"of:=1+2\" office:value-type=\"float\" office:value=\"3\"",
            xp("3"),
          ) +
          xcell(
            " table:formula=\"of:=NA()\" office:value-type=\"string\" office:string-value=\"\"",
            xp("#N/A"),
          ) +
          xcell(" table:formula=\"of:=1/0\"", xp("#DIV/0!")) +
          xcell(
            " table:formula=\"of:=TODAY()\" office:value-type=\"date\" office:date-value=\"2020-01-02\"",
            "",
          ),
        ),
      ),
    ),
    ["0,0 Number 4008000000000000", "0,3 Day 18263"],
  )
}
