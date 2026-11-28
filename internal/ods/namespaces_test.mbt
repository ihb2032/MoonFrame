// Blackbox tests of the namespaces: an element or an attribute is the one
// the format names by the namespace it is bound to, never by the prefix a
// document happens to spell — and never by its local name alone.

///|
/// content.xml with `declarations` on its root element `open` (closed by
/// `close`), the office namespace under the prefix `office`, and `body`
/// inside the body.
fn rooted(
  declarations : String,
  open : String,
  close : String,
  office : String,
  body : String,
) -> String {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<\{open} \{declarations} \{office}:version=\"1.2\">" +
  "<\{office}:body><\{office}:spreadsheet>\{body}</\{office}:spreadsheet></\{office}:body></\{close}>"
}

///|
test "the table namespace as the default one, the office one under a prefix of its own" {
  let content = rooted(
    "xmlns:office=\"\{OFFICE_NS}\" xmlns:table=\"\{TABLE_NS}\" xmlns=\"" +
    TABLE_NS +
    "\" xmlns:text=\"\{TEXT_NS}\"",
    "office:document-content",
    "office:document-content",
    "office",
    "<table table:name=\"S\"><table-row><table-cell office:value-type=\"float\" office:value=\"1\"/><table-cell office:value-type=\"string\"><text:p>x</text:p></table-cell></table-row></table>",
  )
  cells_are(spreadsheet(content), ["0,0 Number 3ff0000000000000", "0,1 Text x"])
  assert_eq(sheet_names(spreadsheet(content)), ["S"])
  let content = rooted(
    "xmlns:o=\"\{OFFICE_NS}\" xmlns:t=\"\{TABLE_NS}\" xmlns:x=\"\{TEXT_NS}\"",
    "o:document-content",
    "o:document-content",
    "o",
    "<t:table t:name=\"S\"><t:table-row><t:table-cell o:value-type=\"float\" o:value=\"1\" t:number-columns-repeated=\"2\"/><t:table-cell o:value-type=\"string\"><x:p>a<x:s x:c=\"2\"/>b</x:p><x:p>c</x:p></t:table-cell></t:table-row></t:table>",
  )
  cells_are(spreadsheet(content), [
    "0,0 Number 3ff0000000000000", "0,1 Number 3ff0000000000000", "0,2 Text a  b\nc",
  ])
  assert_eq(sheet_names(spreadsheet(content)), ["S"])
}

///|
test "a prefix that looks like the format's but is bound elsewhere names nothing" {
  let hijacked = swapped(
    document(xtable("S", xrow(xnumber("1")))),
    "xmlns:table=\"" + TABLE_NS + "\"",
    "xmlns:table=\"urn:example:t\"",
  )
  assert_eq(sheet_names(spreadsheet(hijacked)), [])
  // The office namespace under the prefix `table`: the table and its rows
  // are read, the attributes they carry in that prefix are not.
  let crossed = document(xtable("S", xrow(xnumber("1"))))
    .replace(
      old="xmlns:table=\"" + TABLE_NS + "\"",
      new="xmlns:t=\"" + TABLE_NS + "\" xmlns:table=\"" + OFFICE_NS + "\"",
    )
    .replace(old="<table:table ", new="<t:table ")
    .replace(old="table:name=", new="t:name=")
    .replace(old="<table:table-row>", new="<t:table-row>")
    .replace(old="</table:table-row>", new="</t:table-row>")
    .replace(old="</table:table>", new="</t:table>")
    .replace(old="office:value-type", new="table:value-type")
    .replace(old="office:value", new="table:value")
  assert_eq(sheet_names(spreadsheet(crossed)), ["S"])
  cells_are(spreadsheet(crossed), [])
}

///|
test "an attribute with the right local name and no namespace, or the wrong one, is not read" {
  let one = xnumber("1")
  let second = "<table:table-cell office:value-type=\"float\" office:value=\"2\" "
  cells_are(
    body_package(
      xtable("S", xrow(one + second + "number-columns-repeated=\"3\"/>")),
    ),
    ["0,0 Number 3ff0000000000000", "0,1 Number 4000000000000000"],
  )
  cells_are(
    body_package(
      xtable("S", xrow(one + second + "text:number-columns-repeated=\"3\"/>")),
    ),
    ["0,0 Number 3ff0000000000000", "0,1 Number 4000000000000000"],
  )
  // A row count in the office namespace on the row is not a count.
  let row = swapped(
    swapped(xrow(xnumber("1")), "<table:table-row>", ""),
    "</table:table-row>",
    "",
  )
  cells_are(
    body_package(
      xtable(
        "S",
        "<table:table-row office:number-rows-repeated=\"3\">\{row}</table:table-row>",
      ),
    ),
    ["0,0 Number 3ff0000000000000"],
  )
  // A value attribute in another namespace is no value.
  let unvalued = xcell(
    " office:value-type=\"float\" table:value=\"5\"",
    xp("5"),
  )
  let content = document(xtable("S", xrow(unvalued)))
  let at = at_of(
    @utf8.encode(content),
    "<table:table-cell office:value-type=\"float\" table:value",
  )
  refusal_is(
    spreadsheet(content),
    "ParseError",
    "ods: content.xml byte \{at}: a float cell carries no office:value",
  )
}
