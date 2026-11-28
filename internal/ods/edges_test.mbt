// Blackbox tests at the edges: a sheet with nothing in it, a column of
// nothing but missing values, names and strings as long as the format
// allows them, the positions repeats give cells, rows wherever the format
// puts them, namespaces as the format binds them, every kind of value the
// format spells, and the budget's own edge.

///|
test "a sheet with nothing in it holds no cell, and is still a sheet" {
  cells_are(body_package(xtable("Empty", "")), [])
  cells_are(body_package(xtable("Empty", xrow("") + xrow(xcell("", "")))), [])
  // Rows and columns declared, no value anywhere.
  cells_are(
    body_package(
      "<table:table table:name=\"Empty\"><table:table-column table:number-columns-repeated=\"5\"/><table:table-row table:number-rows-repeated=\"3\"><table:table-cell table:number-columns-repeated=\"5\"/></table:table-row></table:table>",
    ),
    [],
  )
  let sheets = sheet_names(
    body_package(xtable("Empty", "") + xtable("Full", xrow(xnumber("1")))),
  )
  assert_eq(sheets, ["Empty", "Full"])
  // A table with no name, and two of one name.
  let sheets = sheet_names(
    body_package(xtable("", "") + xtable("T", "") + xtable("T", "")),
  )
  assert_eq(sheets, ["", "T", "T"])
  // A whole spreadsheet with no table: no sheet.
  assert_eq(sheet_names(body_package("")), [])
  assert_eq(sheet_names(body_package("<table:calculation-settings/>")), [])
}

///|
test "a column of nothing but missing values holds no cell, and the columns beside it keep their places" {
  let missing = xstring(xp("#N/A")) +
    xstring(xp("")) +
    xcell(" office:value-type=\"void\"", xp("x")) +
    xcell("", xp("just text")) +
    xcell(" office:value-type=\"date\"", xp("2020-01-02")) +
    xcell(" office:value-type=\"date\" office:date-value=\"\"", xp("x")) +
    xcell(" office:value-type=\"float\" office:value=\"5\"", xp("#N/A")) +
    xcell(" office:value-type=\"time\"", "") +
    xcell(
      " office:value-type=\"string\" office:string-value=\"only an attribute\"",
      "",
    ) +
    xcovered(" office:value-type=\"string\"", xp("covered")) +
    xcovered(" office:value-type=\"date\" office:date-value=\"2020-01-02\"", "") +
    xcell(" office:value-type=\"string\"", xp("<text:s text:c=\"0\"/>"))
  cells_are(
    body_package(xtable("S", xrow(xtext("before") + missing + xtext("after")))),
    ["0,0 Text before", "0,13 Text after"],
  )
}

///|
test "names and strings as long as the format allows them" {
  let long_name = "sheet-" + "日本語🎉".repeat(500)
  let long_text = "x".repeat(100000)
  let body = xtable(
    long_name,
    xrow(xstring(xp(long_text)) + xstring(xp("é\u{160}é"))),
  )
  let bytes = body_package(body)
  assert_eq(sheet_names(bytes), [long_name])
  let cells = sheet_grid(bytes).cells()
  assert_eq(cells.length(), 2)
  let first = cells[0].value()
  if first is Text(text) {
    assert_eq(text.length(), 100000)
    assert_eq(text[0:10], "xxxxxxxxxx")
    assert_eq(text[99990:100000], "xxxxxxxxxx")
  } else {
    fail("the long string did not read as text")
  }
  assert_eq(value_text(cells[1].value()), "Text é\u{160}é")
  // The characters XML escapes come back as themselves.
  let raw = "<a & \"b\" say 'c'>\t\n"
  let escaped = xescaped(raw)
  cells_are(body_package(xtable("S", xrow(xstring(xp(escaped))))), [
    "0,0 Text \{raw.replace(old="\n", new="")}",
  ])
  // A name with every character an attribute can hold. The XML reader
  // turns a tab and a line end written in an attribute into spaces, as
  // the specification of XML says; a character reference keeps a line end.
  let odd = "a b\tc\nd &amp; &lt; &gt; &quot; ' é 日 🎉 end&#13;"
  let sheets = sheet_names(body_package(xtable(odd, "")))
  assert_eq(sheets.length(), 1)
  assert_eq(sheets[0], "a b c d & < > \" ' é 日 🎉 end\r")
}

