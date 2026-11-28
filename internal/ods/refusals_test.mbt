// Blackbox tests of the refusals the fixtures do not carry, each by
// variant and by exact text. A byte a message names is found in the bytes
// the test built — never taken on trust — and what a message quotes from
// the XML reader is the reader's own rendering of the same text.

///|
/// Where `attribute` starts in a content.xml the test built, in bytes.
fn at_of(content : Bytes, attribute : String) -> Int32 raise Failure {
  let at = index_of(content, @utf8.encode(attribute))
  if at < 0 {
    fail("\{attribute} is not spelled in the content the test built")
  }
  at
}

///|
/// The XML reader's rendering of its first refusal over `text` — what a
/// refusal of the codec quotes after the byte.
fn reader_says(text : String) -> String {
  let reader = @xml.NamespaceReader::from_string(text)
  let outcome : Result[@xml.NamespaceEvent, @xml.XmlError] = Ok(
    reader.read_event(),
  ) catch {
    e => Err(e)
  }
  let mut last = outcome
  for ;; {
    match last {
      Err(error) => return "\{error}"
      Ok(event) =>
        if event.kind is Eof {
          return "<no refusal>"
        } else {
          last = Ok(reader.read_event()) catch { e => Err(e) }
        }
    }
  }
  "<no refusal>"
}

///|
test "a content.xml in UTF-16 cut inside a code unit, or holding a lone surrogate, is refused by the byte" {
  let whole = utf16("<a/>", false, true)
  let cut = whole + b"A"
  refusal_is(
    only_content(cut),
    "ParseError",
    "ods: content.xml byte \{whole.length()} is not valid UTF-16: an odd number of bytes or a lone surrogate",
  )
  // The mark is two bytes; a lone high surrogate follows it.
  let lone = b"\xff\xfe\x00\xd8" + utf16("<a/>", false, false)
  refusal_is(
    only_content(lone),
    "ParseError",
    "ods: content.xml byte 2 is not valid UTF-16: an odd number of bytes or a lone surrogate",
  )
  // A high surrogate with a character that is no low surrogate after it:
  // the mark, two code units, then the surrogate.
  let pair = utf16("ab", false, true) + b"\x00\xd8" + utf16("x", false, false)
  refusal_is(
    only_content(pair),
    "ParseError",
    "ods: content.xml byte 6 is not valid UTF-16: an odd number of bytes or a lone surrogate",
  )
}

///|
test "a declared encoding other than UTF-8 is refused by name; UTF-8's own spellings read" {
  for
    declared in [
      "UTF-16", "Windows-1252", "ISO-8859-1", "US-ASCII", "Shift_JIS",
    ] {
    let content = swapped(
      document(""),
      "encoding=\"UTF-8\"",
      "encoding=\"\{declared}\"",
    )
    refusal_is(
      spreadsheet(content),
      "Unsupported",
      "ods: content.xml declares the \{declared.to_lower()} encoding, which this reader does not decode",
    )
  }
  for
    declared in [
      "encoding=\"utf8\"", "encoding='UTF-8'", "encoding = \"Utf-8\"", "encoding=\"utf-8\"",
    ] {
    let content = swapped(
      document(xtable("S", xrow(xnumber("1")))),
      "encoding=\"UTF-8\"",
      declared,
    )
    cells_are(spreadsheet(content), ["0,0 Number 3ff0000000000000"])
  }
  // No declaration at all: UTF-8.
  let bare = swapped(
    document(xtable("S", xrow(xnumber("1")))),
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "",
  )
  cells_are(spreadsheet(bare), ["0,0 Number 3ff0000000000000"])
}

