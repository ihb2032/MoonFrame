// Blackbox tests of the positions repeats give a cell, and of the budget
// a sheet is held to: the rectangle a file asks for is checked against a
// budget tied to the package's size before a cell of it is stored.

///|
test "trailing empties repeated by the largest count hold nothing; empties before a value move it" {
  let trailing = "<table:table-cell table:number-columns-repeated=\"2147483647\"/>"
  let last = "<table:table-row table:number-rows-repeated=\"2147483647\"><table:table-cell table:number-columns-repeated=\"2147483647\"/></table:table-row>"
  cells_are(
    body_package(
      "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"2\"><table:table-cell table:number-columns-repeated=\"2\"/><table:table-cell office:value-type=\"float\" office:value=\"1\"/>\{trailing}</table:table-row>\{last}</table:table>",
    ),
    ["0,2 Number 3ff0000000000000", "1,2 Number 3ff0000000000000"],
  )
  // Empty cells before the first value are written out one by one.
  let empties = "<table:table-cell/>".repeat(12)
  cells_are(body_package(xtable("S", xrow(empties + xnumber("7")))), [
    "0,12 Number 401c000000000000",
  ])
  // A row with a value, three empty rows, a row with a value.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(xnumber("1")) +
        "<table:table-row table:number-rows-repeated=\"3\"/>" +
        xrow(xnumber("2")),
      ),
    ),
    ["0,0 Number 3ff0000000000000", "4,0 Number 4000000000000000"],
  )
  // Empty rows at the end are nothing, however many.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(xnumber("1")) +
        "<table:table-row table:number-rows-repeated=\"2147483647\"/>",
      ),
    ),
    ["0,0 Number 3ff0000000000000"],
  )
}