///|
test "rows count wherever the format puts them, and only cells directly under a row" {
  let body = "<table:table table:name=\"S\">" +
    "<table:table-source xlink:href=\"x.ods\" table:table-name=\"T\" xlink:type=\"simple\"/>" +
    "<table:table-column table:number-columns-repeated=\"7\"/>" +
    "<table:table-header-rows>" +
    xrow(xnumber("1")) +
    "</table:table-header-rows>" +
    "<table:table-row-group table:display=\"false\">" +
    xrow(xnumber("2")) +
    "<table:table-row-group><table:table-header-rows>" +
    xrow(xnumber("3")) +
    "</table:table-header-rows><table:table-rows>" +
    xrow(xnumber("4")) +
    "</table:table-rows></table:table-row-group>" +
    "</table:table-row-group>" +
    xrow(
      "loose text in a row" +
      xnumber("5") +
      "<text:p>" +
      xnumber("6") +
      "</text:p>",
    ) +
    "<text:soft-page-break/>" +
    xrow(xnumber("7")) +
    "<table:shapes/>" +
    "</table:table>"
  cells_are(body_package(body), [
    "0,0 Number 3ff0000000000000", "1,0 Number 4000000000000000", "2,0 Number 4008000000000000",
    "3,0 Number 4010000000000000", "4,0 Number 4014000000000000", "5,0 Number 401c000000000000",
  ])
}

///|
test "a table inside a cell is a sheet of its own, and its rows are not the outer sheet's" {
  let inner = xtable("Inner", xrow(xnumber("2")))
  let outer = xtable(
    "Outer",
    xrow(xnumber("1") + xcell("", inner) + xnumber("3")),
  )
  let bytes = body_package(outer)
  assert_eq(sheet_names(bytes), ["Outer", "Inner"])
  cells_are(spreadsheet(document(outer)), [
    "0,0 Number 3ff0000000000000", "0,2 Number 4008000000000000",
  ])
  assert_eq(read(bytes), [
    "0,0 Number 3ff0000000000000", "0,2 Number 4008000000000000",
  ])
  let inner_grid = sheet_grid(bytes, sheet=1)
  assert_eq(inner_grid.cells().map(cell_text), ["0,0 Number 4000000000000000"])
  // A string cell around a table holds the table's text.
  let inner = xtable("Inner", xrow(xstring(xp("deep"))))
  let outer = xtable(
    "Outer",
    xrow(xstring(xp("around ") + inner + xp(" the table"))),
  )
  cells_are(body_package(outer), ["0,0 Text around deep the table"])
}

///|
test "tables outside the body are no sheets, and the body is what the format names" {
  let before = "<office:automatic-styles>" +
    xtable("In styles", xrow(xnumber("1"))) +
    "</office:automatic-styles>"
  let after = "</office:body>" + xtable("After body", xrow(xnumber("2")))
  let content = swapped(
    swapped(document(""), "<office:automatic-styles/>", before),
    "</office:body>",
    after,
  )
  assert_eq(sheet_names(spreadsheet(content)), [])
  // A document with no body at all.
  let root = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"" +
    OFFICE_NS +
    "\" xmlns:table=\"" +
    TABLE_NS +
    "\" xmlns:text=\"" +
    TEXT_NS +
    "\" office:version=\"1.2\">" +
    xtable("S", xrow(xnumber("1"))) +
    "</office:document-content>"
  assert_eq(sheet_names(spreadsheet(root)), [])
}