///|
test "a byte that is not UTF-8 is refused by its byte, after characters that take several" {
  let content = @utf8.encode(
    document(xtable("S", xrow(xstring(xp("日本語🎉 cafX"))))),
  )
  let at = at_of(content, "cafX")
  let broken = content[0:at].to_owned() +
    b"caf\xe9" +
    content[at + 4:].to_owned()
  refusal_is(
    only_content(broken),
    "ParseError",
    "ods: content.xml byte \{at + 3} is not valid UTF-8",
  )
  // The first of several is the one named.
  let twice = content[0:at].to_owned() +
    b"\xe9\xe9" +
    content[at + 4:].to_owned()
  refusal_is(
    only_content(twice),
    "ParseError",
    "ods: content.xml byte \{at} is not valid UTF-8",
  )
}

///|
test "the byte a refusal names is a byte of the entry: past a UTF-8 mark, and in UTF-16 both ways" {
  let content = document(
    xtable(
      "S",
      xrow(
        xcell(
          " office:value-type=\"date\" office:date-value=\"2020-13-01\"",
          xp("x"),
        ),
      ),
    ),
  )
  let at = at_of(@utf8.encode(content), "office:date-value")
  let marked = b"\xef\xbb\xbf" + @utf8.encode(content)
  refusal_is(
    only_content(marked),
    "ParseError",
    "ods: content.xml byte \{at + 3}: the office:date-value attribute \"2020-13-01\" is not a date",
  )
  // In UTF-16 the attribute is found by its own two-byte units.
  let little = utf16(content, false, true)
  let at = index_of(little, utf16("office:date-value", false, false))
  refusal_is(
    only_content(little),
    "ParseError",
    "ods: content.xml byte \{at}: the office:date-value attribute \"2020-13-01\" is not a date",
  )
  let big = utf16(content, true, true)
  let at = index_of(big, utf16("office:date-value", true, false))
  refusal_is(
    only_content(big),
    "ParseError",
    "ods: content.xml byte \{at}: the office:date-value attribute \"2020-13-01\" is not a date",
  )
  // A UTF-16 entry without its mark is not UTF-16 to anyone: it reads as
  // UTF-8 with NUL characters in it, and the XML reader refuses it.
  let unmarked = utf16(document(xtable("S", xrow(xnumber("1")))), false, false)
  let shown = reader_says(@utf8.decode(unmarked))
  refusal_is(
    only_content(unmarked),
    "ParseError",
    "ods: content.xml byte 0 is not well-formed: \{shown}",
  )
}

///|
test "a mimetype that is not the spreadsheet's is refused by what it says, cut or in hexadecimal" {
  let entries : Array[(String, Bytes)] = [
    ("content.xml", @utf8.encode(document(""))),
  ]
  refusal_is(
    with_mimetype(entries, @utf8.encode("a".repeat(70))),
    "Unsupported",
    "ods: the package's mimetype is \"\{"a".repeat(64)}...\", not an OpenDocument spreadsheet's",
  )
  refusal_is(
    with_mimetype(entries, @utf8.encode("b".repeat(300))),
    "Unsupported",
    "ods: the package's mimetype is \"\{"b".repeat(64)}...\", not an OpenDocument spreadsheet's",
  )
  let hex = Bytes::makei(17, i => (0x80 + i).to_byte())
  refusal_is(
    with_mimetype(entries, hex),
    "Unsupported",
    "ods: the package's mimetype is \"\\x80\\x81\\x82\\x83\\x84\\x85\\x86\\x87\\x88\\x89\\x8A\\x8B\\x8C\\x8D\\x8E\\x8F...\", not an OpenDocument spreadsheet's",
  )
  refusal_is(
    with_mimetype(entries, b""),
    "Unsupported",
    "ods: the package's mimetype is \"\", not an OpenDocument spreadsheet's",
  )
  // The 46 bytes and nothing else: a line break after them is not the type.
  let body = xtable("S", xrow(xnumber("1")))
  refusal_is(
    with_mimetype(
      [("content.xml", @utf8.encode(document(body)))],
      @utf8.encode("\{MIMETYPE}\n"),
    ),
    "Unsupported",
    "ods: the package's mimetype is \"\{MIMETYPE}\n\", not an OpenDocument spreadsheet's",
  )
  // A mimetype that is a prefix of it, or longer.
  for
    wrong in [
      "application/vnd.oasis.opendocument.spreadsheetx", "application/vnd.oasis.opendocument.spreadsheet-template",
      " application/vnd.oasis.opendocument.spreadsheet",
    ] {
    refusal_is(
      with_mimetype(
        [("content.xml", @utf8.encode(document(body)))],
        @utf8.encode(wrong),
      ),
      "Unsupported",
      "ods: the package's mimetype is \"\{wrong}\", not an OpenDocument spreadsheet's",
    )
  }
}

