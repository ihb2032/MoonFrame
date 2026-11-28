// Blackbox tests of what surrounds a sheet in content.xml: the prolog and
// the epilog the XML specification allows, the line ends a document may
// use, and the encodings the reader decodes.

///|
test "comments, processing instructions and line ends wherever XML allows them change nothing" {
  let body = xtable(
    "S",
    xrow(xtext("plain") + xstring("<text:p>a<text:line-break/>b</text:p>")),
  )
  let wanted = ["0,0 Text plain", "0,1 Text a\nb"]
  let decorated = swapped(
    swapped(
      document(body),
      "?>\n",
      "?>\n<!-- before the root -->\n<?some-pi data?>\n",
    ),
    "<office:body>",
    "<!-- in the root --><?pi2?><office:body><!-- in the body -->",
  )
  cells_are(spreadsheet(decorated), wanted)
  // A comment or whitespace after the root is the epilog; text is not.
  cells_are(
    spreadsheet(document(body) + "\n<!-- after the root -->\n \t\n"),
    wanted,
  )
  ill_formed_as(document(body) + "\njunk\n")
  // Carriage returns before line feeds, and either declaration spelling.
  cells_are(spreadsheet(swapped(document(body), "\n", "\r\n")), wanted)
  cells_are(
    spreadsheet(
      swapped(
        document(body),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<?xml version='1.0' encoding='utf-8' standalone='yes'?>",
      ),
    ),
    wanted,
  )
  // An indentation puts whitespace inside a string cell, and it stays: a
  // line break at a text node's ends goes, the spaces beside it do not.
  let pretty = document(
    "<table:table table:name=\"S\">\r\n  <table:table-row>\r\n    <table:table-cell office:value-type=\"string\">\r\n      <text:p>indented</text:p>\r\n    </table:table-cell>\r\n  </table:table-row>\r\n</table:table>",
  )
  cells_are(spreadsheet(pretty), ["0,0 Text       indented    "])
  cells_are(spreadsheet(swapped(pretty, "\r\n", "\n")), [
    "0,0 Text       indented    ",
  ])
  // A character reference keeps a carriage return and a tab as themselves,
  // where a carriage return written as itself becomes a line feed.
  cells_are(
    body_package(xtable("S", xrow(xstring(xp("a&#13;b&#9;c&#160;d"))))),
    ["0,0 Text a\rb\tc\u{a0}d"],
  )
  cells_are(body_package(xtable("S", xrow(xstring(xp("a\rb"))))), [
    "0,0 Text a\nb",
  ])
}

///|
test "the byte-order mark, UTF-16 in either byte order, and a UTF-16 declaration all read" {
  let body = xtable("S", xrow(xtext("plain 日本 🎉") + xnumber("1.5")))
  let wanted = ["0,0 Text plain 日本 🎉", "0,1 Number 3ff8000000000000"]
  cells_are(
    only_content(b"\xef\xbb\xbf" + @utf8.encode(document(body))),
    wanted,
  )
  // Without the declaration's encoding name.
  cells_are(
    only_content(
      @utf8.encode(swapped(document(body), " encoding=\"UTF-8\"", "")),
    ),
    wanted,
  )
  cells_are(only_content(utf16(document(body), false, true)), wanted)
  cells_are(only_content(utf16(document(body), true, true)), wanted)
  // Declaring UTF-16, as a UTF-16 document does.
  let declared = swapped(
    document(body),
    "encoding=\"UTF-8\"",
    "encoding=\"UTF-16\"",
  )
  cells_are(only_content(utf16(declared, false, true)), wanted)
  cells_are(only_content(utf16(declared, true, true)), wanted)
  // The same declared UTF-16 in single-byte UTF-8 bytes is not UTF-16:
  // refused by name.
  refusal_is(
    spreadsheet(declared),
    "Unsupported",
    "ods: content.xml declares the utf-16 encoding, which this reader does not decode",
  )
  // UTF-16LE bytes under a UTF-16BE mark, and the other way round: each
  // is refused as text that is not well formed, since the XML reader sees
  // the code units swapped.
  let swapped_order = utf16(document(body), false, false)
  let bytes = Bytes::makei(swapped_order.length(), i => {
    if i % 2 == 0 {
      swapped_order[i + 1]
    } else {
      swapped_order[i - 1]
    }
  })
  let shown = reader_says(@utf16.decode(bytes, endianness=Little))
  refusal_is(
    only_content(b"\xff\xfe" + bytes),
    "ParseError",
    "ods: content.xml byte 2 is not well-formed: \{shown}",
  )
}

///|
test "a document type declaration is taken as XML takes it: an entity it declares is expanded" {
  let body = xtable(
    "S",
    xrow(
      xstring("<text:p>&un; &amp; &apos;x&apos; &#65;</text:p>") + xtext("b"),
    ),
  )
  let with_doctype = swapped(
    document(body),
    "?>\n<office:document-content",
    "?>\n<!DOCTYPE office:document-content [<!ENTITY un \"uno\">]>\n<office:document-content",
  )
  cells_are(spreadsheet(with_doctype), ["0,0 Text uno & 'x' A", "0,1 Text b"])
  // An external entity is not fetched: a document naming one is refused
  // by the XML reader, for a reference to an entity it cannot resolve.
  let external = swapped(
    document(xtext("&ext;")),
    "?>\n<office:document-content",
    "?>\n<!DOCTYPE office:document-content [<!ENTITY ext SYSTEM \"elsewhere.xml\">]>\n<office:document-content",
  )
  ill_formed_as(external)
  // Nothing outside the document is read: a sheet's text is only what the
  // document itself spells, entities included.
  let nested = swapped(
    document(xtable("S", xrow(xstring("<text:p>&un;&un;</text:p>")))),
    "?>\n<office:document-content",
    "?>\n<!DOCTYPE office:document-content [<!ENTITY un \"<text:span>x</text:span>\">]>\n<office:document-content",
  )
  cells_are(spreadsheet(nested), ["0,0 Text xx"])
}