///|
test "an entry the ZIP reader will not open, and an entry past the scratch buffer, are named or passed over" {
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(MIMETYPE), compression=Store)
  archive.add("content.xml", @utf8.encode(document("")))
  let whole = @zip.write(archive) catch { _ => b"" }
  // content.xml's compression method, in its local header and in its
  // directory record, made 99: the method field is 22 bytes before the
  // name in the one and 36 before it in the other.
  let name = index_of(whole, b"content.xml")
  let central = name +
    11 +
    index_of(whole[name + 11:].to_owned(), b"content.xml")
  let patched = Bytes::makei(whole.length(), i => {
    if i == name - 22 || i == central - 36 {
      99
    } else {
      whole[i]
    }
  })
  let outcome : Result[_, @zip.ZipError] = Ok(@zip.read(patched)) catch {
    e => Err(e)
  }
  match outcome {
    Err(@zip.ZipError(_, message)) =>
      refusal_is(
        patched,
        "ParseError",
        "ods: the package is a broken ZIP archive: \{message}",
      )
    Ok(_) => fail("the archive read back with an entry of method 99")
  }
  // A stored entry of 70 KB with one byte flipped after the archive was
  // built: the entry named is the broken one, not the small ones beside it.
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(MIMETYPE), compression=Store)
  archive.add("big.bin", Bytes::makei(70000, _ => b'a'), compression=Store)
  archive.add("content.xml", @utf8.encode(document("")))
  let whole = @zip.write(archive) catch { _ => b"" }
  let name = index_of(whole, b"big.bin")
  let extra = whole[name - 2].to_int() + (whole[name - 1].to_int() << 8)
  let data = name + 7 + extra
  let flipped = Bytes::makei(whole.length(), i => {
    if i == data + 65570 {
      b'b'
    } else {
      whole[i]
    }
  })
  refusal_is(
    flipped, "ParseError", "ods: the package's entry \"big.bin\" is broken: zip: CRC-32 mismatch",
  )
  // A deflated entry of 200 KB that does not compress: its compressed
  // bytes come in ranges of 64 KB, each filling the locator's buffer
  // before it is spent, so the buffer is emptied and refilled; a byte
  // flipped inside its first block makes its checksum wrong at the end.
  let noise = Bytes::makei(200000, i => {
    let mixed = (i.reinterpret_as_uint() * 2654435761U) >> 13
    mixed.to_byte()
  })
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(MIMETYPE), compression=Store)
  archive.add("big.bin", noise)
  archive.add("content.xml", @utf8.encode(document("")))
  let whole = @zip.write(archive) catch { _ => b"" }
  let name = index_of(whole, b"big.bin")
  let extra = whole[name - 2].to_int() + (whole[name - 1].to_int() << 8)
  let data = name + 7 + extra
  let flipped = Bytes::makei(whole.length(), i => {
    if i == data + 100 {
      whole[i] ^ 0x5A
    } else {
      whole[i]
    }
  })
  if flipped[data + 100] == whole[data + 100] {
    fail("the flipped byte is the byte it was")
  }
  let outcome : Result[_, @zip.ZipError] = Ok(@zip.read(flipped)) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the archive read back with a flipped byte in big.bin")
    Err(@zip.ZipError(_, message)) =>
      refusal_is(
        flipped,
        "ParseError",
        "ods: the package's entry \"big.bin\" is broken: \{message}",
      )
  }
}

///|
test "where no mimetype entry judges the package, content.xml's root does" {
  let entries : Array[(String, Bytes)] = [
    ("content.xml", @utf8.encode(document(""))),
  ]
  // An empty mimetype entry is an entry: its bytes are judged.
  refusal_is(
    zip(entries, b""),
    "Unsupported",
    "ods: the package's mimetype is \"\", not an OpenDocument spreadsheet's",
  )
  let flat = swapped(document(""), "office:document-content", "office:document")
  refusal_is(
    zip([("content.xml", @utf8.encode(flat))], b"no mimetype here"),
    "Unsupported",
    "ods: the package's mimetype is \"no mimetype here\", not an OpenDocument spreadsheet's",
  )
  // Without the entry at all: an archive holding content.xml alone.
  let archive = @zip.Archive::Archive()
  archive.add("content.xml", @utf8.encode(flat))
  let without = @zip.write(archive) catch { _ => b"" }
  refusal_is(
    without, "Unsupported", "ods: content.xml's root element is \"office:document\", not an OpenDocument document-content element",
  )
  // The same with content.xml not first: the entry is looked up by name.
  let archive = @zip.Archive::Archive()
  archive.add("readme.txt", b"nothing")
  archive.add("content.xml", @utf8.encode(document("")))
  let sheets = @zip.write(archive) catch { _ => b"" }
  assert_eq(sheet_names(sheets), [])
  let archive = @zip.Archive::Archive()
  archive.add("meta.xml", @utf8.encode(document("")))
  refusal_is(
    @zip.write(archive) catch {
      _ => b""
    },
    "Unsupported",
    "ods: the package holds neither a mimetype nor a content.xml, so it is not an OpenDocument package",
  )
  for
    (root, shown) in [
      ("<html/>", "html"),
      ("<x:a xmlns:x='urn:example:x'/>", "x:a"),
      (
        "<office:document-styles xmlns:office=\"\{OFFICE_NS}\"/>",
        "office:document-styles",
      ),
    ] {
    let archive = @zip.Archive::Archive()
    archive.add("content.xml", @utf8.encode(root))
    refusal_is(
      @zip.write(archive) catch {
        _ => b""
      },
      "Unsupported",
      "ods: content.xml's root element is \"\{shown}\", not an OpenDocument document-content element",
    )
  }
  let typed = swapped(
    document(""),
    " office:version=\"1.2\">",
    " office:version=\"1.2\" office:mimetype=\"application/vnd.oasis.opendocument.chart\">",
  )
  let archive = @zip.Archive::Archive()
  archive.add("content.xml", @utf8.encode(typed))
  refusal_is(
    @zip.write(archive) catch {
      _ => b""
    },
    "Unsupported",
    "ods: content.xml's office:mimetype is \"application/vnd.oasis.opendocument.chart\", not an OpenDocument spreadsheet's",
  )
  let empty = swapped(
    document(""),
    " office:version=\"1.2\">",
    " office:version=\"1.2\" office:mimetype=\"\">",
  )
  let archive = @zip.Archive::Archive()
  archive.add("content.xml", @utf8.encode(empty))
  refusal_is(
    @zip.write(archive) catch {
      _ => b""
    },
    "Unsupported",
    "ods: content.xml's office:mimetype is \"\", not an OpenDocument spreadsheet's",
  )
}

///|
test "a package that is neither an OpenDocument one nor an Office Open XML one is refused as such" {
  let archive = @zip.Archive::Archive()
  archive.add("hello.txt", b"hello")
  refusal_is(
    @zip.write(archive) catch {
      _ => b""
    },
    "Unsupported",
    "ods: the package holds neither a mimetype nor a content.xml, so it is not an OpenDocument package",
  )
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(MIMETYPE), compression=Store)
  archive.add("readme.txt", b"nothing to read")
  refusal_is(
    @zip.write(archive) catch {
      _ => b""
    },
    "ParseError",
    "ods: the package's mimetype is an OpenDocument spreadsheet's, but it holds no content.xml",
  )
  // An Office Open XML package: [Content_Types].xml, a stylesheet, a sheet.
  let archive = @zip.Archive::Archive()
  archive.add("[Content_Types].xml", b"<Types/>")
  archive.add("xl/workbook.xml", b"<workbook/>")
  refusal_is(
    @zip.write(archive) catch {
      _ => b""
    },
    "Unsupported",
    "ods: the package holds an Office Open XML [Content_Types].xml and no content.xml, so it is not an OpenDocument package",
  )
  // A second entry of the same name changes nothing: the first is read.
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(MIMETYPE), compression=Store)
  archive.add("content.xml", @utf8.encode(document("")))
  archive.add("content.xml", b"<broken>")
  assert_eq(sheet_names(@zip.write(archive) catch { _ => b"" }), [])
}

///|
test "a cell of a number type with no number is refused by the cell's byte, naming its type" {
  for kind in ["float", "percentage", "currency"] {
    let content = document(
      xtable("S", xrow(xcell(" office:value-type=\"\{kind}\"", xp("7")))),
    )
    let at = at_of(
      @utf8.encode(content),
      "<table:table-cell office:value-type=\"\{kind}\"",
    )
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at}: a \{kind} cell carries no office:value",
    )
  }
  for
    (kind, value, attribute) in [
      ("float", "1e400", "office:value"),
      ("float", "inf", "office:value"),
      ("percentage", "", "office:value"),
      ("currency", "N/A", "office:value"),
    ] {
    let content = document(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"\{kind}\" office:value=\"\{value}\"",
            xp("7"),
          ),
        ),
      ),
    )
    let at = at_of(@utf8.encode(content), "\{attribute}=\"\{value}\"")
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at}: the \{attribute} attribute \"\{value}\" is not a number",
    )
  }
}

///|
test "a date, a time value or a clock reading that does not parse is refused by its attribute's byte" {
  for
    bad in [
      "2020-13-01", "12:34:56", "2020-01-02T24:00:00", "2020-01-02T12:34:56+25:00",
      "10000-01-01",
    ] {
    let content = document(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"date\" office:date-value=\"\{bad}\"",
            xp("x"),
          ),
        ),
      ),
    )
    let at = at_of(@utf8.encode(content), "office:date-value=\"\{bad}\"")
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at}: the office:date-value attribute \"\{bad}\" is not a date",
    )
  }
  for bad in ["P1Y", "PT", "-PT1H", "PT12.5H", "PT999999999999999999D"] {
    let content = document(
      xtable(
        "S",
        xrow(
          xcell(
            " office:value-type=\"time\" office:time-value=\"\{bad}\"",
            xp("x"),
          ),
        ),
      ),
    )
    let at = at_of(@utf8.encode(content), "office:time-value=\"\{bad}\"")
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at}: the office:time-value attribute \"\{bad}\" is not a time value",
    )
  }
  // A time cell with no value reads its text; a text that is no clock
  // reading is refused by the cell's byte.
  for
    bad in [
      "noon", "24:00:00", "12:34:56Z", "2020-01-02 12:34:56", "PT12H34M56S",
    ] {
    let opening = "<table:table-cell office:value-type=\"time\"><text:p>\{bad}</text:p>"
    let content = document(xtable("S", xrow("\{opening}</table:table-cell>")))
    let at = at_of(@utf8.encode(content), opening)
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at}: the text of a time cell, \"\{bad}\", is not a clock reading",
    )
  }
}

///|
test "a repeat count that spells no number, or more than the reader takes, is refused by the attribute's byte" {
  for
    (attribute, value, wrong) in [
      ("table:number-columns-repeated", "", "is not a whole number"),
      ("table:number-columns-repeated", "-2", "is not a whole number"),
      ("table:number-columns-repeated", "abc", "is not a whole number"),
      ("table:number-columns-repeated", " 2", "is not a whole number"),
      (
        "table:number-columns-repeated", "2147483648", "is past the largest count this reader takes",
      ),
    ] {
    let content = document(
      xtable("S", xrow("<table:table-cell \{attribute}=\"\{value}\"/>")),
    )
    let at = at_of(@utf8.encode(content), "\{attribute}=\"\{value}\"")
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at}: the \{attribute} attribute \"\{value}\" \{wrong}",
    )
  }
  // On a row: the same.
  let content = document(
    "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"-1\"><table:table-cell office:value-type=\"float\" office:value=\"1\"/></table:table-row></table:table>",
  )
  let at = at_of(@utf8.encode(content), "table:number-rows-repeated=\"-1\"")
  refusal_is(
    spreadsheet(content),
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-rows-repeated attribute \"-1\" is not a whole number",
  )
}

///|
test "a repeat count that would make a sheet hold more cells than the budget is refused, naming the attribute" {
  // A hundred thousand rows, one cell each, in a package of a few hundred
  // bytes; the largest count the reader takes is fine where nothing is held.
  let big = "70000"
  let content = document(
    "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"\{big}\"><table:table-cell office:value-type=\"float\" office:value=\"1\"/></table:table-row></table:table>",
  )
  let bytes = spreadsheet(content)
  let at = at_of(@utf8.encode(content), "table:number-rows-repeated=\"\{big}\"")
  refusal_is(
    bytes,
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-rows-repeated attribute \"\{big}\" would make sheet \"S\" hold more cells than this reader grants a package of \{bytes.length()} bytes (\{budget_of(bytes.length())})",
  )
  // Along a row: two cells of 50 000 columns each, the second one's count
  // the last read before the sheet is measured.
  let wide = "50000"
  let second = "<table:table-cell office:value-type=\"float\" office:value=\"2\" table:number-columns-repeated=\"\{wide}\"/>"
  let content = document(
    xtable(
      "S",
      xrow(
        "<table:table-cell office:value-type=\"float\" office:value=\"1\" table:number-columns-repeated=\"\{wide}\"/>\{second}",
      ),
    ),
  )
  let bytes = spreadsheet(content)
  let at = at_of(
    @utf8.encode(content),
    "table:number-columns-repeated=\"\{wide}\"/></table:table-row>",
  )
  refusal_is(
    bytes,
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-columns-repeated attribute \"\{wide}\" would make sheet \"S\" hold more cells than this reader grants a package of \{bytes.length()} bytes (\{budget_of(bytes.length())})",
  )
  // A row of 40 000 cells and 3 000 such rows: 120 000 000 cells in a
  // rectangle, though 40 001 are spelled. It is the last count the sheet
  // read — the cell's — that the refusal names.
  let rows = "3000"
  let content = document(
    "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"\{rows}\"><table:table-cell office:value-type=\"float\" office:value=\"1\" table:number-columns-repeated=\"40000\"/></table:table-row></table:table>",
  )
  let bytes = spreadsheet(content)
  let at = at_of(
    @utf8.encode(content),
    "table:number-columns-repeated=\"40000\"",
  )
  refusal_is(
    bytes,
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-columns-repeated attribute \"40000\" would make sheet \"S\" hold more cells than this reader grants a package of \{bytes.length()} bytes (\{budget_of(bytes.length())})",
  )
  // A sheet's name in that message is the name as spelled, quotes and all.
  let name = "The &quot;big&quot; sheet"
  let content = document(
    "<table:table table:name=\"\{name}\"><table:table-row table:number-rows-repeated=\"\{big}\"><table:table-cell office:value-type=\"float\" office:value=\"1\"/></table:table-row></table:table>",
  )
  let bytes = spreadsheet(content)
  let at = at_of(@utf8.encode(content), "table:number-rows-repeated=\"\{big}\"")
  refusal_is(
    bytes,
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-rows-repeated attribute \"\{big}\" would make sheet \"The \"big\" sheet\" hold more cells than this reader grants a package of \{bytes.length()} bytes (\{budget_of(bytes.length())})",
  )
}

///|
test "a text:s made to spell more spaces than the budget is refused; a text:c that spells no count, too" {
  let spaces = "<text:s text:c=\"2147483647\"/>"
  let content = document(xtable("S", xrow(xstring(xp(spaces)))))
  let bytes = spreadsheet(content)
  let at = at_of(@utf8.encode(content), spaces)
  refusal_is(
    bytes,
    "ParseError",
    "ods: content.xml byte \{at + 8}: the text:c attribute \"2147483647\" would spell more spaces than this reader grants a package of \{bytes.length()} bytes (\{budget_of(bytes.length())})",
  )
  for value in ["", "x", "-1", "2147483648"] {
    let wrong = if value == "2147483648" {
      "is past the largest count this reader takes"
    } else {
      "is not a whole number"
    }
    let spaces = "<text:s text:c=\"\{value}\"/>"
    let content = document(xtable("S", xrow(xstring(xp(spaces)))))
    let at = at_of(@utf8.encode(content), spaces)
    refusal_is(
      spreadsheet(content),
      "ParseError",
      "ods: content.xml byte \{at + 8}: the text:c attribute \"\{value}\" \{wrong}",
    )
  }
}

///|
/// The refusal the codec gives for a content.xml that is not well-formed,
/// checked against the XML reader's own position and rendering over the
/// same text — ASCII, so that a code unit of the reader is a byte.
fn ill_formed_as(content : String) -> Unit raise Failure {
  let reader = @xml.NamespaceReader::from_string(content)
  let outcome : Result[_, @xml.XmlError] = Ok(reader.read_event()) catch {
    e => Err(e)
  }
  let mut last = outcome
  let mut found : (Int32, String)? = None
  for ;; {
    match last {
      Err(whole) =>
        match whole {
          At(error~, span~) => {
            ignore(error)
            found = Some((span.start.offset, "\{whole}"))
            break
          }
        }
      Ok(event) =>
        if event.kind is Eof {
          break
        } else {
          last = Ok(reader.read_event()) catch { e => Err(e) }
        }
    }
  }
  match found {
    None => fail("\{content}: the XML reader raised nothing")
    Some((at, shown)) =>
      refusal_is(
        spreadsheet(content),
        "ParseError",
        "ods: content.xml byte \{at} is not well-formed: \{shown}",
      )
  }
}

///|
test "a content.xml that is not well-formed is refused by its byte, quoting the XML reader" {
  for
    broken in [
      "<a><b></a>", "<a>&foo;</a>", "<a><!-- x -- y --></a>", "<a><![CDATA[never closed</a>",
      "<a x='1' x='2'/>", "<table:table-row><foo", "<a>\t<c></a>  <d/>",
    ] {
    ill_formed_as(document(broken))
  }
  // Broken on its own: two roots, text after the root, nothing to be the
  // root at all, and a document cut inside a tag.
  for
    bare in [
      "<a/><b/>", "<a>x</a>junk", "", " ", "\n", "<!-- only a comment -->", "<?pi data?>",
      "<a", "<a x", "<a x=", "<a x='", "<!--", "<![CDATA[x",
    ] {
    ill_formed_as(bare)
  }
  // After characters that take several bytes each, the byte is still a byte.
  let broken = document("<a>日本語🎉<b></a>")
  let shown = reader_says(broken)
  let at = at_of(@utf8.encode(broken), "</a>")
  refusal_is(
    spreadsheet(broken),
    "ParseError",
    "ods: content.xml byte \{at} is not well-formed: \{shown}",
  )
}
